"""Read-only overview presentation. No title parsing or media operations."""

from app.models import DownloadHistory, OverviewOrganizedMedia, OverviewRuntimeItem


def cached_history(store):
    cached = store.get_config("download_history_state_cache") or {}
    indexed = {item["id"]: item for item in cached.get("items", []) if isinstance(item, dict) and "id" in item}
    result = []
    for row in store.list_history(limit=-1):
        snapshot = indexed.get(row["id"], {})
        if snapshot.get("fingerprint") != row["fingerprint"]:
            snapshot = {}
        # Persistent identity and lifecycle win over an older downloader snapshot.
        result.append(DownloadHistory(**{**snapshot, **row}))
    return result


def recently_organized_media(subscriptions, history, records):
    subscriptions_by_id = {item.id: item for item in subscriptions}
    history_by_id = {item.id: item for item in history}
    groups = {}
    seen_destinations = set()
    for record in sorted(records, key=lambda item: (item.created_at, item.id), reverse=True):
        if record.status != "moved" or record.destination_path in seen_destinations:
            continue
        seen_destinations.add(record.destination_path)
        preview = record.preview
        download = history_by_id.get(preview.download_record_id)
        subscription_id = record.subscription_id or (download.subscription_id if download else None)
        subscription = subscriptions_by_id.get(subscription_id)
        season = record.effective_season or record.subscription_season
        # Unlinked manual media use the already-resolved target directory, not a title guess.
        key = f"subscription:{subscription_id}" if subscription_id else f"media:{preview.media_type}:{preview.show_directory}"
        key += f":{season}"
        start, end = preview.episode_start, preview.episode_end
        episodes = []
        if preview.media_type != "movie" and not preview.is_batch and start is not None:
            episodes = list(range(start, (end or start) + 1)) if (end or start) - start < 1000 else [start]
        if key not in groups:
            groups[key] = OverviewOrganizedMedia(
                id=key, subscription_id=subscription_id, history_id=record.id,
                title=subscription.name if subscription else preview.show_directory,
                media_type=preview.media_type, episodes=episodes, season=season,
                completed_at=record.created_at,
            )
        elif (groups[key].completed_at - record.created_at).total_seconds() <= 86400:
            groups[key].episodes = sorted(set(groups[key].episodes + episodes))
    return list(groups.values())[:6]


def runtime_items(store):
    result = []
    state = store.get_config("automation_state") or {}
    result.append(OverviewRuntimeItem(
        id="subscriptions", title="订阅检查", state="unknown",
        detail="运行状态未知", checked_at=state.get("last_run_at"),
    ))
    connections = store.get_config("downloader_connection_status") or {}
    for key, name in (("qbittorrent", "qBittorrent"), ("transmission", "Transmission")):
        config = store.get_config(key)
        cached = connections.get(key) or {}
        checked = cached.get("checked_at")
        if not config and not checked:
            continue
        status = ("success" if cached.get("verified") else "failed") if checked else "configured"
        result.append(OverviewRuntimeItem(
            id=f"downloader:{key}", title=name, state=status,
            detail={"success": "最近检测成功", "failed": "最近检测失败", "configured": "已配置，尚未检测"}[status],
            checked_at=checked,
        ))
    targets = store.list_organize_targets(include_disabled=False)
    result.append(OverviewRuntimeItem(
        id="organize", title="整理目标", state="configured" if targets else "failed",
        detail=f"{len(targets)} 个可用配置" if targets else "未设置可用整理目标",
    ))
    sites = store.get_config("site_settings") or {}
    result.append(OverviewRuntimeItem(
        id="sites", title="站点", state="configured" if sites else "unknown",
        detail=f"{len(sites)} 个配置 · 连通状态未知",
    ))
    brush = store.get_config("brush_state") or {}
    result.append(OverviewRuntimeItem(
        id="brush", title="站点刷流", state="failed" if brush.get("last_error") else "unknown",
        detail="最近检查失败" if brush.get("last_error") else "运行状态未知",
        checked_at=brush.get("last_check_at"),
    ))
    plex = store.get_config("playlist_settings") or {}
    result.append(OverviewRuntimeItem(
        id="playlists", title="Plex", state="configured" if plex.get("server_url") else "unknown",
        detail="已配置 · 连接状态以播放列表读取结果为准" if plex.get("server_url") else "未配置",
    ))
    return result
