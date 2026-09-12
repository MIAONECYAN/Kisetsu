from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from typing import Any

from app.brush.service import BrushService
from app.core.downloader import DownloaderClient
from app.core.downloaders import describe_downloader_error, downloader_client, downloader_configured
from app.db import Store
from app.notifications.pending import flush_pending_size_notifications
from app.services.downloads import cleanup_orphaned_subscription_tags


logger = logging.getLogger("kisetsu.task_state")
STATE_KEY = "task_state_sync_state"
INTERVAL_SECONDS = 10

HistorySyncHook = Callable[
    [Store, dict[str, list[dict[str, Any]]], dict[str, DownloaderClient], dict[str, Exception]],
    Awaitable[dict[str, int]],
]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class TaskStateScheduler:
    def __init__(
        self,
        store_factory: Callable[[], Store],
        brush_service: BrushService,
        history_sync_hook: HistorySyncHook,
        *,
        interval_seconds: int = INTERVAL_SECONDS,
        sleep=asyncio.sleep,
        monotonic=time.monotonic,
    ):
        self.store_factory = store_factory
        self.brush_service = brush_service
        self.history_sync_hook = history_sync_hook
        self.interval_seconds = max(INTERVAL_SECONDS, int(interval_seconds))
        self._sleep = sleep
        self._monotonic = monotonic
        self._loop_task: asyncio.Task | None = None
        self._current_tick: asyncio.Task | None = None
        self._coordination_lock = asyncio.Lock()
        self._next_run_at: datetime | None = None
        self._skipped_overlap_count = 0

    async def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._loop())

    async def shutdown(self) -> None:
        loop_task = self._loop_task
        self._loop_task = None
        if loop_task is not None and not loop_task.done():
            loop_task.cancel()
            with suppress(asyncio.CancelledError):
                await loop_task
        current = self._current_tick
        if current is not None and not current.done():
            with suppress(Exception):
                await asyncio.shield(current)
        self._next_run_at = None

    async def run_now(self, *, trigger: str = "manual") -> dict[str, Any]:
        async with self._coordination_lock:
            current = self._current_tick
            if current is not None and not current.done():
                self._skipped_overlap_count += 1
                task = current
            else:
                task = asyncio.create_task(self._run_cycle(trigger=trigger))
                self._current_tick = task
        return await asyncio.shield(task)

    async def status(self) -> dict[str, Any]:
        state = self.store_factory().get_config(STATE_KEY) or {}
        return {
            "running": self._loop_task is not None and not self._loop_task.done(),
            "interval_seconds": self.interval_seconds,
            "current_run": self._current_tick is not None and not self._current_tick.done(),
            "next_run_at": self._next_run_at.isoformat() if self._next_run_at else None,
            "skipped_overlap_count": self._skipped_overlap_count,
            **state,
        }

    async def _loop(self) -> None:
        trigger = "startup"
        while True:
            started = self._monotonic()
            try:
                await self.run_now(trigger=trigger)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("task state background cycle failed")
            trigger = "schedule"
            elapsed = self._monotonic() - started
            if elapsed >= self.interval_seconds:
                self._skipped_overlap_count += 1
                delay = float(self.interval_seconds)
            else:
                delay = self.interval_seconds - elapsed
            self._next_run_at = utc_now() + timedelta(seconds=delay)
            await self._sleep(delay)

    async def _run_cycle(self, *, trigger: str) -> dict[str, Any]:
        started_at = utc_now()
        started_monotonic = self._monotonic()
        store = self.store_factory()
        previous_state = store.get_config(STATE_KEY) or {}
        state: dict[str, Any] = {
            "last_started_at": started_at.isoformat(),
            "last_trigger": trigger,
            "last_error": None,
        }
        if trigger != "startup":
            for key in (
                "orphan_tag_owned_count",
                "orphan_tag_protected_count",
                "orphan_tag_deleted_count",
                "orphan_tag_cleanup_error",
            ):
                if key in previous_state:
                    state[key] = previous_state[key]
        store.set_config(STATE_KEY, state)
        snapshots: dict[str, list[dict[str, Any]]] = {}
        clients: dict[str, DownloaderClient] = {}
        errors: dict[str, Exception] = {}
        try:
            downloader_types = self._used_downloader_types(store)
            for downloader_type in sorted(downloader_types):
                try:
                    client = downloader_client(store, downloader_type)
                    clients[downloader_type] = client
                    snapshots[downloader_type] = await client.list_torrents()
                except Exception as exc:
                    errors[downloader_type] = exc

            tag_cleanup_state: dict[str, Any] = {}
            if trigger == "startup" and downloader_configured(store, "qbittorrent"):
                try:
                    qb_client = clients.get("qbittorrent") or downloader_client(store, "qbittorrent")
                    qb_torrents = snapshots.get("qbittorrent")
                    if qb_torrents is None:
                        qb_torrents = await qb_client.list_torrents()
                    tag_cleanup_result = await cleanup_orphaned_subscription_tags(store, qb_client, qb_torrents)
                    tag_cleanup_state = {
                        "orphan_tag_owned_count": int(tag_cleanup_result.get("owned_count", 0)),
                        "orphan_tag_protected_count": int(tag_cleanup_result.get("protected_count", 0)),
                        "orphan_tag_deleted_count": int(tag_cleanup_result.get("deleted_count", 0)),
                    }
                except Exception as exc:
                    tag_cleanup_state = {"orphan_tag_cleanup_error": type(exc).__name__}

            history_result = await self.history_sync_hook(store, snapshots, clients, errors)
            brush_result = await self.brush_service.sync_tasks(
                task_snapshots=snapshots,
                clients=clients,
                snapshot_errors=errors,
            )
            brush_repository = self.brush_service.repository()
            brush_task_lookup = getattr(brush_repository, "get_task", None)
            notification_result = await flush_pending_size_notifications(
                store,
                snapshots,
                brush_task_lookup=brush_task_lookup if callable(brush_task_lookup) else None,
            )
            error_messages = [
                f"{downloader_type}: {describe_downloader_error(downloader_type, exc)}"
                for downloader_type, exc in errors.items()
            ]
            state.update(
                history_updated_count=int(history_result.get("updated_count", 0)),
                organized_count=int(history_result.get("organized_count", 0)),
                brush_updated_count=int(brush_result.get("checked_count", 0)),
                brush_cleaned_count=int(brush_result.get("deleted_count", 0)),
                size_notification_sent_count=int(notification_result.get("sent_count", 0)),
                size_notification_waiting_count=int(notification_result.get("waiting_count", 0)),
                downloader_snapshot_count=len(snapshots),
                downloader_error_count=len(errors),
                last_error="; ".join(error_messages) or None,
                **tag_cleanup_state,
            )
        except Exception as exc:
            state["last_error"] = type(exc).__name__
            logger.exception("task state sync failed trigger=%s", trigger)
        finally:
            finished_at = utc_now()
            state.update(
                last_finished_at=finished_at.isoformat(),
                duration_ms=round((self._monotonic() - started_monotonic) * 1000, 1),
                skipped_overlap_count=self._skipped_overlap_count,
            )
            store.set_config(STATE_KEY, {key: value for key, value in state.items() if value is not None})
            logger.info(
                "task state sync finished trigger=%s duration_ms=%s history=%s brush=%s organized=%s cleaned=%s errors=%s",
                trigger,
                state.get("duration_ms"),
                state.get("history_updated_count", 0),
                state.get("brush_updated_count", 0),
                state.get("organized_count", 0),
                state.get("brush_cleaned_count", 0),
                state.get("downloader_error_count", 0),
            )
        return state

    def _used_downloader_types(self, store: Store) -> set[str]:
        terminal_history_statuses = {"dry_run", "deleted", "organized_task_removed"}
        downloader_types = {
            str(row.get("downloader_type") or "qbittorrent")
            for row in store.list_history(limit=100000)
            if str(row.get("status") or "") not in terminal_history_statuses
        }
        downloader_types.update(task.downloader_type for task in self.brush_service.repository().checkable_tasks())
        pending = store.get_config("pending_download_confirmations") or {}
        if any(isinstance(value, dict) for value in pending.values()):
            downloader_types.add("qbittorrent")
        return downloader_types
