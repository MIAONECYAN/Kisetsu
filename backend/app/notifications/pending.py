from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

from app.db import Store
from app.notifications.models import NotificationEvent, NotificationTestResponse
from app.notifications.service import NotificationService
from app.notifications.templates import event_with_confirmed_size, event_with_temporarily_unknown_size, normalized_size_bytes
from app.services.downloads import task_total_size_bytes


PENDING_SIZE_NOTIFICATIONS_KEY = "pending_download_size_notifications"
PENDING_SIZE_TIMEOUT_SECONDS = 120


def history_size_target(history_id: int, size_bytes: int | None = None) -> dict[str, Any]:
    return {"kind": "history", "id": int(history_id), "size_bytes": normalized_size_bytes(size_bytes)}


def brush_size_target(task_id: int, size_bytes: int | None = None) -> dict[str, Any]:
    return {"kind": "brush", "id": int(task_id), "size_bytes": normalized_size_bytes(size_bytes)}


def _pending(store: Store) -> dict[str, dict[str, Any]]:
    data = store.get_config(PENDING_SIZE_NOTIFICATIONS_KEY) or {}
    return {str(key): value for key, value in data.items() if isinstance(value, dict)}


def _save_pending(store: Store, values: dict[str, dict[str, Any]]) -> None:
    if values:
        store.set_config(PENDING_SIZE_NOTIFICATIONS_KEY, values)
    else:
        store.delete_config(PENDING_SIZE_NOTIFICATIONS_KEY)


async def send_or_defer_size_notification(
    store: Store,
    event: NotificationEvent,
    targets: list[dict[str, Any]],
    *,
    timeout_seconds: int = PENDING_SIZE_TIMEOUT_SECONDS,
) -> NotificationTestResponse | None:
    if normalized_size_bytes(event.size_bytes) is not None or not targets:
        return await NotificationService(store).send_best_effort(event)

    now = datetime.now(timezone.utc)
    pending = _pending(store)
    pending[event.event_key] = {
        "event": event.model_dump(mode="json"),
        "targets": targets,
        "queued_at": now.isoformat(),
        "deadline_at": (now + timedelta(seconds=max(10, int(timeout_seconds)))).isoformat(),
    }
    _save_pending(store, pending)
    return None


def _snapshot_size(
    downloader_type: str,
    torrent_hash: str | None,
    remote_task_id: str | None,
    snapshots: dict[str, list[dict[str, Any]]],
) -> int | None:
    items = snapshots.get(downloader_type) or []
    candidates: list[dict[str, Any]] = []
    if downloader_type == "qbittorrent" and torrent_hash:
        expected = torrent_hash.casefold()
        candidates = [item for item in items if str(item.get("hash") or "").casefold() == expected]
    elif downloader_type == "transmission" and remote_task_id:
        expected = str(remote_task_id)
        candidates = [item for item in items if str(item.get("remote_id") or "") == expected]
    if len(candidates) != 1:
        return None
    return task_total_size_bytes(candidates[0])


def _target_size(
    store: Store,
    target: dict[str, Any],
    snapshots: dict[str, list[dict[str, Any]]],
    brush_task_lookup: Callable[[int], Any] | None,
) -> int | None:
    known = normalized_size_bytes(target.get("size_bytes"))
    if known is not None:
        return known
    identifier = target.get("id")
    if not isinstance(identifier, int):
        return None
    if target.get("kind") == "history":
        history = store.get_history(identifier)
        if not history:
            return None
        return _snapshot_size(
            str(history.get("downloader_type") or "qbittorrent"),
            str(history.get("qbittorrent_hash") or "") or None,
            str(history.get("remote_task_id") or "") or None,
            snapshots,
        )
    if target.get("kind") == "brush" and brush_task_lookup is not None:
        task = brush_task_lookup(identifier)
        if task is None:
            return None
        task_size = normalized_size_bytes(getattr(task, "size_bytes", None))
        if task_size is not None:
            return task_size
        return _snapshot_size(
            str(getattr(task, "downloader_type", None) or "qbittorrent"),
            getattr(task, "qbittorrent_hash", None),
            str(getattr(task, "remote_task_id", None) or "") or None,
            snapshots,
        )
    return None


def _parse_deadline(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


async def flush_pending_size_notifications(
    store: Store,
    snapshots: dict[str, list[dict[str, Any]]],
    *,
    brush_task_lookup: Callable[[int], Any] | None = None,
    now: datetime | None = None,
) -> dict[str, int]:
    pending = _pending(store)
    if not pending:
        return {"checked_count": 0, "sent_count": 0, "waiting_count": 0}

    current = now or datetime.now(timezone.utc)
    sent = 0
    waiting = 0
    for event_key, record in list(pending.items()):
        if store.notification_event_sent(event_key, "bark"):
            pending.pop(event_key, None)
            continue
        try:
            event = NotificationEvent.model_validate(record.get("event"))
        except Exception:
            pending.pop(event_key, None)
            continue
        targets = [target for target in record.get("targets", []) if isinstance(target, dict)]
        sizes = [_target_size(store, target, snapshots, brush_task_lookup) for target in targets]
        resolved = bool(targets) and all(size is not None for size in sizes)
        deadline = _parse_deadline(record.get("deadline_at"))
        if not resolved and (deadline is None or current < deadline):
            waiting += 1
            continue
        if resolved:
            event = event_with_confirmed_size(event, sum(int(size) for size in sizes if size is not None))
        else:
            event = event_with_temporarily_unknown_size(event)
        response = await NotificationService(store).send_best_effort(event)
        if response is not None:
            sent += int(response.ok and response.provider == "bark")
            pending.pop(event_key, None)
        else:
            waiting += 1
    _save_pending(store, pending)
    return {"checked_count": len(pending) + sent, "sent_count": sent, "waiting_count": waiting}
