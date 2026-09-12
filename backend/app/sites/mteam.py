from __future__ import annotations

from contextlib import suppress
from datetime import datetime, timezone
import re
from urllib.parse import quote

import httpx

from app.models import SearchResult
from app.sites.base import (
    BaseSiteAdapter,
    SiteAdapterError,
    SiteRateLimitError,
    bytes_to_size,
    category_label,
    clean_optional,
    root_domain,
    stable_result_id,
    torrent_filename,
    pt_metadata_from_dict,
)


class MTeamAdapter(BaseSiteAdapter):
    supports_brush = True
    id = "mteam"
    name = "M-Team"
    display_name = "M-Team"
    base_url = "https://kp.m-team.cc"
    primary_url = "https://kp.m-team.cc"
    fallback_base_urls = ["https://m-team.cc"]
    supports_pagination = True
    default_page_size = 100
    max_recommended_pages = 5
    auth_mode = "api_key"
    auth_fields = ["api_key", "authorization", "user_agent"]
    retryable_http_statuses = {429, 500, 502, 503, 504}
    rss_default_path = "getrss.php"
    rss_default_params = {
        "showrows": 50,
        "inclbookmarked": 0,
        "itemsmalldescr": 1,
        "https": 1,
    }

    async def test_connection(self) -> tuple[bool, str, int | None]:
        if not getattr(self, "api_key", None):
            return False, "M-Team 需要 API Key，请先在站点设置中填写。", None
        response = await self.request("POST", f"{self.api_base_url}/api/member/profile", raise_for_status=False)
        if response.status_code != 200:
            return False, f"M-Team 连接失败：HTTP {response.status_code}。", response.status_code
        payload = response.json()
        if payload.get("data"):
            return True, "M-Team 连接成功。", response.status_code
        return False, payload.get("message") or "M-Team API Key 无效或已过期。", response.status_code

    async def account_stats(self) -> tuple[int, int, float | None]:
        if not getattr(self, "api_key", None):
            raise SiteAdapterError("M-Team 需要 API Key，请先在站点设置中填写。")
        response = await self.request("POST", f"{self.api_base_url}/api/member/profile", raise_for_status=False)
        if response.status_code in {401, 403}:
            raise SiteAdapterError("M-Team 认证失败，请检查 API Key。")
        if response.status_code != 200:
            raise SiteAdapterError(f"M-Team 账户信息获取失败：HTTP {response.status_code}。")
        return self.parse_account_stats(response.json())

    @staticmethod
    def parse_account_stats(payload: dict) -> tuple[int, int, float | None]:
        if not isinstance(payload, dict) or not MTeamAdapter.is_success_business_code(payload.get("code")):
            raise SiteAdapterError("M-Team 账户信息响应异常。")
        counts = (payload.get("data") or {}).get("memberCount")
        if not isinstance(counts, dict):
            raise SiteAdapterError("M-Team 账户信息缺少流量数据。")
        try:
            uploaded = int(counts.get("uploaded") or 0)
            downloaded = int(counts.get("downloaded") or 0)
            raw_ratio = counts.get("shareRate")
            ratio = float(raw_ratio) if raw_ratio not in (None, "", "---", "∞") else (uploaded / downloaded if downloaded else None)
        except (TypeError, ValueError) as exc:
            raise SiteAdapterError("M-Team 账户流量数据格式异常。") from exc
        return uploaded, downloaded, ratio

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(
        self,
        keyword: str,
        page: int = 1,
        page_size: int = 30,
        mode: str | None = None,
        categories: list[str] | None = None,
    ) -> tuple[list[SearchResult], bool]:
        results, has_more, _total = await self.search_page_with_total(
            keyword,
            page=page,
            page_size=page_size,
            mode=mode,
            categories=categories,
        )
        return results, has_more

    async def search_page_with_total(
        self,
        keyword: str,
        page: int = 1,
        page_size: int = 30,
        mode: str | None = None,
        categories: list[str] | None = None,
    ) -> tuple[list[SearchResult], bool, int | None]:
        if not getattr(self, "api_key", None):
            raise SiteAdapterError("M-Team 需要 API Key，请先在站点设置中填写。")
        payload = {
            "keyword": self.normalize_keyword(keyword),
            "categories": categories or [],
            "pageNumber": max(1, page),
            "pageSize": min(max(1, page_size), self.default_page_size),
            "visible": 1,
        }
        if mode:
            payload["mode"] = mode
        data = await self.request_search_data(payload)
        rows = data.get("data")
        if not isinstance(rows, list):
            raise SiteAdapterError("M-Team 搜索响应缺少资源列表，请稍后重试。")
        total = self.parse_total(data.get("total"))
        results = [self.result_from_item(item) for item in rows or [] if isinstance(item, dict)]
        has_more = bool(total is not None and page * payload["pageSize"] < total)
        if total is None:
            has_more = len(results) >= payload["pageSize"]
        return results, has_more, total

    async def request_search_data(self, payload: dict[str, object]) -> dict:
        url = f"{self.api_base_url}/api/torrent/search"
        policy = self.rate_limit_policy()
        attempts = policy.max_retries + 1
        last_rate_limit_message: str | None = None
        for attempt in range(attempts):
            try:
                response = await self.request(
                    "POST",
                    url,
                    headers={"Content-Type": "application/json", "Referer": f"{self.base_url.rstrip('/')}/browse"},
                    json=payload,
                    raise_for_status=False,
                )
            except (httpx.TimeoutException, httpx.ConnectError) as exc:
                if attempt + 1 < attempts:
                    await self.backoff_after_access_limit(url, type(exc).__name__)
                    continue
                raise SiteAdapterError("M-Team 搜索请求超时或连接失败，请稍后重试。") from exc
            if response.status_code in self.retryable_http_statuses:
                if attempt + 1 < attempts:
                    await self.backoff_after_access_limit(url, f"HTTP {response.status_code}")
                    continue
                if response.status_code == 429:
                    raise SiteRateLimitError("M-Team 请求过于频繁，请稍后再试。")
                raise SiteAdapterError(f"M-Team 暂时不可用：HTTP {response.status_code}，请稍后重试。")
            if response.status_code in {401, 403}:
                raise SiteAdapterError("M-Team 认证失败，请检查 API Key 或 Authorization。")
            if response.status_code >= 400:
                raise SiteAdapterError(f"M-Team 搜索失败：HTTP {response.status_code}。")
            try:
                response_payload = response.json()
            except ValueError as exc:
                raise SiteAdapterError("M-Team 搜索响应不是有效 JSON，请稍后重试。") from exc
            if not isinstance(response_payload, dict):
                raise SiteAdapterError("M-Team 搜索响应格式异常，请稍后重试。")
            business_code = response_payload.get("code")
            message = str(response_payload.get("message") or "").strip()
            if self.is_success_business_code(business_code):
                data = response_payload.get("data")
                if not isinstance(data, dict):
                    raise SiteAdapterError("M-Team 搜索响应缺少数据，请稍后重试。")
                return data
            if self.is_business_rate_limit(business_code, message):
                last_rate_limit_message = message
                if attempt + 1 < attempts:
                    await self.backoff_after_access_limit(url, f"业务码 {business_code or '-'}：请求频繁")
                    continue
                raise SiteRateLimitError("M-Team 请求过于频繁，请稍后再试。")
            if self.is_auth_business_error(business_code, message):
                raise SiteAdapterError("M-Team 认证失败，请检查 API Key 或 Authorization。")
            safe_code = str(business_code) if business_code not in (None, "") else "未知"
            raise SiteAdapterError(f"M-Team 搜索失败：业务码 {safe_code}。")
        raise SiteRateLimitError(last_rate_limit_message or "M-Team 请求过于频繁，请稍后再试。")

    @staticmethod
    def is_success_business_code(value: object) -> bool:
        return value in (None, "", 0, "0", "SUCCESS", "success")

    @staticmethod
    def is_business_rate_limit(code: object, message: str) -> bool:
        normalized = message.casefold()
        return str(code) in {"429"} or any(
            marker in normalized
            for marker in ("请求过于频繁", "請求過於頻繁", "too many request", "rate limit")
        )

    @staticmethod
    def is_auth_business_error(code: object, message: str) -> bool:
        normalized = message.casefold()
        return str(code) in {"401", "403"} or any(
            marker in normalized
            for marker in ("api key", "apikey", "unauthorized", "未授权", "未授權", "认证", "認證")
        )

    @staticmethod
    def parse_total(value: object) -> int | None:
        if value in (None, ""):
            return None
        try:
            return max(0, int(value))
        except (TypeError, ValueError) as exc:
            raise SiteAdapterError("M-Team 搜索响应中的总数无效，请稍后重试。") from exc

    @property
    def api_base_url(self) -> str:
        return f"https://api.{root_domain(self.base_url)}"

    def normalize_keyword(self, keyword: str) -> str:
        value = keyword.strip()
        if value.startswith("tt"):
            return f"https://www.imdb.com/title/{value}"
        return value

    def result_from_item(self, item: dict) -> SearchResult:
        torrent_id = str(item.get("id") or "")
        title = item.get("name") or "未命名资源"
        metadata = pt_metadata_from_dict(item, site_id=self.id)
        subtitle = metadata.get("subtitle") if isinstance(metadata.get("subtitle"), str) else None
        description = clean_optional(
            item.get("descr")
            or item.get("summary")
            or item.get("overview")
            or item.get("intro")
        )
        if description == subtitle:
            description = None
        detail_url = f"{self.base_url.rstrip('/')}/detail/{torrent_id}" if torrent_id else self.base_url
        download_url = f"{self.api_base_url}/api/torrent/genDlToken?id={torrent_id}" if torrent_id else None
        published = self.format_timestamp(item.get("createdDate"))
        return SearchResult(
            id=stable_result_id(self.id, title, download_url, detail_url),
            title=title,
            subtitle=subtitle,
            description=description,
            published_at=published,
            size=bytes_to_size(item.get("size")),
            size_bytes=metadata.get("size_bytes") if isinstance(metadata.get("size_bytes"), int) else None,
            category=metadata.get("category") if isinstance(metadata.get("category"), str) else None,
            language=metadata.get("language") if isinstance(metadata.get("language"), str) else None,
            is_free=metadata.get("is_free") if isinstance(metadata.get("is_free"), bool) else None,
            discount_label=metadata.get("discount_label") if isinstance(metadata.get("discount_label"), str) else None,
            free_until=metadata.get("free_until") if isinstance(metadata.get("free_until"), str) else None,
            free_remaining=metadata.get("free_remaining") if isinstance(metadata.get("free_remaining"), str) else None,
            seeders=metadata.get("seeders") if isinstance(metadata.get("seeders"), int) else None,
            leechers=metadata.get("leechers") if isinstance(metadata.get("leechers"), int) else None,
            downloads=metadata.get("downloads") if isinstance(metadata.get("downloads"), int) else None,
            download_factor=metadata.get("download_factor") if isinstance(metadata.get("download_factor"), float) else None,
            upload_factor=metadata.get("upload_factor") if isinstance(metadata.get("upload_factor"), float) else None,
            hit_and_run=metadata.get("hit_and_run") if isinstance(metadata.get("hit_and_run"), bool) else None,
            download_url=download_url,
            magnet_url=None,
            source=self.id,
            detail_url=detail_url,
            source_url=f"mteam:{torrent_id}" if torrent_id else None,
        )

    async def preview_rss_resources(
        self,
        *,
        keyword: str | None = None,
        category: str | None = None,
        page: int = 1,
        page_size: int = 25,
    ) -> dict[str, object] | None:
        if not getattr(self, "api_key", None):
            return None
        category_codes = self.category_codes_for_label(category)
        # MoviePilot's MTorrentSpider uses one API page of 100 items. Keep that
        # resource window, then page it locally for a lighter SwiftUI preview.
        fetched, _has_more, api_total = await self.search_page_with_total(
            keyword or "",
            page=1,
            page_size=self.default_page_size,
            categories=category_codes,
        )
        filtered = fetched
        if category and not category_codes:
            lowered_category = category.lower()
            filtered = [
                result
                for result in filtered
                if (result.category or "").lower() == lowered_category
                or lowered_category in (result.category or "").lower()
            ]
        total_count = len(filtered)
        effective_page_size = max(1, min(page_size, self.default_page_size))
        total_pages = (total_count + effective_page_size - 1) // effective_page_size if total_count else 0
        effective_page = min(max(1, page), max(1, total_pages))
        page_start = (effective_page - 1) * effective_page_size
        page_results = filtered[page_start : page_start + effective_page_size]
        return {
            "results": page_results,
            "source_results": fetched,
            "count": total_count,
            "api_total": api_total,
            "page": effective_page,
            "page_size": effective_page_size,
            "total_pages": total_pages,
            "has_previous": effective_page > 1,
            "has_next": effective_page < total_pages,
        }

    def category_codes_for_label(self, category: str | None) -> list[str]:
        if not category:
            return []
        wanted = category.strip()
        if not wanted:
            return []
        matched: list[str] = []
        for code in (
            "401",
            "402",
            "403",
            "404",
            "405",
            "406",
            "407",
            "408",
            "409",
            "410",
            "419",
            "420",
            "421",
            "435",
            "438",
            "439",
        ):
            if category_label(self.id, code) == wanted:
                matched.append(code)
        return matched

    async def enrich_rss_preview_results(self, results: list[SearchResult], *, limit: int = 20) -> list[SearchResult]:
        if not getattr(self, "api_key", None):
            return results
        if all(result.seeders is not None and result.downloads is not None for result in results[:limit]):
            return results
        enriched: list[SearchResult] = []
        cache: dict[str, SearchResult] = {}
        id_cache: dict[str, SearchResult] = {}
        wanted_ids = [self.torrent_id_from_result(result) for result in results[:limit]]
        wanted_ids = [torrent_id for torrent_id in wanted_ids if torrent_id]
        if wanted_ids:
            latest_results: list[SearchResult] = []
            adult_results: list[SearchResult] = []
            with suppress(Exception):
                latest_results, _ = await self.search_page("", page=1, page_size=min(self.default_page_size, max(limit, len(wanted_ids) * 2)))
            with suppress(Exception):
                adult_results, _ = await self.search_page("", page=1, page_size=min(self.default_page_size, max(limit, len(wanted_ids) * 2)), mode="adult")
            for item in [*latest_results, *adult_results]:
                if torrent_id := self.torrent_id_from_result(item):
                    id_cache[torrent_id] = item
        for index, result in enumerate(results):
            if index >= limit:
                enriched.append(result)
                continue
            torrent_id = self.torrent_id_from_result(result)
            matched = id_cache.get(torrent_id or "")
            key = result.title.strip()
            if matched is None:
                matched = cache.get(key)
            if matched is None:
                with suppress(Exception):
                    search_results, _ = await self.search_page(key, page=1, page_size=5)
                    matched = next((item for item in search_results if item.title.strip() == key), search_results[0] if search_results else None)
                    if matched is None:
                        adult_results, _ = await self.search_page(key, page=1, page_size=5, mode="adult")
                        matched = next((item for item in adult_results if item.title.strip() == key), adult_results[0] if adult_results else None)
                    if matched is not None:
                        cache[key] = matched
            enriched.append(self.merge_rss_preview_metadata(result, matched) if matched is not None else result)
        return enriched

    def merge_rss_preview_metadata(self, rss_result: SearchResult, metadata: SearchResult) -> SearchResult:
        updates = {
            "subtitle": rss_result.subtitle or metadata.subtitle,
            "description": rss_result.description or metadata.description,
            "category": metadata.category or rss_result.category,
            "language": metadata.language or rss_result.language,
            "is_free": metadata.is_free if metadata.is_free is not None else rss_result.is_free,
            "discount_label": metadata.discount_label or rss_result.discount_label,
            "free_until": metadata.free_until or rss_result.free_until,
            "free_remaining": metadata.free_remaining or rss_result.free_remaining,
            "seeders": metadata.seeders if metadata.seeders is not None else rss_result.seeders,
            "leechers": metadata.leechers if metadata.leechers is not None else rss_result.leechers,
            "downloads": metadata.downloads if metadata.downloads is not None else rss_result.downloads,
            "detail_url": metadata.detail_url or rss_result.detail_url,
            "source_url": metadata.source_url or rss_result.source_url,
        }
        return rss_result.model_copy(update=updates)

    def format_timestamp(self, value: object) -> str | None:
        if value is None:
            return None
        if isinstance(value, (int, float)):
            timestamp = float(value)
            if timestamp > 10_000_000_000:
                timestamp /= 1000
            return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()
        text = str(value).strip()
        return text or None

    async def download_torrent(self, result: SearchResult) -> tuple[bytes, str]:
        torrent_id = self.torrent_id_from_result(result)
        if not torrent_id:
            raise SiteAdapterError("M-Team 下载失败：无法识别种子 ID。")
        response = await self.request(
            "POST",
            f"{self.api_base_url}/api/torrent/genDlToken",
            headers={"Content-Type": "application/x-www-form-urlencoded", "Referer": result.detail_url or self.base_url},
            data={"id": torrent_id},
            raise_for_status=False,
        )
        if response.status_code != 200:
            raise SiteAdapterError(f"M-Team 下载失败：HTTP {response.status_code}。")
        payload = response.json()
        data = payload.get("data")
        if not data:
            message = payload.get("message") or "M-Team 未返回下载凭证。"
            raise SiteAdapterError(f"M-Team 下载失败：{message}")
        download_url = self.download_url_from_token(data)
        torrent_response = await self.request(
            "GET",
            download_url,
            headers={"Accept": "application/x-bittorrent,*/*", "Referer": result.detail_url or self.base_url},
        )
        return torrent_response.content, torrent_filename(result)

    def torrent_id_from_result(self, result: SearchResult) -> str | None:
        for value in (result.source_url, result.download_url, result.detail_url, result.id):
            if not value:
                continue
            match = re.search(r"(?:mteam:|[?&]id=|/detail/)(\d+)", value)
            if match:
                return match.group(1)
        return None

    def download_url_from_token(self, data: object) -> str:
        if isinstance(data, dict):
            for key in ("url", "downloadUrl", "download_url", "link"):
                value = data.get(key)
                if isinstance(value, str) and value.strip():
                    return value.strip()
            credential = data.get("credential") or data.get("token")
            if isinstance(credential, str) and credential.strip():
                return f"{self.api_base_url}/api/torrent/download?credential={quote(credential.strip())}"
        text = str(data).strip()
        if text.startswith(("http://", "https://")):
            return text
        return f"{self.api_base_url}/api/torrent/download?credential={quote(text)}"
