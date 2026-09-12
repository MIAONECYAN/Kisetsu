from __future__ import annotations

import hashlib
from pathlib import Path

from app.models import SearchResult, Subscription
from app.notifications.models import NotificationEvent
from app.services.subscription import fingerprint_result
from app.services.title_parser import parse_title
from app.sites import get_site_adapter


def format_size_bytes(value: int | None) -> str:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return "未知"
    size = float(value)
    units = ("B", "KB", "MB", "GB", "TB")
    unit = units[0]
    for candidate in units[1:]:
        if size < 1024:
            break
        size /= 1024
        unit = candidate
    if unit == "B" or size >= 100:
        return f"{size:.0f} {unit}"
    text = f"{size:.1f}".rstrip("0").rstrip(".")
    return f"{text} {unit}"


def normalized_size_bytes(value: int | None) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def event_with_confirmed_size(event: NotificationEvent, size_bytes: int) -> NotificationEvent:
    actual_size = normalized_size_bytes(size_bytes)
    if actual_size is None:
        return event
    updated = event.model_copy(deep=True)
    updated.size_bytes = actual_size
    updated.extra["size_bytes"] = actual_size
    size_line = f"体积：{format_size_bytes(actual_size)}"
    lines = updated.body.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("体积："):
            lines[index] = size_line
            break
    else:
        lines.append(size_line)
    updated.body = "\n".join(lines)
    return updated


def event_with_temporarily_unknown_size(event: NotificationEvent) -> NotificationEvent:
    updated = event.model_copy(deep=True)
    lines = updated.body.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("体积："):
            lines[index] = "体积：暂时未知"
            break
    else:
        lines.append("体积：暂时未知")
    updated.body = "\n".join(lines)
    return updated


def site_display_name(site_id: str | None) -> str:
    value = (site_id or "").strip()
    if not value:
        return "未知"
    try:
        return get_site_adapter(value).display_name
    except Exception:
        return value


def new_download_body(
    resource_title: str,
    *,
    download_source: str,
    downloader_type: str,
    site_name: str,
    size_bytes: int | None,
    prefix: str | None = None,
) -> str:
    heading = " · ".join(item for item in (prefix, resource_title) if item)
    return "\n".join(
        (
            heading,
            f"来源：{download_source}",
            f"下载器：{'Transmission' if downloader_type == 'transmission' else 'qBittorrent'}",
            f"站点：{site_name}",
            f"体积：{format_size_bytes(size_bytes)}",
        )
    )


def episode_label(season: int | None, episode: int | None) -> str | None:
    if season is not None and episode is not None:
        return f"S{season:02d}E{episode:02d}"
    if episode is not None:
        return f"第 {episode} 集"
    return None


def _number_ranges(numbers: list[int]) -> list[tuple[int, int]]:
    if not numbers:
        return []
    ranges: list[tuple[int, int]] = []
    start = previous = numbers[0]
    for number in numbers[1:]:
        if number == previous + 1:
            previous = number
            continue
        ranges.append((start, previous))
        start = previous = number
    ranges.append((start, previous))
    return ranges


def compact_episode_ranges(subscription: Subscription, results: list[SearchResult]) -> str | None:
    episodes_by_season: dict[int | None, set[int]] = {}
    for result in results:
        parsed = parse_title(
            result.title,
            subscription.episode_parse_rules,
            context_season_number=subscription.season,
        )
        season = parsed.explicit_season_number or parsed.season_number or subscription.season
        start = parsed.episode or parsed.episode_start
        end = parsed.episode_end or start
        if start is None:
            continue
        if end is None or end < start or end - start > 200:
            end = start
        episodes_by_season.setdefault(season, set()).update(range(start, end + 1))

    labels: list[str] = []
    for season in sorted(episodes_by_season, key=lambda value: (value is None, value or 0)):
        ranges = _number_ranges(sorted(episodes_by_season[season]))
        if season is None:
            for start, end in ranges:
                labels.append(f"第 {start} 集" if start == end else f"第 {start}-{end} 集")
            continue
        prefix = f"S{season:02d}"
        for start, end in ranges:
            labels.append(f"{prefix}E{start:02d}" if start == end else f"{prefix}E{start:02d}-E{end:02d}")
    return "、".join(labels) or None


def download_batch_summary_event(
    store,
    subscription: Subscription,
    results: list[SearchResult],
    *,
    event_key: str,
    matched_count: int,
    added_count: int,
    reconciled_count: int,
    pending_count: int,
    failed_count: int,
    deferred_count: int = 0,
    final_failure: bool = False,
    added_results: list[SearchResult] | None = None,
    size_bytes_by_fingerprint: dict[str, int] | None = None,
    downloader_type: str | None = None,
) -> NotificationEvent:
    episode_range = compact_episode_ranges(subscription, results)
    parts = [f"匹配 {matched_count}", f"新增 {added_count}", f"已协调 {reconciled_count}"]
    if pending_count:
        parts.append(f"待确认 {pending_count}")
    if deferred_count:
        parts.append(f"延后 {deferred_count}")
    parts.append(f"失败 {failed_count}")
    summary = " · ".join([*([episode_range] if episode_range else []), *parts])
    added_items = added_results or []
    known_sizes = [
        (size_bytes_by_fingerprint or {}).get(fingerprint_result(item)) or item.size_bytes
        for item in added_items
    ]
    total_size = (
        sum(int(value) for value in known_sizes)
        if added_items and all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in known_sizes)
        else None
    )
    first = results[0] if results else None
    site_names = list(dict.fromkeys(site_display_name(item.source) for item in added_items))
    site_name = "、".join(site_names) if site_names else site_display_name(first.source if first else None)
    body = (
        "\n".join(
            (
                summary,
                "来源：订阅下载",
                f"下载器：{'Transmission' if downloader_type == 'transmission' else 'qBittorrent'}",
                f"站点：{site_name}",
                f"体积：{format_size_bytes(total_size)}",
            )
        )
        if added_count > 0
        else summary
    )[:500]
    parsed = (
        parse_title(
            first.title,
            subscription.episode_parse_rules,
            context_season_number=subscription.season,
        )
        if first
        else None
    )
    return NotificationEvent(
        event_key=event_key,
        event_type="download_batch_summary",
        title=f"{'批量下载失败' if final_failure else '批量下载'}：{subscription.name}",
        body=body,
        anime_title=subscription.name,
        poster_url=poster_url_for_subscription(store, subscription.id),
        subscription_id=subscription.id,
        season_number=(parsed.explicit_season_number or parsed.season_number or subscription.season) if parsed else subscription.season,
        episode_number=(parsed.episode or parsed.episode_start) if parsed else None,
        size_bytes=total_size,
        download_source="订阅下载" if added_count > 0 else None,
        site_name=site_name if added_count > 0 else None,
        downloader_type=downloader_type if added_count > 0 else None,
        extra={
            "episode_range": episode_range,
            "matched_count": matched_count,
            "added_count": added_count,
            "reconciled_count": reconciled_count,
            "pending_count": pending_count,
            "deferred_count": deferred_count,
            "failed_count": failed_count,
            "final_failure": final_failure,
            "size_bytes": total_size,
            "download_source": "订阅下载" if added_count > 0 else None,
            "site_name": site_name if added_count > 0 else None,
            "downloader_type": downloader_type if added_count > 0 else None,
        },
    )


def pending_failure_batch_event(
    store,
    subscription: Subscription,
    results: list[SearchResult],
    fingerprints: list[str],
) -> NotificationEvent:
    digest = hashlib.sha256("\n".join(sorted(fingerprints)).encode("utf-8")).hexdigest()[:20]
    return download_batch_summary_event(
        store,
        subscription,
        results,
        event_key=f"download_batch_final_failure:{subscription.id}:{digest}",
        matched_count=len(results),
        added_count=0,
        reconciled_count=0,
        pending_count=0,
        failed_count=len(results),
        final_failure=True,
    )


def poster_url_for_subscription(store, subscription_id: int | None) -> str | None:
    if subscription_id is None:
        return None
    for row in store.list_metadata_bindings_for_target("subscription", str(subscription_id), limit=10):
        if row.get("poster_url"):
            return row.get("poster_url")
    return None


def subscription_metadata_bound_event(store, subscription: Subscription, selected_title: str | None) -> NotificationEvent:
    title = selected_title.strip() if selected_title and selected_title.strip() else subscription.name
    return NotificationEvent(
        event_key=f"subscription_metadata_bound:{subscription.id}:{title}",
        event_type="subscription_metadata_bound",
        title=f"订阅识别完成：{subscription.name}",
        body=f"番剧信息已识别为：{title}。正在刷新订阅资源。",
        anime_title=subscription.name,
        poster_url=poster_url_for_subscription(store, subscription.id),
        subscription_id=subscription.id,
        extra={"selected_title": title},
    )


def subscription_new_resource_event(store, subscription: Subscription, results: list[SearchResult]) -> NotificationEvent | None:
    if not results:
        return None
    first = results[0]
    parsed = parse_title(first.title, subscription.episode_parse_rules, context_season_number=subscription.season)
    season = parsed.season_number or subscription.season
    episode = parsed.episode or parsed.episode_start
    label = episode_label(season, episode)
    if len(results) == 1:
        body_parts = [item for item in [label, first.title] if item]
        body = " · ".join(body_parts)
    else:
        labels = []
        for result in results[:5]:
            item = parse_title(result.title, subscription.episode_parse_rules, context_season_number=subscription.season)
            item_label = episode_label(item.season_number or subscription.season, item.episode or item.episode_start)
            labels.append(item_label or item.title or result.title)
        suffix = f"、其余 {len(results) - len(labels)} 个" if len(results) > len(labels) else ""
        body = f"本次发现 {len(results)} 个新资源：" + "、".join(labels) + suffix
    return NotificationEvent(
        event_key=f"subscription_new_resource:{subscription.id}:{','.join(fingerprint_result(item) for item in results)}",
        event_type="subscription_new_resource",
        title=f"发现新剧集：{subscription.name}",
        body=body,
        anime_title=subscription.name,
        poster_url=poster_url_for_subscription(store, subscription.id),
        subscription_id=subscription.id,
        season_number=season,
        episode_number=episode,
        resource_title=first.title,
        extra={"resource_count": len(results), "resource_titles": [item.title for item in results[:10]]},
    )


def subscription_refresh_failed_event(store, subscription: Subscription, error_message: str) -> NotificationEvent:
    return NotificationEvent(
        event_key=f"subscription_refresh_failed:{subscription.id}:{error_message[:120]}",
        event_type="subscription_refresh_failed",
        title=f"订阅刷新失败：{subscription.name}",
        body=error_message[:240],
        anime_title=subscription.name,
        poster_url=poster_url_for_subscription(store, subscription.id),
        subscription_id=subscription.id,
        error_message=error_message[:240],
    )


def download_started_event(
    store,
    subscription: Subscription | None,
    result: SearchResult,
    history_id: int | None,
    save_path: str | None = None,
    *,
    size_bytes: int | None = None,
    downloader_type: str | None = None,
) -> NotificationEvent:
    parsed = parse_title(result.title, subscription.episode_parse_rules if subscription else [], context_season_number=subscription.season if subscription else None)
    anime_title = subscription.name if subscription else (parsed.title or result.title)
    season = parsed.season_number or (subscription.season if subscription else None)
    episode = parsed.episode or parsed.episode_start
    label = episode_label(season, episode)
    actual_size = normalized_size_bytes(size_bytes) or normalized_size_bytes(result.size_bytes)
    download_source = "订阅下载" if subscription else "手动下载"
    site_name = site_display_name(result.source)
    return NotificationEvent(
        event_key=f"download_started:{history_id or fingerprint_result(result)}",
        event_type="download_started",
        title=f"开始下载：{anime_title}",
        body=new_download_body(
            result.title,
            download_source=download_source,
            downloader_type=downloader_type or "qbittorrent",
            site_name=site_name,
            size_bytes=actual_size,
            prefix=label,
        ),
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, subscription.id if subscription else None),
        subscription_id=subscription.id if subscription else None,
        download_record_id=history_id,
        season_number=season,
        episode_number=episode,
        torrent_title=result.title,
        resource_title=result.title,
        size_bytes=actual_size,
        download_source=download_source,
        site_name=site_name,
        downloader_type=downloader_type,
        extra={
            "save_path": save_path,
            "size_bytes": actual_size,
            "download_source": download_source,
            "site_name": site_name,
            "downloader_type": downloader_type,
        },
    )


def brush_task_added_event(
    *,
    run_id: int,
    task_id: int,
    title: str,
    site_name: str,
    size_bytes: int | None,
    downloader_type: str,
    discount_label: str | None = None,
) -> NotificationEvent:
    actual_size = normalized_size_bytes(size_bytes)
    return NotificationEvent(
        event_key=f"brush_task_added:{task_id}",
        event_type="brush_task_added",
        title=f"新增刷流任务：{site_name}",
        body=new_download_body(
            title,
            download_source="站点刷流",
            downloader_type=downloader_type,
            site_name=site_name,
            size_bytes=actual_size,
        ),
        resource_title=title,
        size_bytes=actual_size,
        download_source="站点刷流",
        site_name=site_name,
        downloader_type=downloader_type,
        extra={
            "brush_run_id": run_id,
            "brush_task_id": task_id,
            "size_bytes": actual_size,
            "download_source": "站点刷流",
            "site_name": site_name,
            "downloader_type": downloader_type,
            "discount_label": discount_label,
        },
    )


def download_failed_event(store, subscription: Subscription | None, result: SearchResult, error_message: str) -> NotificationEvent:
    parsed = parse_title(result.title, subscription.episode_parse_rules if subscription else [], context_season_number=subscription.season if subscription else None)
    anime_title = subscription.name if subscription else (parsed.title or result.title)
    season = parsed.season_number or (subscription.season if subscription else None)
    episode = parsed.episode or parsed.episode_start
    label = episode_label(season, episode)
    return NotificationEvent(
        event_key=f"download_failed:{subscription.id if subscription else 'manual'}:{fingerprint_result(result)}",
        event_type="download_failed",
        title=f"下载失败：{anime_title}",
        body=" · ".join(item for item in [label, error_message] if item),
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, subscription.id if subscription else None),
        subscription_id=subscription.id if subscription else None,
        season_number=season,
        episode_number=episode,
        torrent_title=result.title,
        error_message=error_message,
    )


def download_completed_event(store, history: dict) -> NotificationEvent:
    title = str(history.get("title") or "下载任务")
    subscription_id = history.get("subscription_id")
    subscription = store.get_subscription(int(subscription_id)) if subscription_id else None
    anime_title = subscription.get("name") if subscription else (parse_title(title).title or title)
    parsed = parse_title(title, context_season_number=subscription.get("season") if subscription else None)
    season = parsed.season_number or (subscription.get("season") if subscription else None)
    episode = parsed.episode or parsed.episode_start
    label = episode_label(season, episode)
    return NotificationEvent(
        event_key=f"download_completed:{history.get('id')}",
        event_type="download_completed",
        title=f"下载完成：{anime_title}",
        body=" · ".join(item for item in [label, title] if item),
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, int(subscription_id) if subscription_id else None),
        subscription_id=int(subscription_id) if subscription_id else None,
        download_record_id=int(history.get("id")),
        season_number=season,
        episode_number=episode,
        torrent_title=title,
    )


def organize_completed_event(store, record: dict, subscription: Subscription | None = None) -> NotificationEvent:
    preview = record.get("preview") or {}
    destination = str(record.get("destination_path") or "")
    source = str(record.get("source_path") or "")
    title = Path(destination).name or Path(source).name or "整理记录"
    anime_title = subscription.name if subscription else str(preview.get("show_directory") or parse_title(title).title or "Kisetsu")
    season = record.get("effective_season") or preview.get("season_number")
    parsed = parse_title(title, context_season_number=season)
    episode = parsed.episode or parsed.episode_start
    label = episode_label(season, episode)
    preview_download_id = preview.get("download_record_id")
    identity = "\n".join(
        (
            str(subscription.id if subscription else record.get("subscription_id") or "manual"),
            str(preview_download_id or "no-download-record"),
            source,
            destination,
            str(season or ""),
            str(episode or ""),
        )
    )
    identity_digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]
    return NotificationEvent(
        event_key=f"organize_completed:v2:{identity_digest}",
        event_type="organize_completed",
        title=f"整理完成：{anime_title}",
        body=" · ".join(item for item in [label, title] if item),
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, subscription.id if subscription else None),
        subscription_id=subscription.id if subscription else None,
        organize_record_id=int(record.get("id")),
        season_number=season,
        episode_number=episode,
        organized_file_name=title,
        extra={"organized_path": destination},
    )


def organize_failed_event(store, title: str, message: str, record_id: int | None = None, subscription: Subscription | None = None) -> NotificationEvent:
    anime_title = subscription.name if subscription else (parse_title(title).title or "Kisetsu")
    return NotificationEvent(
        event_key=f"organize_failed:{record_id or title}:{message}",
        event_type="organize_failed",
        title=f"整理失败：{anime_title}",
        body=f"{Path(title).name or title} · {message}",
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, subscription.id if subscription else None),
        subscription_id=subscription.id if subscription else None,
        organize_record_id=record_id,
        error_message=message,
    )


def organize_needs_review_event(store, title: str, message: str, subscription: Subscription | None = None) -> NotificationEvent:
    anime_title = subscription.name if subscription else (parse_title(title).title or "Kisetsu")
    return NotificationEvent(
        event_key=f"organize_needs_review:{title}:{message}",
        event_type="organize_needs_review",
        title=f"需要手动整理：{anime_title}",
        body=message[:240],
        anime_title=anime_title,
        poster_url=poster_url_for_subscription(store, subscription.id if subscription else None),
        subscription_id=subscription.id if subscription else None,
        error_message=message[:240],
    )
