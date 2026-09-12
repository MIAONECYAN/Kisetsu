from __future__ import annotations

import asyncio
import base64
import binascii
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timedelta, timezone
import re
import sqlite3
from pathlib import Path
from pathlib import PurePosixPath

from app.core.downloader import DownloaderAddResult, DownloaderClient, DownloaderError
from app.core.downloaders import (
    describe_downloader_error,
    downloader_client,
    downloader_display_name,
    stored_downloader_routing,
)
from app.core.qbittorrent import QbittorrentClient
from app.db import Store
from app.models import EpisodeParseRule, QbittorrentConfig, RefreshAllResponse, RefreshResponse, SearchDiagnostics, SearchResult, SiteSearchDiagnostics, Subscription, SubscriptionCreate, SubscriptionMatch
from app.notifications.service import NotificationService
from app.notifications.pending import history_size_target, send_or_defer_size_notification
from app.notifications.templates import (
    download_batch_summary_event,
    download_failed_event,
    download_started_event,
    pending_failure_batch_event,
    subscription_new_resource_event,
    subscription_refresh_failed_event,
)
from app.services.downloads import confirmed_task_size_bytes, release_subscription_download_tag, resource_total_size_bytes, submit_result_to_downloader, subscription_download_tag
from app.services.episode_fulfillment import (
    automatic_download_fulfillment_decision,
    build_subscription_episode_media_index,
    episode_keys_for_parsed_title,
    submitted_episode_keys,
)
from app.services.managed_directories import subscription_download_directory
from app.services.search import search_multi_site
from app.services.search_result_analysis import analyze_search_result, is_collection_parsed
from app.services.subscription import btih_hash_from_url, dedupe_results, fingerprint_result, match_results_with_diagnostics, record_processed, should_auto_download
from app.services.title_parser import parse_title
from app.sites import describe_site_error, get_site_adapter, site_usage_restriction
from app.sites.rate_limiter import drain_rate_limit_events

TASK_TEXT_RE = re.compile(r"[^0-9a-z\u4e00-\u9fff]+", re.IGNORECASE)
TASK_TOKEN_RE = re.compile(r"[a-z0-9]+|[\u4e00-\u9fff]+", re.IGNORECASE)
WEAK_TASK_TOKENS = {"web", "dl", "aac", "avc", "mp4", "mkv", "chs", "cht", "big5", "gb"}
PENDING_CONFIRMATIONS_KEY = "pending_download_confirmations"
PENDING_CONFIRMATION_SECONDS = 90
DEGRADED_RESPONSE_TYPES = {"timeout", "connect_error", "http_429", "http_5xx", "request_error"}
_SUBSCRIPTION_REFRESH_LOCKS: dict[tuple[str, int], asyncio.Lock] = {}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _pending_confirmations(store: Store) -> dict[str, dict]:
    data = store.get_config(PENDING_CONFIRMATIONS_KEY) or {}
    return {str(key): value for key, value in data.items() if isinstance(value, dict)}


def _save_pending_confirmations(store: Store, values: dict[str, dict]) -> None:
    store.set_config(PENDING_CONFIRMATIONS_KEY, values)


def _remember_pending_confirmation(
    store: Store,
    subscription: Subscription,
    result: SearchResult,
    add_result: DownloaderAddResult,
    lookup_tag: str | None,
) -> None:
    fingerprint = fingerprint_result(result)
    records = _pending_confirmations(store)
    now = _utc_now()
    previous = records.get(fingerprint) or {}
    records[fingerprint] = {
        "subscription_id": subscription.id,
        "torrent_hash": add_result.torrent_hash,
        "lookup_tag": lookup_tag,
        "response_type": add_result.response_type or "unknown",
        "started_at": previous.get("started_at") or now.isoformat(),
        "deadline_at": previous.get("deadline_at") or (now + timedelta(seconds=PENDING_CONFIRMATION_SECONDS)).isoformat(),
        "attempts": int(previous.get("attempts") or 0),
    }
    _save_pending_confirmations(store, records)


@asynccontextmanager
async def _submission_session(client: DownloaderClient):
    manager = getattr(client, "submission_session", None)
    if callable(manager):
        async with manager():
            yield
        return
    yield


def _torrent_tags(torrent: dict) -> set[str]:
    raw = torrent.get("tags")
    if isinstance(raw, str):
        return {item.strip() for item in raw.split(",") if item.strip()}
    if isinstance(raw, list):
        return {str(item).strip() for item in raw if str(item).strip()}
    return set()


async def reconcile_pending_confirmations(
    store: Store,
    *,
    client: DownloaderClient | None = None,
    torrents: list[dict] | None = None,
    subscription_id: int | None = None,
    now: datetime | None = None,
    manage_session: bool = True,
) -> dict[str, object]:
    records = _pending_confirmations(store)
    selected = {
        fingerprint: data
        for fingerprint, data in records.items()
        if subscription_id is None or int(data.get("subscription_id") or 0) == subscription_id
    }
    if not selected:
        return {"confirmed": 0, "pending": 0, "failed": 0, "conflicts": 0, "warnings": []}

    active_client = client
    if torrents is None and active_client is None:
        try:
            active_client = downloader_client(store, "qbittorrent")
        except Exception as exc:
            return {
                "confirmed": 0,
                "pending": len(selected),
                "failed": 0,
                "conflicts": 0,
                "warnings": [describe_downloader_error("qbittorrent", exc)],
            }

    if torrents is None:
        try:
            if manage_session:
                async with _submission_session(active_client):
                    torrents = await active_client.list_torrents()
            else:
                torrents = await active_client.list_torrents()
        except Exception as exc:
            return {
                "confirmed": 0,
                "pending": len(selected),
                "failed": 0,
                "conflicts": 0,
                "warnings": [describe_downloader_error("qbittorrent", exc)],
            }

    by_hash: dict[str, list[dict]] = {}
    by_tag: dict[str, list[dict]] = {}
    for torrent in torrents:
        torrent_hash = _torrent_hash(torrent)
        if torrent_hash:
            by_hash.setdefault(torrent_hash, []).append(torrent)
        for tag in _torrent_tags(torrent):
            by_tag.setdefault(tag, []).append(torrent)

    current_time = now or _utc_now()
    confirmed = 0
    pending_count = 0
    failed = 0
    conflicts = 0
    warnings: list[str] = []
    expired_by_subscription: dict[int, list[tuple[str, SearchResult]]] = {}
    for fingerprint, data in selected.items():
        history = store.get_history_by_fingerprint(fingerprint)
        if history is None or history.get("status") != "pending_confirmation":
            records.pop(fingerprint, None)
            continue
        expected_hash = str(data.get("torrent_hash") or history.get("qbittorrent_hash") or "").casefold()
        lookup_tag = str(data.get("lookup_tag") or "")
        candidates = by_hash.get(expected_hash, []) if expected_hash else []
        if not candidates and lookup_tag:
            candidates = by_tag.get(lookup_tag, [])
        if len(candidates) > 1:
            conflicts += 1
            pending_count += 1
            warnings.append("待确认任务存在多个身份候选，已停止自动协调。")
            continue
        if len(candidates) == 1:
            torrent = candidates[0]
            store.update_history_qbittorrent_task(
                int(history["id"]),
                qbittorrent_hash=_torrent_hash(torrent) or None,
                downloader_type="qbittorrent",
                torrent_name=_torrent_name(torrent) or None,
                save_path=_torrent_save_path(torrent) or history.get("save_path"),
            )
            store.update_history_status(int(history["id"]), "queued")
            sub_id = int(data.get("subscription_id") or history.get("subscription_id") or 0)
            if sub_id:
                store.update_subscription_match_status(sub_id, fingerprint, "queued")
            if active_client is not None:
                with suppress(Exception):
                    await release_subscription_download_tag(
                        active_client,
                        lookup_tag,
                        torrent_hash=_torrent_hash(torrent) or None,
                    )
            records.pop(fingerprint, None)
            confirmed += 1
            continue

        deadline = _parse_datetime(str(data.get("deadline_at") or ""))
        if deadline is not None and current_time >= deadline:
            store.update_history_status(int(history["id"]), "error")
            sub_id = int(data.get("subscription_id") or history.get("subscription_id") or 0)
            if sub_id:
                store.update_subscription_match_status(sub_id, fingerprint, "error")
            records.pop(fingerprint, None)
            if active_client is not None:
                with suppress(Exception):
                    await release_subscription_download_tag(active_client, lookup_tag)
            failed += 1
            subscription_data = store.get_subscription(sub_id) if sub_id else None
            if subscription_data is not None:
                result = SearchResult(
                    id=f"pending-{fingerprint[:12]}",
                    title=str(history.get("title") or "待确认下载"),
                    source=str(history.get("source") or "unknown"),
                    download_url=history.get("download_url"),
                )
                expired_by_subscription.setdefault(sub_id, []).append((fingerprint, result))
            continue

        data["attempts"] = int(data.get("attempts") or 0) + 1
        records[fingerprint] = data
        pending_count += 1

    _save_pending_confirmations(store, records)
    for sub_id, expired_items in expired_by_subscription.items():
        subscription_data = store.get_subscription(sub_id)
        if subscription_data is None:
            continue
        subscription = Subscription(**subscription_data)
        if len(expired_items) == 1:
            await NotificationService(store).send_best_effort(
                download_failed_event(
                    store,
                    subscription,
                    expired_items[0][1],
                    "qBittorrent 在确认期限内未出现对应任务",
                )
            )
            continue
        await NotificationService(store).send_best_effort(
            pending_failure_batch_event(
                store,
                subscription,
                [item[1] for item in expired_items],
                [item[0] for item in expired_items],
            )
        )
    return {
        "confirmed": confirmed,
        "pending": pending_count,
        "failed": failed,
        "conflicts": conflicts,
        "warnings": warnings,
    }


def _append_rate_limit_events(diagnostics: SearchDiagnostics, site_id: str) -> None:
    events = [event.message for event in drain_rate_limit_events(site_id)]
    if not events:
        return
    for site_diagnostics in diagnostics.site_diagnostics:
        if site_diagnostics.site == site_id:
            site_diagnostics.rate_limit_events.extend(events)
            return
    diagnostics.site_diagnostics.append(SiteSearchDiagnostics(site=site_id, rate_limit_events=events))


def _global_episode_rules(store: Store) -> list[EpisodeParseRule]:
    data = store.get_config("episode_parse_rules") or {}
    return [EpisodeParseRule(**item) for item in data.get("user_rules", []) if isinstance(item, dict)]


def _effective_episode_rules(store: Store, subscription: Subscription) -> list[EpisodeParseRule]:
    rules = [*subscription.episode_parse_rules, *_global_episode_rules(store)]
    return [rule.model_copy(update={"priority": index}) for index, rule in enumerate(rules)]


def _normalize_info_hash(value: str | None) -> str | None:
    if not value:
        return None
    candidate = value.strip().casefold()
    if re.fullmatch(r"[a-f0-9]{40}", candidate):
        return candidate
    if re.fullmatch(r"[a-z2-7]{32}", candidate):
        try:
            return base64.b32decode(candidate.upper()).hex()
        except (binascii.Error, ValueError):
            return None
    return None


def _torrent_hash(torrent: dict) -> str:
    return _normalize_info_hash(str(torrent.get("hash") or "")) or str(torrent.get("hash") or "").casefold()


def _torrent_name(torrent: dict) -> str:
    return str(torrent.get("name") or "")


def _torrent_save_path(torrent: dict) -> str:
    return str(torrent.get("save_path") or torrent.get("savePath") or "")


def _normalized_task_text(value: str | None) -> str:
    if not value:
        return ""
    return TASK_TEXT_RE.sub("", value.casefold())


def _same_task_text(left: str | None, right: str | None) -> bool:
    normalized_left = _normalized_task_text(left)
    normalized_right = _normalized_task_text(right)
    if not normalized_left or not normalized_right:
        return False
    if normalized_left == normalized_right:
        return True
    shortest = min(len(normalized_left), len(normalized_right))
    return shortest >= 8 and (normalized_left in normalized_right or normalized_right in normalized_left)


def _task_tokens(value: str | None) -> set[str]:
    if not value:
        return set()
    return {token.casefold() for token in TASK_TOKEN_RE.findall(value) if token.strip()}


def _same_task_tokens(left: str | None, right: str | None) -> bool:
    left_tokens = _task_tokens(left)
    right_tokens = _task_tokens(right)
    if not left_tokens or not right_tokens:
        return False
    common = left_tokens & right_tokens
    meaningful = common - WEAK_TASK_TOKENS
    ratio = len(common) / max(1, min(len(left_tokens), len(right_tokens)))
    return len(meaningful) >= 4 or (len(common) >= 5 and ratio >= 0.45)


def _same_save_path(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left_path = str(PurePosixPath(left)).rstrip("/")
    right_path = str(PurePosixPath(right)).rstrip("/")
    return bool(left_path and right_path and left_path == right_path)


def _same_episode_identity(left: str | None, right: str | None) -> bool:
    left_parsed = parse_title(left or "")
    right_parsed = parse_title(right or "")
    if left_parsed.episode is not None and right_parsed.episode is not None:
        if left_parsed.episode != right_parsed.episode:
            return False
    if left_parsed.season is not None and right_parsed.season is not None:
        if left_parsed.season != right_parsed.season:
            return False
    return True


def _download_save_path(base_path: str | None, title: str | None) -> str | None:
    path = subscription_download_directory(base_path, title)
    return str(path) if path is not None else None


def _find_torrent_for_result(result: SearchResult, save_path: str | None, torrents: list[dict]) -> dict | None:
    expected_hash = btih_hash_from_url(result.magnet_url or result.download_url)
    if expected_hash:
        for torrent in torrents:
            if _torrent_hash(torrent) == expected_hash:
                return torrent
        return None

    for torrent in torrents:
        name = _torrent_name(torrent)
        if _same_episode_identity(result.title, name) and _same_task_text(result.title, name):
            return torrent

    return None


async def _remember_submitted_torrent(
    client: DownloaderClient,
    store: Store,
    history_id: int,
    result: SearchResult,
    save_path: str | None,
    downloader_type: str = "qbittorrent",
    add_result: DownloaderAddResult | None = None,
) -> None:
    with suppress(Exception):
        torrent = None
        if add_result is not None:
            task_by_identity = getattr(client, "task_by_identity", None)
            if callable(task_by_identity):
                torrent = await task_by_identity(add_result)
        if torrent is None:
            torrent = _find_torrent_for_result(result, save_path, await client.list_torrents())
        if torrent is None:
            return
        store.update_history_qbittorrent_task(
            history_id,
            qbittorrent_hash=_torrent_hash(torrent) or None,
            downloader_type=downloader_type,
            remote_task_id=str(torrent.get("remote_id")) if torrent.get("remote_id") is not None else None,
            torrent_name=_torrent_name(torrent) or None,
            save_path=_torrent_save_path(torrent) or save_path,
        )


async def fetch_subscription_results(
    subscription: Subscription,
    site_settings: dict | None = None,
    *,
    max_pages: int | None = None,
    page_size: int = 50,
    timeout_seconds: float = 15,
) -> tuple[list[SearchResult], list[str], SearchDiagnostics]:
    warnings: list[str] = []
    results: list[SearchResult] = []
    empty_diagnostics = SearchDiagnostics()
    mikan_source = subscription.mikan_bangumi_url or subscription.source_url
    if subscription.source_type == "mikan_bangumi":
        if not mikan_source:
            warnings.append("Mikan 番组：请填写 Mikan Bangumi 地址。")
            return results, warnings, empty_diagnostics
        try:
            adapter = get_site_adapter("mikan", site_settings)
            bangumi_id_from_keyword = getattr(adapter, "bangumi_id_from_keyword", None)
            bangumi_id = bangumi_id_from_keyword(mikan_source) if bangumi_id_from_keyword else None
            if bangumi_id:
                warnings.append(f"使用 mikan bangumi id={bangumi_id} 抓取资源。")
                page_results, search_warnings, search_diagnostics = await search_multi_site(
                    mikan_source,
                    ["mikan"],
                    max_pages=1,
                    page_size=100,
                    site_settings=site_settings,
                    timeout_seconds=timeout_seconds,
                    respect_site_enabled=False,
                    site_purpose="subscription",
                )
                results.extend(page_results)
                return results, [*warnings, *search_warnings], search_diagnostics
        except Exception as exc:
            warnings.append(f"mikan Bangumi：{describe_site_error(exc)}")
            return results, warnings, empty_diagnostics

    if subscription.source_type == "rss":
        if not subscription.rss_urls:
            warnings.append("RSS：请填写 RSS 地址。")
            return results, warnings, empty_diagnostics
        for index, rss_url in enumerate(subscription.rss_urls):
            site_id = subscription.sites[min(index, len(subscription.sites) - 1)] if subscription.sites else "dmhy"
            site_diagnostics = SiteSearchDiagnostics(site=site_id)
            drain_rate_limit_events(site_id)
            try:
                adapter = get_site_adapter(site_id, site_settings)
                restriction = site_usage_restriction(adapter, "subscription", respect_site_enabled=False)
                if restriction:
                    site_diagnostics.stop_reason, message = restriction
                    site_diagnostics.warnings.append(message)
                    warnings.append(f"{site_id} RSS：{message}")
                    empty_diagnostics.site_diagnostics.append(site_diagnostics)
                    continue
                text = await adapter.fetch_text(rss_url)
                parsed_results = await adapter.parse_rss(text)
                results.extend(parsed_results)
                site_diagnostics.pages_fetched = 1
                site_diagnostics.total_fetched = len(parsed_results)
                site_diagnostics.total_unique = len(parsed_results)
                site_diagnostics.stop_reason = "no_next_page"
            except Exception as exc:
                message = describe_site_error(exc)
                warnings.append(f"{site_id} RSS：{message}")
                site_diagnostics.error = message
                site_diagnostics.completed_all_accessible_pages = False
                site_diagnostics.stop_reason = "site_error"
            finally:
                site_diagnostics.rate_limit_events.extend(event.message for event in drain_rate_limit_events(site_id))
                empty_diagnostics.site_diagnostics.append(site_diagnostics)
        empty_diagnostics.total_fetched = len(results)
        empty_diagnostics.total_unique = len(results)
        empty_diagnostics.pages_fetched = sum(item.pages_fetched for item in empty_diagnostics.site_diagnostics)
        empty_diagnostics.completed_all_accessible_pages = all(item.completed_all_accessible_pages for item in empty_diagnostics.site_diagnostics)
        empty_diagnostics.stop_reasons = [
            f"{item.site}: {item.stop_reason}"
            for item in empty_diagnostics.site_diagnostics
            if item.stop_reason
        ]
        return results, warnings, empty_diagnostics

    if subscription.source_type != "keyword":
        warnings.append("订阅来源无效，已跳过刷新。")
        return results, warnings, empty_diagnostics

    results, search_warnings, diagnostics = await search_multi_site(
        subscription.keyword,
        subscription.sites,
        max_pages=max_pages,
        page_size=page_size,
        site_settings=site_settings,
        timeout_seconds=timeout_seconds,
        respect_site_enabled=False,
        site_purpose="subscription",
    )
    return results, [*warnings, *search_warnings], diagnostics


async def _fetch_subscription_results_with_settings(
    subscription: Subscription,
    site_settings: dict | None,
) -> tuple[list[SearchResult], list[str]]:
    response = await _fetch_subscription_results_with_settings_detailed(subscription, site_settings)
    return response[0], response[1]


async def _fetch_subscription_results_with_settings_detailed(
    subscription: Subscription,
    site_settings: dict | None,
    *,
    max_pages: int | None = None,
    timeout_seconds: float = 15,
) -> tuple[list[SearchResult], list[str], SearchDiagnostics]:
    try:
        if max_pages is None:
            response = await fetch_subscription_results(subscription, site_settings, timeout_seconds=timeout_seconds)
        else:
            response = await fetch_subscription_results(subscription, site_settings, max_pages=max_pages, timeout_seconds=timeout_seconds)
    except TypeError as exc:
        if "positional" not in str(exc) and "argument" not in str(exc):
            raise
        response = await fetch_subscription_results(subscription)
    if len(response) == 2:
        results, warnings = response
        diagnostics = SearchDiagnostics(total_fetched=len(results), total_unique=len(results))
        return results, warnings, diagnostics
    return response


async def _sync_mikan_total_episodes(
    store: Store,
    subscription: Subscription,
    warnings: list[str],
    diagnostics: SearchDiagnostics,
    *,
    timeout_seconds: float = 15,
) -> None:
    if "mikan" not in subscription.sites:
        return
    mikan_diagnostics = next((item for item in diagnostics.site_diagnostics if item.site == "mikan"), None)
    if mikan_diagnostics and mikan_diagnostics.stop_reason in {"timeout", "site_rate_limited", "site_error"}:
        warnings.append("mikan 总集数：本轮资源请求未完成，已保留现有总集数。")
        return
    adapter = get_site_adapter("mikan", store.get_runtime_config("site_settings") or {})
    bangumi_id_from_keyword = getattr(adapter, "bangumi_id_from_keyword", None)
    total_episodes_from_html = getattr(adapter, "total_episodes_from_html", None)
    if bangumi_id_from_keyword is None or total_episodes_from_html is None:
        return
    bangumi_id = bangumi_id_from_keyword(subscription.mikan_bangumi_url or subscription.source_url or subscription.keyword)
    if not bangumi_id:
        return
    drain_rate_limit_events("mikan")
    try:
        html = await asyncio.wait_for(
            adapter.fetch_text(f"{adapter.base_url}/Home/Bangumi/{bangumi_id}"),
            timeout=max(1.0, float(timeout_seconds)),
        )
        total_episodes = total_episodes_from_html(html)
    except asyncio.TimeoutError:
        warnings.append("mikan 总集数：请求超时，已保留现有总集数。")
        return
    except Exception as exc:
        warnings.append(f"mikan 总集数：{describe_site_error(exc)}")
        return
    finally:
        _append_rate_limit_events(diagnostics, "mikan")
    if not total_episodes:
        return

    data = store.get_subscription(subscription.id)
    if data is None:
        return
    data["metadata_episode_count"] = total_episodes
    if data.get("total_episodes") is None or data.get("total_episodes_source") != "manual":
        data["total_episodes"] = total_episodes
        data["total_episodes_source"] = "mikan"
    payload = SubscriptionCreate(**data).model_dump(mode="json")
    store.update_subscription(subscription.id, payload)


def _subscription_refresh_lock(store: Store, subscription_id: int) -> asyncio.Lock:
    key = (str(store.path.expanduser().resolve(strict=False)), subscription_id)
    lock = _SUBSCRIPTION_REFRESH_LOCKS.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _SUBSCRIPTION_REFRESH_LOCKS[key] = lock
    return lock


def _prefer_largest_single_episode_resources(
    subscription: Subscription,
    results: list[SearchResult],
    episode_parse_rules: list[EpisodeParseRule],
) -> tuple[list[SearchResult], list[tuple[SearchResult, str]]]:
    preferred_by_episode: dict[tuple[int, int], tuple[int, int | None]] = {}
    rejected: dict[int, str] = {}

    for index, result in enumerate(results):
        parsed = analyze_search_result(
            result,
            episode_parse_rules,
            context_season_number=subscription.season,
        ).effective
        if is_collection_parsed(parsed) or parsed.resource_type != "single_episode":
            continue
        episode_keys = episode_keys_for_parsed_title(subscription, parsed)
        if len(episode_keys) != 1:
            continue
        episode_key = next(iter(episode_keys))
        size_bytes = resource_total_size_bytes(result)
        current = preferred_by_episode.get(episode_key)
        if current is None:
            preferred_by_episode[episode_key] = (index, size_bytes)
            continue

        current_index, current_size = current
        should_replace = size_bytes is not None and (current_size is None or size_bytes > current_size)
        if should_replace:
            rejected[current_index] = (
                "同集存在体积已知的资源"
                if current_size is None
                else "同集存在更大体积资源"
            )
            preferred_by_episode[episode_key] = (index, size_bytes)
        else:
            if current_size is None and size_bytes is None:
                rejected[index] = "同集资源体积均未知，已按稳定顺序选择一个"
            elif size_bytes is None:
                rejected[index] = "同集存在体积已知的资源"
            else:
                rejected[index] = "同集存在体积更大或相同且排序更靠前的资源"

    selected = [result for index, result in enumerate(results) if index not in rejected]
    skipped = [(result, rejected[index]) for index, result in enumerate(results) if index in rejected]
    return selected, skipped


async def refresh_subscription(
    store: Store,
    subscription: Subscription,
    *,
    qbittorrent_config: QbittorrentConfig | None = None,
    auto_download_enabled: bool = True,
) -> RefreshResponse:
    async with _subscription_refresh_lock(store, subscription.id):
        return await _refresh_subscription_once(
            store,
            subscription,
            qbittorrent_config=qbittorrent_config,
            auto_download_enabled=auto_download_enabled,
        )


async def _refresh_subscription_once(
    store: Store,
    subscription: Subscription,
    *,
    qbittorrent_config: QbittorrentConfig | None = None,
    auto_download_enabled: bool = True,
) -> RefreshResponse:
    warnings: list[str] = []
    if not subscription.enabled:
        history = store.add_subscription_refresh_history(
            subscription_id=subscription.id,
            matched_count=0,
            added_count=0,
            skipped_count=0,
            error_count=0,
            warnings=["订阅已停用，未刷新。"],
        )
        return RefreshResponse(
            subscription_id=subscription.id,
            refresh_history_id=history["id"],
            warnings=["订阅已停用，未刷新。"],
        )

    search_settings = store.get_config("search_settings") or {}
    timeout_seconds = float(search_settings.get("site_timeout_seconds") or 15)
    results, fetch_warnings, search_diagnostics = await _fetch_subscription_results_with_settings_detailed(
        subscription,
        store.get_runtime_config("site_settings") or {},
        timeout_seconds=timeout_seconds,
    )
    warnings.extend(fetch_warnings)
    await _sync_mikan_total_episodes(
        store,
        subscription,
        warnings,
        search_diagnostics,
        timeout_seconds=timeout_seconds,
    )
    effective_rules = _effective_episode_rules(store, subscription)
    matched, diagnostics = match_results_with_diagnostics(store, subscription, results, effective_rules)
    diagnostics.search_diagnostics = search_diagnostics
    diagnostics.pages_fetched = search_diagnostics.pages_fetched
    diagnostics.total_unique = search_diagnostics.total_unique
    diagnostics.stop_reasons = search_diagnostics.stop_reasons
    diagnostics.reached_max_pages = search_diagnostics.reached_max_pages
    diagnostics.completed_all_accessible_pages = search_diagnostics.completed_all_accessible_pages
    diagnostics.reached_internal_safety_limit = search_diagnostics.reached_internal_safety_limit
    diagnostics.has_more = search_diagnostics.has_more
    fresh, history_skipped = dedupe_results(store, matched)
    skipped = list(history_skipped)
    download_candidates = list(fresh)
    fulfillment_blocked_fingerprints: set[str] = set()
    fulfillment_skip_count = 0
    if auto_download_enabled and subscription.auto_download and fresh:
        media_index = build_subscription_episode_media_index(subscription, store)
        active_episode_keys = submitted_episode_keys(subscription, store)
        download_candidates = []
        for result in fresh:
            parsed = analyze_search_result(
                result,
                effective_rules,
                context_season_number=subscription.season,
            ).effective
            decision = automatic_download_fulfillment_decision(
                subscription,
                parsed,
                media_index,
            )
            reason = decision.reason
            if not reason and decision.episode_keys.intersection(active_episode_keys):
                reason = "该剧集已有有效下载任务或等待整理记录"
            if reason:
                fingerprint = fingerprint_result(result)
                fulfillment_blocked_fingerprints.add(fingerprint)
                fulfillment_skip_count += 1
                skipped.append(result)
                warnings.append(f"{reason}，跳过自动下载：{result.title}")
                continue
            download_candidates.append(result)
    size_preference_skip_count = 0
    if auto_download_enabled and subscription.auto_download and download_candidates:
        download_candidates, size_preference_skipped = _prefer_largest_single_episode_resources(
            subscription,
            download_candidates,
            effective_rules,
        )
        size_preference_skip_count = len(size_preference_skipped)
        for result, reason in size_preference_skipped:
            skipped.append(result)
            warnings.append(f"{reason}，跳过自动下载：{result.title}")
    added: list[SearchResult] = []
    pending_results: list[SearchResult] = []
    reconciled_results: list[SearchResult] = []
    failed_results: list[SearchResult] = []
    deferred_results: list[SearchResult] = []
    history_ids: dict[str, int] = {}
    confirmed_sizes: dict[str, int] = {}
    failure_messages: dict[str, str] = {}
    reconciled_pending_count = 0
    match_records: list[SubscriptionMatch] = []

    statuses = {fingerprint_result(result): "new" for result in fresh}
    for result in skipped:
        fingerprint = fingerprint_result(result)
        history_item = store.get_history_by_fingerprint(fingerprint)
        history_status = str((history_item or {}).get("status") or "")
        statuses[fingerprint] = history_status if history_status not in {"", "error", "dry_run"} else "skipped"

    if auto_download_enabled and subscription.auto_download:
        downloader_type = stored_downloader_routing(store).subscription_downloader
        try:
            if downloader_type == "qbittorrent" and qbittorrent_config is not None:
                client: DownloaderClient = QbittorrentClient(qbittorrent_config)
                downloader_config = qbittorrent_config
            elif downloader_type == "qbittorrent" and not store.get_runtime_config("qbittorrent"):
                raise DownloaderError("qBittorrent 用户名或密码未配置")
            else:
                client = downloader_client(store, downloader_type)
                downloader_config = getattr(client, "config", None)
            if downloader_config is None:
                raise RuntimeError(f"{downloader_display_name(downloader_type)} 尚未配置")
        except Exception as exc:
            error_message = describe_downloader_error(downloader_type, exc)
            warnings.append(f"订阅已开启自动下载，但 {error_message}。")
            for result in download_candidates:
                statuses[fingerprint_result(result)] = "error"
                failed_results.append(result)
                failure_messages[fingerprint_result(result)] = error_message
        else:
            async with _submission_session(client):
                reconciliation = await reconcile_pending_confirmations(
                    store,
                    client=client,
                    subscription_id=subscription.id,
                    manage_session=False,
                )
                reconciled_pending_count = int(reconciliation.get("confirmed") or 0)
                if reconciled_pending_count:
                    warnings.append(f"已协调确认 {reconciliation['confirmed']} 个等待中的下载任务。")
                warnings.extend(str(item) for item in reconciliation.get("warnings") or [])
                for result in skipped:
                    fingerprint = fingerprint_result(result)
                    history_item = store.get_history_by_fingerprint(fingerprint)
                    history_status = str((history_item or {}).get("status") or "")
                    statuses[fingerprint] = history_status if history_status not in {"", "dry_run"} else "skipped"

                degraded_streak = 0
                deferred_count = 0
                decided_episode_keys: set[tuple[int, int]] = set()
                for result in download_candidates:
                    fingerprint = fingerprint_result(result)
                    if degraded_streak >= 2:
                        statuses[fingerprint] = "deferred"
                        deferred_count += 1
                        deferred_results.append(result)
                        continue
                    if not should_auto_download(subscription, result, effective_rules):
                        warnings.append(f"合集资源按当前策略仅显示，不自动下载：{result.title}")
                        continue
                    parsed = analyze_search_result(
                        result,
                        effective_rules,
                        context_season_number=subscription.season,
                    ).effective
                    media_index = build_subscription_episode_media_index(subscription, store)
                    decision = automatic_download_fulfillment_decision(
                        subscription,
                        parsed,
                        media_index,
                    )
                    current_keys = set(decision.episode_keys)
                    reason = decision.reason
                    if not reason and current_keys.intersection(
                        submitted_episode_keys(subscription, store)
                    ):
                        reason = "该剧集已有有效下载任务或等待整理记录"
                    if not reason and current_keys.intersection(decided_episode_keys):
                        reason = "同一剧集本轮已有自动下载决策"
                    if reason:
                        statuses[fingerprint] = "skipped"
                        fulfillment_blocked_fingerprints.add(fingerprint)
                        fulfillment_skip_count += 1
                        if result not in skipped:
                            skipped.append(result)
                        warnings.append(f"{reason}，跳过自动下载：{result.title}")
                        continue
                    decided_episode_keys.update(current_keys)
                    url = result.magnet_url or result.download_url
                    if not url:
                        warnings.append(f"资源没有可下载链接：{result.title}")
                        statuses[fingerprint] = "error"
                        failed_results.append(result)
                        failure_messages[fingerprint] = "资源没有可下载链接"
                        continue
                    try:
                        effective_save_path = _download_save_path(subscription.save_path or downloader_config.default_save_path, subscription.name)
                        category = subscription.category or (downloader_config.default_category if isinstance(downloader_config, QbittorrentConfig) else None)
                        default_tags = downloader_config.default_tags if isinstance(downloader_config, QbittorrentConfig) else downloader_config.default_labels
                        lookup_tag = subscription_download_tag(subscription.id, fingerprint) if downloader_type == "qbittorrent" else None
                        submission_tags = list(dict.fromkeys([*(subscription.tags or default_tags), *([lookup_tag] if lookup_tag else [])]))
                        add_result = await submit_result_to_downloader(
                            client,
                            result,
                            save_path=effective_save_path,
                            category=category,
                            tags=submission_tags,
                            lookup_tag=lookup_tag,
                            site_settings=store.get_runtime_config("site_settings") or {},
                        )
                        history_status = "pending_confirmation" if add_result.pending_confirmation else "queued"
                        history_id = record_processed(
                            store,
                            result,
                            subscription_id=subscription.id,
                            status=history_status,
                            qbittorrent_hash=add_result.torrent_hash,
                            downloader_type=downloader_type,
                            remote_task_id=add_result.remote_task_id,
                            torrent_name=add_result.torrent_name or result.title,
                            save_path=effective_save_path,
                        )
                        history_ids[fingerprint] = history_id
                        statuses[fingerprint] = history_status
                        if add_result.pending_confirmation:
                            _remember_pending_confirmation(store, subscription, result, add_result, lookup_tag)
                            pending_results.append(result)
                            warnings.append(f"{downloader_display_name(downloader_type)} 已接收请求，等待确认任务：{result.title}")
                            degraded_streak = degraded_streak + 1 if add_result.response_type in DEGRADED_RESPONSE_TYPES else 0
                            continue
                        degraded_streak = 0
                        if downloader_type != "qbittorrent" or not (add_result.torrent_hash and add_result.torrent_name):
                            await _remember_submitted_torrent(
                                client,
                                store,
                                history_id,
                                result,
                                effective_save_path,
                                downloader_type,
                                add_result,
                            )
                        if downloader_type == "qbittorrent":
                            mapped_history = store.get_history(history_id) or {}
                            with suppress(Exception):
                                await release_subscription_download_tag(
                                    client,
                                    lookup_tag,
                                    torrent_hash=add_result.torrent_hash or mapped_history.get("qbittorrent_hash"),
                                )
                        if add_result.duplicate:
                            skipped.append(result)
                            reconciled_results.append(result)
                            warnings.append(f"{downloader_display_name(downloader_type)} 任务已存在，已完成映射：{result.title}")
                        else:
                            notification_size = resource_total_size_bytes(result) or add_result.content_size or await confirmed_task_size_bytes(client, add_result)
                            if notification_size:
                                confirmed_sizes[fingerprint] = notification_size
                            added.append(result)
                    except Exception as exc:
                        error_message = describe_downloader_error(downloader_type, exc)
                        warnings.append(f"{downloader_display_name(downloader_type)} 添加任务失败：{result.title}，{error_message}")
                        statuses[fingerprint] = "error"
                        degraded_streak += 1
                        failed_results.append(result)
                        failure_messages[fingerprint] = error_message
                if deferred_count:
                    warnings.append(f"下载器服务连续异常，本轮停止后续提交 {deferred_count} 条，等待下次刷新。")

    for result in matched:
        parsed = analyze_search_result(
            result,
            effective_rules,
            context_season_number=subscription.season,
        ).effective
        record = store.upsert_subscription_match(
            subscription_id=subscription.id,
            fingerprint=fingerprint_result(result),
            result=result.model_dump(mode="json"),
            parsed_title=parsed.model_dump(mode="json"),
            status=statuses.get(fingerprint_result(result), "matched"),
        )
        match_records.append(SubscriptionMatch(**record))

    error_count = sum(1 for item in match_records if item.status == "error")
    fulfillment_summary = (
        f"，已满足剧集跳过 {fulfillment_skip_count} 条"
        if fulfillment_skip_count
        else ""
    )
    size_preference_summary = (
        f"，同集体积择优跳过 {size_preference_skip_count} 条"
        if size_preference_skip_count
        else ""
    )
    detail_parts: list[str] = []
    if diagnostics.excluded_by_batch_policy or diagnostics.excluded_by_episode_coverage:
        detail_parts.append(
            f"其中合集策略排除 {diagnostics.excluded_by_batch_policy} 条、范围未覆盖 {diagnostics.excluded_by_episode_coverage} 条"
        )
    if diagnostics.matched_by_subtitle or diagnostics.episode_parsed_from_subtitle:
        detail_parts.append(
            f"副标题番名命中 {diagnostics.matched_by_subtitle} 条、副标题集数解析 {diagnostics.episode_parsed_from_subtitle} 条"
        )
    detail_summary = "".join(f"{item}，" for item in detail_parts)
    diagnostic_summary = (
        f"抓取 {diagnostics.total_fetched} 条，匹配 {diagnostics.matched_count} 条，"
        f"字幕组过滤 {diagnostics.excluded_by_fansub} 条，包含词过滤 {diagnostics.excluded_by_include} 条，"
        f"排除词过滤 {diagnostics.excluded_by_exclude} 条，分辨率过滤 {diagnostics.excluded_by_resolution} 条，体积过滤 {diagnostics.excluded_by_size} 条，"
        f"正则过滤 {diagnostics.excluded_by_regex} 条，集数过滤 {diagnostics.excluded_by_episode_filter} 条，"
        f"{detail_summary}"
        f"季度不匹配排除 {diagnostics.excluded_by_season_mismatch} 条，metadata 不匹配排除 {diagnostics.excluded_by_metadata_mismatch + diagnostics.excluded_by_bangumi_id_mismatch} 条，"
        f"重复跳过 {diagnostics.duplicate_count} 条{fulfillment_summary}{size_preference_summary}，等待下载器确认 {len(pending_results)} 条。"
    )
    response_warnings = [*warnings, diagnostic_summary]
    history = store.add_subscription_refresh_history(
        subscription_id=subscription.id,
        matched_count=len(matched),
        added_count=len(added),
        skipped_count=len(skipped),
        error_count=error_count,
        warnings=response_warnings,
    )
    notification_results = [
        result
        for result in download_candidates
        if fingerprint_result(result) not in fulfillment_blocked_fingerprints
    ]
    if auto_download_enabled and subscription.auto_download and len(notification_results) >= 2:
        event = download_batch_summary_event(
            store,
            subscription,
            notification_results,
            event_key=f"download_batch_summary:{subscription.id}:{history['id']}",
            matched_count=len(matched),
            added_count=len(added),
            reconciled_count=len(reconciled_results) + reconciled_pending_count,
            pending_count=len(pending_results),
            failed_count=len(failed_results),
            deferred_count=len(deferred_results),
            added_results=added,
            size_bytes_by_fingerprint=confirmed_sizes,
            downloader_type=downloader_type,
        )
        targets = [
            history_size_target(history_ids[fingerprint_result(item)], confirmed_sizes.get(fingerprint_result(item)) or resource_total_size_bytes(item))
            for item in added
            if history_ids.get(fingerprint_result(item)) is not None
        ]
        await send_or_defer_size_notification(store, event, targets)
    elif auto_download_enabled and subscription.auto_download and len(notification_results) == 1:
        result = notification_results[0]
        fingerprint = fingerprint_result(result)
        if result in added:
            history_item = store.get_history_by_fingerprint(fingerprint) or {}
            history_id = history_ids.get(fingerprint)
            event = download_started_event(
                store,
                subscription,
                result,
                history_id,
                history_item.get("save_path"),
                size_bytes=confirmed_sizes.get(fingerprint),
                downloader_type=downloader_type,
            )
            targets = [history_size_target(history_id, confirmed_sizes.get(fingerprint) or resource_total_size_bytes(result))] if history_id is not None else []
            await send_or_defer_size_notification(store, event, targets)
        elif result in failed_results:
            await NotificationService(store).send_best_effort(
                download_failed_event(store, subscription, result, failure_messages.get(fingerprint, "下载任务提交失败"))
            )
        elif result in pending_results:
            await NotificationService(store).send_best_effort(
                download_batch_summary_event(
                    store,
                    subscription,
                    [result],
                    event_key=f"download_submission_summary:{subscription.id}:{history['id']}",
                    matched_count=len(matched),
                    added_count=0,
                    reconciled_count=0,
                    pending_count=1,
                    failed_count=0,
                )
            )
        else:
            event = subscription_new_resource_event(store, subscription, notification_results)
            if event is not None:
                await NotificationService(store).send_best_effort(event)
    else:
        event = subscription_new_resource_event(store, subscription, notification_results)
        if event is not None:
            await NotificationService(store).send_best_effort(event)
    return RefreshResponse(
        subscription_id=subscription.id,
        refresh_history_id=history["id"],
        matched=matched,
        added=added,
        skipped=skipped,
        pending=pending_results,
        match_records=match_records,
        warnings=response_warnings,
        diagnostics=diagnostics,
    )


async def refresh_all_enabled(
    store: Store,
    *,
    qbittorrent_config: QbittorrentConfig | None = None,
    auto_download_enabled: bool = True,
) -> RefreshAllResponse:
    responses: list[RefreshResponse] = []
    warnings: list[str] = []
    skipped = 0
    for item in sorted(store.list_subscriptions(), key=lambda row: int(row.get("id") or 0)):
        subscription = Subscription(**item)
        if not subscription.enabled:
            skipped += 1
            continue
        try:
            responses.append(
                await refresh_subscription(
                    store,
                    subscription,
                    qbittorrent_config=qbittorrent_config,
                    auto_download_enabled=auto_download_enabled,
                )
            )
        except sqlite3.Error:
            # Failure notifications read poster and notification settings from
            # the same database, so a database error must end this cycle here.
            raise
        except Exception as exc:
            message = describe_site_error(exc)
            warnings.append(f"订阅 {subscription.id} 刷新失败：{message}")
            await NotificationService(store).send_best_effort(subscription_refresh_failed_event(store, subscription, message))
    return RefreshAllResponse(refreshed=len(responses), responses=responses, warnings=warnings, skipped=skipped)
