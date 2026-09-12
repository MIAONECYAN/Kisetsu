from __future__ import annotations

import asyncio
import logging
import sqlite3
import uuid
from collections.abc import Awaitable, Callable
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from typing import Any

from app.db import Store
from app.models import (
    AutomationJobRecord,
    AutomationRunNowResponse,
    AutomationSettingsRequest,
    AutomationStatus,
    QbittorrentConfig,
    SchedulerStatus,
    RefreshAllResponse,
)
from app.services.subscription_runner import refresh_all_enabled
from app.sites import describe_site_error

logger = logging.getLogger("kisetsu.automation")

CONFIG_KEY = "automation_settings"
STATE_KEY = "automation_state"
JOBS_KEY = "automation_recent_jobs"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def default_automation_settings() -> AutomationSettingsRequest:
    return AutomationSettingsRequest()


def stored_automation_settings(store: Store) -> AutomationSettingsRequest:
    return AutomationSettingsRequest(**(store.get_config(CONFIG_KEY) or {}))


def _stored_qbittorrent_config(store: Store) -> QbittorrentConfig | None:
    data = store.get_runtime_config("qbittorrent")
    return QbittorrentConfig(**data) if data else None


class AutomationService:
    def __init__(self, store_factory: Callable[[], Store]):
        self.store_factory = store_factory
        self.post_refresh_hook: Callable[[Store, RefreshAllResponse], Awaitable[dict[str, int]]] | None = None
        self._task: asyncio.Task | None = None
        self._job_lock = asyncio.Lock()
        self._next_run_at: datetime | None = None
        self._current_job: AutomationJobRecord | None = None

    async def restore_from_store(self) -> None:
        settings = stored_automation_settings(self.store_factory())
        if settings.auto_refresh_enabled:
            await self.start(settings.auto_refresh_interval_seconds, persist=False)

    async def shutdown(self) -> None:
        await self.stop(persist=False)

    async def status(self) -> AutomationStatus:
        store = self.store_factory()
        settings = stored_automation_settings(store)
        state = store.get_config(STATE_KEY) or {}
        running = self._task is not None and not self._task.done()
        message = "运行中" if running else "已停止"
        if running and self._next_run_at:
            message = f"运行中，下次刷新：{self._next_run_at.astimezone().strftime('%H:%M')}"
        if state.get("last_error_message"):
            message = f"{message}，上次错误：{state.get('last_error_message')}"
        return AutomationStatus(
            backend_running=True,
            scheduler_running=running,
            auto_refresh_enabled=settings.auto_refresh_enabled,
            auto_refresh_interval_seconds=settings.auto_refresh_interval_seconds,
            auto_download_enabled=settings.auto_download_enabled,
            auto_organize_enabled=settings.auto_organize_enabled,
            notifications_enabled=settings.notifications_enabled,
            last_run_at=state.get("last_run_at"),
            next_run_at=_iso(self._next_run_at),
            last_success_at=state.get("last_success_at"),
            last_error_at=state.get("last_error_at"),
            last_error_message=state.get("last_error_message"),
            current_job_id=self._current_job.job_id if self._current_job else None,
            current_job=self._current_job.model_dump(mode="json") if self._current_job else None,
            message=message,
        )

    async def scheduler_status(self) -> SchedulerStatus:
        status = await self.status()
        return SchedulerStatus(
            running=status.scheduler_running,
            interval_seconds=status.auto_refresh_interval_seconds,
            last_run_at=status.last_run_at,
            last_error=status.last_error_message,
            next_run_at=status.next_run_at,
            last_success_at=status.last_success_at,
            last_error_at=status.last_error_at,
            last_error_message=status.last_error_message,
            current_job_id=status.current_job_id,
        )

    async def update_settings(self, request: AutomationSettingsRequest) -> AutomationStatus:
        store = self.store_factory()
        store.set_config(CONFIG_KEY, request.model_dump(mode="json"))
        if request.auto_refresh_enabled:
            await self.start(request.auto_refresh_interval_seconds, persist=False)
        else:
            await self.stop(persist=False)
        return await self.status()

    async def update_interval(self, interval_seconds: int) -> AutomationStatus:
        self.store_factory().set_automation_interval(interval_seconds)
        # Preserve the current job/deadline. _loop reads the new interval after this cycle.
        return await self.status()

    async def start(self, interval_seconds: int, *, persist: bool = True) -> AutomationStatus:
        interval_seconds = max(1, min(86400, int(interval_seconds)))
        store = self.store_factory()
        settings = stored_automation_settings(store)
        settings.auto_refresh_enabled = True
        settings.auto_refresh_interval_seconds = interval_seconds
        if persist:
            store.set_config(CONFIG_KEY, settings.model_dump(mode="json"))
        self._next_run_at = _now() + timedelta(seconds=interval_seconds)
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._loop())
        logger.info("automation scheduler started interval_seconds=%s next_run_at=%s", interval_seconds, _iso(self._next_run_at))
        return await self.status()

    async def stop(self, *, persist: bool = True) -> AutomationStatus:
        if persist:
            store = self.store_factory()
            settings = stored_automation_settings(store)
            settings.auto_refresh_enabled = False
            store.set_config(CONFIG_KEY, settings.model_dump(mode="json"))
        if self._task is not None and not self._task.done():
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
        self._task = None
        self._next_run_at = None
        logger.info("automation scheduler stopped")
        return await self.status()

    async def run_now(self) -> AutomationRunNowResponse:
        if self._job_lock.locked():
            logger.info("skip auto refresh because previous job still running")
            status = await self.status()
            return AutomationRunNowResponse(ok=False, message="已有自动刷新任务正在运行，已跳过。", status=status)
        job = await self._run_job(trigger="manual")
        return AutomationRunNowResponse(ok=job.status == "success", message="自动刷新已完成" if job.status == "success" else "自动刷新失败", status=await self.status(), job=job)

    async def recent_jobs(self, limit: int = 20) -> list[AutomationJobRecord]:
        rows = self.store_factory().get_config(JOBS_KEY) or {"items": []}
        return [AutomationJobRecord(**item) for item in rows.get("items", [])[:limit]]

    async def _loop(self) -> None:
        while True:
            settings = stored_automation_settings(self.store_factory())
            interval = max(1, settings.auto_refresh_interval_seconds)
            if self._next_run_at is None:
                self._next_run_at = _now() + timedelta(seconds=interval)
            delay = max(0.0, (self._next_run_at - _now()).total_seconds())
            await asyncio.sleep(delay)
            if self._job_lock.locked():
                logger.info("skip auto refresh because previous job still running")
                self._record_job(AutomationJobRecord(job_id=str(uuid.uuid4()), started_at=_iso(_now()) or "", finished_at=_iso(_now()), status="skipped", error_message="上一轮仍在运行"))
            else:
                await self._run_job(trigger="schedule")
            settings = stored_automation_settings(self.store_factory())
            self._next_run_at = _now() + timedelta(seconds=max(1, settings.auto_refresh_interval_seconds))

    async def _run_job(self, *, trigger: str) -> AutomationJobRecord:
        async with self._job_lock:
            job = AutomationJobRecord(job_id=str(uuid.uuid4()), started_at=_iso(_now()) or "")
            self._current_job = job
            store = self.store_factory()
            state: dict[str, Any] = {}
            try:
                settings = stored_automation_settings(store)
                logger.info(
                    "auto refresh tick started job_id=%s trigger=%s interval_seconds=%s",
                    job.job_id,
                    trigger,
                    settings.auto_refresh_interval_seconds,
                )
                state = store.get_config(STATE_KEY) or {}
                state.update(last_run_at=job.started_at, current_job_id=job.job_id)
                store.set_config(STATE_KEY, state)
                response = await refresh_all_enabled(
                    store,
                    qbittorrent_config=_stored_qbittorrent_config(store),
                    auto_download_enabled=settings.auto_download_enabled,
                )
                job.refreshed_count = response.refreshed
                job.matched_count = sum(len(item.matched) for item in response.responses)
                job.downloaded_count = sum(len(item.added) for item in response.responses)
                job.error_count = sum(1 for item in response.responses for record in item.match_records if record.status == "error") + len(response.warnings)
                if settings.auto_organize_enabled and self.post_refresh_hook is not None:
                    hook_result = await self.post_refresh_hook(store, response)
                    job.organized_count = int(hook_result.get("organized_count", 0))
                    job.error_count += int(hook_result.get("error_count", 0))
                job.status = "success" if job.error_count == 0 else "error"
                job.error_message = "; ".join(response.warnings) if response.warnings else None
                state.update(
                    last_success_at=_iso(_now()) if job.status == "success" else state.get("last_success_at"),
                    last_error_at=_iso(_now()) if job.status == "error" else None,
                    last_error_message=job.error_message,
                )
            except Exception as exc:
                job.status = "error"
                job.error_count = 1
                if isinstance(exc, sqlite3.Error):
                    job.error_message = "定时刷新失败：数据库暂时不可用。"
                else:
                    job.error_message = f"定时刷新失败：{describe_site_error(exc)}"
                state.update(last_error_at=_iso(_now()), last_error_message=job.error_message)
                logger.exception("auto refresh job failed job_id=%s: %s", job.job_id, job.error_message)
            finally:
                job.finished_at = _iso(_now())
                try:
                    store.set_config(STATE_KEY, {k: v for k, v in state.items() if v is not None})
                    self._record_job(job)
                except sqlite3.Error as exc:
                    logger.error(
                        "auto refresh state persistence skipped job_id=%s database_error=%s",
                        job.job_id,
                        type(exc).__name__,
                    )
                self._current_job = None
                logger.info(
                    "auto refresh job finished job_id=%s status=%s refreshed_count=%s matched_count=%s downloaded_count=%s organized_count=%s notified_count=%s error_count=%s",
                    job.job_id,
                    job.status,
                    job.refreshed_count,
                    job.matched_count,
                    job.downloaded_count,
                    job.organized_count,
                    job.notified_count,
                    job.error_count,
                )
            return job

    def _record_job(self, job: AutomationJobRecord) -> None:
        store = self.store_factory()
        rows = store.get_config(JOBS_KEY) or {"items": []}
        items = [job.model_dump(mode="json"), *rows.get("items", [])]
        store.set_config(JOBS_KEY, {"items": items[:50]})
