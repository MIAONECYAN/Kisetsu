from __future__ import annotations

import hashlib
import re
from collections.abc import Iterable

from app.core.downloader import DownloaderAddResult, DownloaderClient
from app.db import Store
from app.models import SearchResult
from app.sites import get_site_adapter
from app.sites.base import coerce_size_bytes

PRIVATE_TORRENT_SITES = {"mteam", "soulvoice", "hddolby", "opencd"}
SUBSCRIPTION_DOWNLOAD_TAG_RE = re.compile(r"^kisetsu-sub-[1-9][0-9]*-[0-9a-f]{16}$")
TERMINAL_DOWNLOAD_STATUSES = {
    "dry_run",
    "deleted",
    "error",
    "organized",
    "organized_task_removed",
    "seeding_stopped",
}


def normalize_add_result(value: DownloaderAddResult | str | None, downloader_type: str) -> DownloaderAddResult:
    if isinstance(value, DownloaderAddResult):
        return value
    if not value:
        return DownloaderAddResult(downloader_type=downloader_type)
    identity = str(value)
    if downloader_type == "transmission" and identity.isdigit():
        return DownloaderAddResult(downloader_type=downloader_type, remote_task_id=identity)
    return DownloaderAddResult(downloader_type=downloader_type, torrent_hash=identity.casefold())


def resource_total_size_bytes(result: SearchResult) -> int | None:
    for value in (result.size_bytes, result.size):
        parsed = coerce_size_bytes(value)
        if isinstance(parsed, int) and not isinstance(parsed, bool) and parsed > 0:
            return parsed
    return None


def _bencoded_bytes(data: bytes, index: int) -> tuple[bytes, int]:
    colon = data.find(b":", index)
    if colon < 0 or not data[index:colon].isdigit():
        raise ValueError("invalid bencoded byte string")
    length = int(data[index:colon])
    start = colon + 1
    end = start + length
    if end > len(data):
        raise ValueError("truncated bencoded byte string")
    return data[start:end], end


def _bencoded_integer(data: bytes, index: int) -> tuple[int, int]:
    if data[index:index + 1] != b"i":
        raise ValueError("invalid bencoded integer")
    end = data.find(b"e", index + 1)
    if end < 0:
        raise ValueError("truncated bencoded integer")
    return int(data[index + 1:end]), end + 1


def _bencoded_skip(data: bytes, index: int) -> int:
    if index >= len(data):
        raise ValueError("truncated bencode value")
    token = data[index:index + 1]
    if token == b"i":
        return _bencoded_integer(data, index)[1]
    if token in {b"l", b"d"}:
        cursor = index + 1
        while cursor < len(data) and data[cursor:cursor + 1] != b"e":
            if token == b"d":
                _, cursor = _bencoded_bytes(data, cursor)
            cursor = _bencoded_skip(data, cursor)
        if cursor >= len(data):
            raise ValueError("truncated bencode collection")
        return cursor + 1
    if token.isdigit():
        return _bencoded_bytes(data, index)[1]
    raise ValueError("invalid bencode token")


def _dictionary_value_range(data: bytes, index: int, wanted_key: bytes) -> tuple[int, int] | None:
    if data[index:index + 1] != b"d":
        return None
    cursor = index + 1
    while cursor < len(data) and data[cursor:cursor + 1] != b"e":
        key, cursor = _bencoded_bytes(data, cursor)
        value_start = cursor
        cursor = _bencoded_skip(data, cursor)
        if key == wanted_key:
            return value_start, cursor
    return None


def torrent_content_size_bytes(content: bytes) -> int | None:
    """Return the exact payload length from a valid torrent metainfo document."""
    try:
        info_range = _dictionary_value_range(content, 0, b"info")
        if info_range is None:
            return None
        info_start, _ = info_range
        length_range = _dictionary_value_range(content, info_start, b"length")
        if length_range is not None:
            length, end = _bencoded_integer(content, length_range[0])
            if end == length_range[1] and length > 0:
                return length

        files_range = _dictionary_value_range(content, info_start, b"files")
        if files_range is None or content[files_range[0]:files_range[0] + 1] != b"l":
            return None
        cursor = files_range[0] + 1
        total = 0
        file_count = 0
        while cursor < files_range[1] and content[cursor:cursor + 1] != b"e":
            file_end = _bencoded_skip(content, cursor)
            file_length_range = _dictionary_value_range(content, cursor, b"length")
            if file_length_range is None:
                return None
            length, length_end = _bencoded_integer(content, file_length_range[0])
            if length_end != file_length_range[1] or length < 0:
                return None
            total += length
            file_count += 1
            cursor = file_end
        return total if file_count and total > 0 else None
    except (IndexError, TypeError, ValueError):
        return None


async def confirmed_task_size_bytes(
    client: DownloaderClient,
    add_result: DownloaderAddResult,
) -> int | None:
    if not add_result.task_identifier:
        return None
    task_by_identity = getattr(client, "task_by_identity", None)
    if not callable(task_by_identity):
        return None
    try:
        task = await task_by_identity(add_result)
    except Exception:
        return None
    return task_total_size_bytes(task)


def task_total_size_bytes(task: object) -> int | None:
    if not isinstance(task, dict):
        return None
    for key in ("total_size", "size", "totalSize"):
        value = task.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            return value
        if isinstance(value, str) and value.isdigit() and int(value) > 0:
            return int(value)
    return None


async def submit_result_to_downloader(
    client: DownloaderClient,
    result: SearchResult,
    *,
    save_path: str | None = None,
    category: str | None = None,
    tags: Iterable[str] = (),
    lookup_tag: str | None = None,
    site_settings: dict | None = None,
) -> DownloaderAddResult:
    url = result.magnet_url or result.download_url
    if result.source not in PRIVATE_TORRENT_SITES:
        if not url:
            raise ValueError("搜索结果没有可下载链接")
        return normalize_add_result(
            await client.add_url(
                url,
                save_path=save_path,
                category=category,
                tags=tags,
                lookup_tag=lookup_tag,
            ),
            getattr(client, "downloader_type", "qbittorrent"),
        )

    adapter = get_site_adapter(result.source, site_settings)
    content, filename = await adapter.download_torrent(result)
    add_result = normalize_add_result(
        await client.add_torrent_bytes(
            content,
            filename=filename,
            save_path=save_path,
            category=category,
            tags=tags,
            lookup_tag=lookup_tag,
        ),
        getattr(client, "downloader_type", "qbittorrent"),
    )
    add_result.content_size = torrent_content_size_bytes(content)
    return add_result


submit_result_to_qbittorrent = submit_result_to_downloader


def subscription_download_tag(subscription_id: int, fingerprint: str) -> str:
    digest = hashlib.sha256(f"{subscription_id}:{fingerprint}".encode("utf-8")).hexdigest()[:16]
    return f"kisetsu-sub-{subscription_id}-{digest}"


def is_subscription_download_tag(value: str) -> bool:
    return bool(SUBSCRIPTION_DOWNLOAD_TAG_RE.fullmatch(value.strip()))


def _torrent_tags(torrent: dict) -> set[str]:
    raw = torrent.get("tags")
    if isinstance(raw, str):
        return {value.strip() for value in raw.split(",") if value.strip()}
    if isinstance(raw, list):
        return {str(value).strip() for value in raw if str(value).strip()}
    return set()


async def release_subscription_download_tag(
    client: DownloaderClient,
    lookup_tag: str | None,
    *,
    torrent_hash: str | None = None,
) -> bool:
    if not lookup_tag or not is_subscription_download_tag(lookup_tag):
        return False
    remove_tags = getattr(client, "remove_tags", None)
    delete_tags = getattr(client, "delete_tags", None)
    if not callable(delete_tags) or getattr(client, "downloader_type", None) != "qbittorrent":
        return False
    if torrent_hash and callable(remove_tags):
        await remove_tags([torrent_hash], [lookup_tag])
    remaining = await client.list_torrents(tag=lookup_tag)
    if remaining:
        return False
    await delete_tags([lookup_tag])
    return True


async def cleanup_orphaned_subscription_tags(
    store: Store,
    client: DownloaderClient,
    torrents: list[dict],
) -> dict[str, int]:
    list_tags = getattr(client, "list_tags", None)
    delete_tags = getattr(client, "delete_tags", None)
    if (
        getattr(client, "downloader_type", None) != "qbittorrent"
        or not callable(list_tags)
        or not callable(delete_tags)
    ):
        return {"owned_count": 0, "protected_count": 0, "deleted_count": 0}

    histories = store.list_history(limit=100000)
    owned_tags = {
        subscription_download_tag(int(row["subscription_id"]), str(row["fingerprint"]))
        for row in histories
        if row.get("subscription_id") is not None
    }
    global_tags = await list_tags()
    candidates = {tag for tag in global_tags if tag in owned_tags and is_subscription_download_tag(tag)}
    task_tags = {tag for torrent in torrents for tag in _torrent_tags(torrent)}
    pending = store.get_config("pending_download_confirmations") or {}
    pending_tags = {
        str(value.get("lookup_tag") or "")
        for value in pending.values()
        if isinstance(value, dict)
    }
    active_history_tags = {
        subscription_download_tag(int(row["subscription_id"]), str(row["fingerprint"]))
        for row in histories
        if row.get("subscription_id") is not None
        and str(row.get("status") or "") not in TERMINAL_DOWNLOAD_STATUSES
    }
    protected = candidates.intersection(task_tags | pending_tags | active_history_tags)
    orphaned = sorted(candidates - protected)
    if orphaned:
        await delete_tags(orphaned)
    return {
        "owned_count": len(candidates),
        "protected_count": len(protected),
        "deleted_count": len(orphaned),
    }
