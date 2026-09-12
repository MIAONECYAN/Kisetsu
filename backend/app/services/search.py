from __future__ import annotations

import asyncio
import re

import httpx

from app.models import SearchDiagnostics, SearchResult, SiteSearchDiagnostics
from app.sites import describe_site_error, get_site_adapter, site_usage_restriction
from app.sites.base import SiteRateLimitError
from app.sites.rate_limiter import drain_rate_limit_events

INTERNAL_SEARCH_PAGE_LIMIT = 50
MAX_CONCURRENT_SEARCH_SITES = 2


def result_dedupe_key(result: SearchResult) -> str:
    url = result.magnet_url or result.download_url or result.detail_url
    if url:
        match = re.search(r"btih:([a-zA-Z0-9]+)", url)
        if match:
            return f"btih:{match.group(1).casefold()}"
        return f"url:{url.casefold()}"
    title_key = re.sub(r"\s+", " ", result.title.casefold()).strip()
    return "|".join([result.source, title_key, result.size or "", result.published_at or ""])


def stop_reason_label(reason: str) -> str:
    labels = {
        "site_disabled": "站点已停用",
        "site_brush_only": "站点仅用于刷流",
        "timeout": "站点请求超时",
        "site_rate_limited": "站点访问限制",
        "site_error": "站点请求失败",
        "empty_page": "当前页没有资源",
        "no_new_unique_results": "没有新增资源，避免重复循环",
        "no_next_page": "站点没有下一页",
        "max_pages": "达到本次页数上限",
        "internal_safety_limit": "达到安全页数上限",
        "single_page_site": "站点仅支持单页",
    }
    return labels.get(reason, reason)


async def search_site_pages(
    site_id: str,
    keyword: str,
    *,
    start_page: int = 1,
    max_pages: int | None = None,
    page_size: int,
    site_settings: dict | None = None,
    stop_when_no_new_results: bool = True,
    timeout_seconds: float = 15,
    respect_site_enabled: bool = True,
    site_purpose: str = "search",
) -> tuple[list[SearchResult], SiteSearchDiagnostics]:
    diagnostics = SiteSearchDiagnostics(site=site_id)
    try:
        adapter = get_site_adapter(site_id, site_settings)
        diagnostics.supports_pagination = bool(getattr(adapter, "supports_pagination", False))
        restriction = site_usage_restriction(
            adapter,
            site_purpose,
            respect_site_enabled=respect_site_enabled,
        )
        if restriction:
            diagnostics.stop_reason, message = restriction
            diagnostics.warnings.append(message)
            return [], diagnostics
    except Exception as exc:
        diagnostics.error = describe_site_error(exc)
        diagnostics.stop_reason = "site_error"
        return [], diagnostics

    all_results: list[SearchResult] = []
    seen: set[str] = set()
    effective_max_pages = max_pages or INTERNAL_SEARCH_PAGE_LIMIT
    hard_limited = effective_max_pages >= INTERNAL_SEARCH_PAGE_LIMIT
    end_page = start_page + effective_max_pages - 1
    for page in range(start_page, end_page + 1):
        try:
            search_page = getattr(adapter, "search_page", None)
            if callable(search_page):
                page_results, has_more = await asyncio.wait_for(
                    search_page(keyword, page=page, page_size=page_size),
                    timeout=timeout_seconds,
                )
            else:
                if page > 1:
                    break
                page_results = await asyncio.wait_for(adapter.search(keyword, page_size), timeout=timeout_seconds)
                has_more = False
                diagnostics.warnings.append("该站点未提供分页接口，已按单页结果处理。")
        except asyncio.TimeoutError:
            diagnostics.error = f"搜索第 {page} 页超时（{int(timeout_seconds)} 秒），可在设置中调大单站点搜索超时或稍后重试。"
            diagnostics.stop_reason = "timeout"
            break
        except (SiteRateLimitError, httpx.HTTPStatusError) as exc:
            if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code not in {403, 429}:
                diagnostics.error = f"{describe_site_error(exc)}。当前镜像访问失败，可在设置中切换镜像。"
                diagnostics.stop_reason = "site_error"
                break
            diagnostics.error = describe_site_error(exc)
            diagnostics.warnings.append("站点可能触发访问限制，本次已停止继续请求，稍后重试会更稳。")
            diagnostics.has_more = False
            diagnostics.completed_all_accessible_pages = False
            diagnostics.stop_reason = "site_rate_limited"
            break
        except Exception as exc:
            diagnostics.error = f"{describe_site_error(exc)}。当前镜像访问失败，可在设置中切换镜像。"
            diagnostics.stop_reason = "site_error"
            break
        finally:
            diagnostics.rate_limit_events.extend(event.message for event in drain_rate_limit_events(site_id))

        diagnostics.pages_fetched += 1
        diagnostics.total_fetched += len(page_results)
        new_count = 0
        for result in page_results:
            result = result.model_copy(update={"page": page})
            key = result_dedupe_key(result)
            if key not in seen:
                seen.add(key)
                new_count += 1
            all_results.append(result)
        diagnostics.total_unique = len(seen)
        diagnostics.has_more = bool(has_more)
        if page == end_page and has_more:
            diagnostics.reached_max_pages = True
            diagnostics.completed_all_accessible_pages = False
            diagnostics.reached_internal_safety_limit = hard_limited
            diagnostics.stop_reason = "internal_safety_limit" if hard_limited else "max_pages"
            if hard_limited:
                diagnostics.warnings.append("结果较多，已停止在安全上限，可缩小关键词后再试。")
            break
        if not page_results:
            diagnostics.warnings.append("当前页没有返回资源，已停止继续搜索。")
            diagnostics.has_more = False
            diagnostics.completed_all_accessible_pages = True
            diagnostics.stop_reason = "empty_page"
            break
        if stop_when_no_new_results and page_results and new_count == 0:
            diagnostics.warnings.append("本页没有新增资源，已停止继续搜索，避免重复结果循环。")
            diagnostics.has_more = False
            diagnostics.completed_all_accessible_pages = True
            diagnostics.stop_reason = "no_new_unique_results"
            break
        if not has_more:
            diagnostics.completed_all_accessible_pages = True
            diagnostics.has_more = False
            diagnostics.stop_reason = "no_next_page"
            if site_id == "mikan" and page == start_page and diagnostics.total_fetched >= 900:
                diagnostics.warnings.append("Mikan 搜索页只返回当前结果页；如需完整订阅，请使用 Mikan 番组地址。")
            break
        if not diagnostics.supports_pagination:
            diagnostics.warnings.append("该站点未声明分页能力，已按单页结果处理。")
            diagnostics.has_more = False
            diagnostics.completed_all_accessible_pages = True
            diagnostics.stop_reason = "single_page_site"
            break
    return all_results, diagnostics


async def search_multi_site(
    keyword: str,
    sites: list[str],
    *,
    start_page: int = 1,
    max_pages: int | None = None,
    page_size: int,
    site_settings: dict | None = None,
    deduplicate: bool = True,
    stop_when_no_new_results: bool = True,
    timeout_seconds: float = 15,
    respect_site_enabled: bool = True,
    site_purpose: str = "search",
) -> tuple[list[SearchResult], list[str], SearchDiagnostics]:
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_SEARCH_SITES)

    async def run_site(site_id: str) -> tuple[list[SearchResult], SiteSearchDiagnostics]:
        async with semaphore:
            return await search_site_pages(
                site_id,
                keyword,
                start_page=start_page,
                max_pages=max_pages,
                page_size=page_size,
                site_settings=site_settings,
                stop_when_no_new_results=stop_when_no_new_results,
                timeout_seconds=timeout_seconds,
                respect_site_enabled=respect_site_enabled,
                site_purpose=site_purpose,
            )

    tasks = [run_site(site_id) for site_id in sites]
    responses = await asyncio.gather(*tasks)
    warnings: list[str] = []
    all_results: list[SearchResult] = []
    seen: set[str] = set()
    diagnostics = SearchDiagnostics()
    for site_results, site_diag in responses:
        diagnostics.site_diagnostics.append(site_diag)
        diagnostics.pages_fetched += site_diag.pages_fetched
        diagnostics.total_fetched += site_diag.total_fetched
        diagnostics.reached_max_pages = diagnostics.reached_max_pages or site_diag.reached_max_pages
        diagnostics.reached_internal_safety_limit = diagnostics.reached_internal_safety_limit or site_diag.reached_internal_safety_limit
        diagnostics.completed_all_accessible_pages = diagnostics.completed_all_accessible_pages and site_diag.completed_all_accessible_pages
        diagnostics.has_more = diagnostics.has_more or site_diag.has_more
        if site_diag.stop_reason:
            diagnostics.stop_reasons.append(f"{site_diag.site}: {stop_reason_label(site_diag.stop_reason)}")
        if site_diag.error:
            warnings.append(f"{site_diag.site}: {site_diag.error}")
        warnings.extend(f"{site_diag.site}: {warning}" for warning in site_diag.warnings)
        for result in site_results:
            key = result_dedupe_key(result)
            if key in seen:
                if not deduplicate:
                    all_results.append(result)
                continue
            seen.add(key)
            all_results.append(result)
    diagnostics.total_unique = len(seen)
    return all_results, warnings, diagnostics
