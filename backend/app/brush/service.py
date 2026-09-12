from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import random
import re
import uuid
from collections import Counter
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path, PurePosixPath
from typing import Any, Callable

from app.brush.models import (
    BrushActionResponse,
    BrushCandidate,
    BrushCandidatePage,
    BrushDeleteCapability,
    BrushDownloaderTransfer,
    BrushGroup,
    BrushRule,
    BrushRun,
    BrushSettings,
    BrushSiteAccount,
    BrushStats,
    BrushStatus,
    BrushTask,
)
from app.brush.repository import BrushRepository, now_iso
from app.brush.sites import brush_site_capabilities, get_brush_site_adapter
from app.brush.transmission_delete import (
    BACKEND_LOCAL_MACOS,
    RPC_NATIVE,
    DeletePlanStore,
    TransmissionDeleteError,
    build_macos_delete_plan,
    delete_macos_plan_files,
    ensure_plan_paths_unshared,
    transmission_delete_mode,
)
from app.core.downloader import DownloaderClient, DownloaderError
from app.core.downloaders import (
    describe_downloader_error,
    downloader_client,
    downloader_configured,
    downloader_display_name,
    stored_downloader_routing,
    stored_transmission_config,
)
from app.db import Store
from app.notifications import NotificationEvent, NotificationService
from app.notifications.pending import brush_size_target, send_or_defer_size_notification
from app.notifications.templates import brush_task_added_event
from app.services.downloads import normalize_add_result, task_total_size_bytes, torrent_content_size_bytes
from app.services.managed_directories import (
    ManagedDirectoryTarget,
    brush_task_directory,
    paths_overlap,
    prune_empty_managed_directory,
)
from app.sites import describe_site_error


logger = logging.getLogger("kisetsu.brush")
SETTINGS_KEY = "brush_settings"
STATE_KEY = "brush_state"
BASE_TAG = "Kisetsu刷流"
LEGACY_BASE_TAGS = frozenset({"AnimePilot刷流"})
GROUP_TAG_PREFIX = "AP分组-"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = parsedate_to_datetime(value)
        return parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.astimezone().astimezone(timezone.utc)
    except (TypeError, ValueError, OverflowError):
        pass
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.astimezone().astimezone(timezone.utc)
    except ValueError:
        return None


def task_key(site_id: str, resource_id: str) -> str:
    return hashlib.sha256(f"{site_id}|{resource_id}".encode("utf-8")).hexdigest()


def split_tags(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return [item.strip() for item in str(value or "").split(",") if item.strip()]


def migrate_legacy_empty_include_patterns(payload: dict[str, Any]) -> dict[str, Any]:
    migrated = dict(payload)
    global_rule = migrated.get("global_rule")
    if isinstance(global_rule, dict) and global_rule.get("include_pattern") == "(?!)":
        migrated["global_rule"] = {**global_rule, "include_pattern": None}

    site_overrides = migrated.get("site_overrides")
    if isinstance(site_overrides, dict):
        updated_overrides = dict(site_overrides)
        changed = False
        for site_id, override in site_overrides.items():
            if not isinstance(override, dict):
                continue
            rule = override.get("rule")
            if not isinstance(rule, dict) or rule.get("include_pattern") != "(?!)":
                continue
            updated_overrides[site_id] = {
                **override,
                "rule": {**rule, "include_pattern": None},
            }
            changed = True
        if changed:
            migrated["site_overrides"] = updated_overrides
    groups = migrated.get("groups")
    if isinstance(groups, list):
        updated_groups: list[object] = []
        changed = False
        for group in groups:
            if not isinstance(group, dict):
                updated_groups.append(group)
                continue
            rule = group.get("rule")
            if not isinstance(rule, dict) or rule.get("include_pattern") != "(?!)":
                updated_groups.append(group)
                continue
            updated_groups.append({**group, "rule": {**rule, "include_pattern": None}})
            changed = True
        if changed:
            migrated["groups"] = updated_groups
    return migrated


class BrushService:
    def __init__(self, store_factory: Callable[[], Store]):
        self.store_factory = store_factory
        self._task: asyncio.Task | None = None
        self._lock = asyncio.Lock()
        self._next_brush_at: datetime | None = None
        self._next_check_at: datetime | None = None
        self._current_operation: str | None = None
        self._site_account_cache: dict[str, tuple[datetime, BrushSiteAccount]] = {}
        self._site_account_lock = asyncio.Lock()
        self._delete_lock = asyncio.Lock()

    def repository(self) -> BrushRepository:
        repository = BrushRepository(self.store_factory())
        repository.init()
        return repository

    def settings(self) -> BrushSettings:
        store = self.store_factory()
        raw = store.get_config(SETTINGS_KEY) or {}
        migrated = migrate_legacy_empty_include_patterns(raw)
        legacy = any(key in raw for key in (
            "risk_confirmed",
            "max_policy_probes_per_run",
            "max_global_upload_kib",
            "max_global_download_kib",
            "task_upload_limit_kib",
            "task_download_limit_kib",
        ))
        if legacy:
            global_rule = dict(migrated.get("global_rule") or {})
            if global_rule.get("seed_time_hours") in (None, 96, 96.0):
                global_rule["seed_time_hours"] = 72
            if global_rule.get("seed_ratio") is None:
                global_rule["seed_ratio"] = 2
            migrated["global_rule"] = global_rule
        settings = BrushSettings(**migrated)
        normalized = settings.model_dump(mode="json")
        if normalized != raw:
            store.set_config(SETTINGS_KEY, normalized)
        return settings

    def _downloader(self, downloader_type: str | None = None) -> DownloaderClient:
        store = self.store_factory()
        selected = downloader_type or stored_downloader_routing(store).brush_downloader
        return downloader_client(store, selected)

    def _qbittorrent(self) -> DownloaderClient:
        return self._downloader("qbittorrent")

    def _client_for_type(self, downloader_type: str) -> DownloaderClient:
        return self._qbittorrent() if downloader_type == "qbittorrent" else self._downloader(downloader_type)

    def _capacity_downloader_types(self, repository: BrushRepository, selected: str) -> list[str]:
        store = self.store_factory()
        downloader_types = {selected}
        downloader_types.update(task.downloader_type for task in repository.checkable_tasks())
        downloader_types.update(
            downloader_type
            for downloader_type in ("qbittorrent", "transmission")
            if downloader_configured(store, downloader_type)
        )
        return sorted(downloader_types)

    async def _brush_task_snapshots(
        self,
        repository: BrushRepository,
        selected: str,
    ) -> tuple[dict[str, DownloaderClient], dict[str, list[dict[str, Any]]]]:
        clients: dict[str, DownloaderClient] = {}
        snapshots: dict[str, list[dict[str, Any]]] = {}
        for downloader_type in self._capacity_downloader_types(repository, selected):
            try:
                client = self._client_for_type(downloader_type)
                snapshots[downloader_type] = await client.list_torrents()
                clients[downloader_type] = client
            except Exception as exc:
                name = downloader_display_name(downloader_type)
                reason = describe_downloader_error(downloader_type, exc)
                raise DownloaderError(f"无法确认 {name} 中的刷流任务数量：{reason}") from exc
        return clients, snapshots

    @staticmethod
    def _snapshot_item_key(downloader_type: str, item: dict[str, Any], index: int) -> tuple[str, str]:
        identity = str(item.get("remote_id") or item.get("hash") or "").strip().casefold()
        if not identity:
            unique_tags = sorted(tag for tag in split_tags(item.get("tags")) if tag.startswith("AP刷流-"))
            identity = unique_tags[0] if unique_tags else f"snapshot:{index}"
        return downloader_type, identity

    def _count_existing_brush_tasks(
        self,
        repository: BrushRepository,
        snapshots: dict[str, list[dict[str, Any]]],
    ) -> int:
        counted: set[tuple[str, str]] = set()
        known_items: set[tuple[str, int]] = set()
        for task in repository.tracked_tasks():
            items = snapshots.get(task.downloader_type, [])
            item = self._find_task_item(task, items)
            if item is None:
                continue
            index = next(index for index, candidate in enumerate(items) if candidate is item)
            known_items.add((task.downloader_type, index))
            if task.status not in {"deleted", "archived"}:
                counted.add(self._snapshot_item_key(task.downloader_type, item, index))
        for downloader_type, items in snapshots.items():
            for index, item in enumerate(items):
                if (downloader_type, index) in known_items:
                    continue
                tags = split_tags(item.get("tags"))
                if BASE_TAG in tags and any(tag.startswith("AP刷流-") for tag in tags):
                    counted.add(self._snapshot_item_key(downloader_type, item, index))
        return len(counted)

    def _task_group_id(self, settings: BrushSettings, task: BrushTask) -> str | None:
        configured_ids = {group.id for group in settings.groups}
        if task.group_id in configured_ids:
            return task.group_id
        group = self._group_for_site(settings, task.site_id)
        return group.id if group else None

    def _snapshot_group_id(self, settings: BrushSettings, item: dict[str, Any]) -> str | None:
        configured_ids = {group.id for group in settings.groups}
        tags = split_tags(item.get("tags"))
        for tag in tags:
            if tag.startswith(GROUP_TAG_PREFIX):
                group_id = tag.removeprefix(GROUP_TAG_PREFIX)
                if group_id in configured_ids:
                    return group_id
        for tag in tags:
            if tag.startswith("站点-"):
                group = self._group_for_site(settings, tag.removeprefix("站点-"))
                if group:
                    return group.id
        enabled_groups = self._enabled_groups(settings)
        if len(enabled_groups) == 1:
            return enabled_groups[0].id
        return None

    def _group_task_counts(
        self,
        repository: BrushRepository,
        snapshots: dict[str, list[dict[str, Any]]],
        settings: BrushSettings,
    ) -> dict[str, dict[str, int]]:
        counts = {group.id: {"tasks": 0, "downloading": 0} for group in settings.groups}
        counted: set[tuple[str, str]] = set()
        known_items: set[tuple[str, int]] = set()
        for task in repository.tracked_tasks():
            items = snapshots.get(task.downloader_type, [])
            item = self._find_task_item(task, items)
            if item is None or task.status in {"deleted", "archived"}:
                continue
            index = next(index for index, candidate in enumerate(items) if candidate is item)
            known_items.add((task.downloader_type, index))
            identity = self._snapshot_item_key(task.downloader_type, item, index)
            if identity in counted:
                continue
            group_id = self._task_group_id(settings, task)
            if group_id not in counts:
                continue
            counted.add(identity)
            counts[group_id]["tasks"] += 1
            if float(item.get("progress") or 0) < 1:
                counts[group_id]["downloading"] += 1
        for downloader_type, items in snapshots.items():
            for index, item in enumerate(items):
                if (downloader_type, index) in known_items:
                    continue
                tags = split_tags(item.get("tags"))
                if BASE_TAG not in tags or not any(tag.startswith("AP刷流-") for tag in tags):
                    continue
                identity = self._snapshot_item_key(downloader_type, item, index)
                if identity in counted:
                    continue
                group_id = self._snapshot_group_id(settings, item)
                if group_id not in counts:
                    continue
                counted.add(identity)
                counts[group_id]["tasks"] += 1
                if float(item.get("progress") or 0) < 1:
                    counts[group_id]["downloading"] += 1
        return counts

    async def restore_from_store(self) -> None:
        self.repository()
        try:
            await self._recover_pending_transmission_deletes()
        except Exception as exc:
            message = str(exc) or "Transmission 删除计划恢复失败"
            self._update_state(last_error=message)
            logger.warning("brush transmission delete recovery failed: %s", message)
        settings = self.settings()
        if settings.enabled:
            try:
                await self.start(persist=False)
            except Exception as exc:
                message = str(exc) or "刷流后台恢复失败"
                self._update_state(last_error=message)
                logger.warning("brush scheduler restore failed: %s", message)

    async def shutdown(self) -> None:
        await self.stop(persist=False)

    async def update_settings(self, settings: BrushSettings) -> BrushStatus:
        self._validate_save_paths(settings)
        store = self.store_factory()
        store.set_config(SETTINGS_KEY, settings.model_dump(mode="json"))
        if settings.enabled:
            await self.start(persist=False)
        else:
            await self.stop(persist=False)
        return await self.status()

    def _validate_save_paths(self, settings: BrushSettings) -> None:
        if not settings.save_path.strip():
            if settings.enabled:
                raise ValueError("请设置刷流专用保存目录。")
            return
        configured_paths = [settings.save_path]
        store = self.store_factory()
        qb_payload = store.get_runtime_config("qbittorrent") or {}
        transmission_payload = store.get_runtime_config("transmission") or {}
        ordinary_paths = {
            str(qb_payload.get("default_save_path") or "").strip(),
            str(transmission_payload.get("default_save_path") or "").strip(),
        }
        ordinary_paths.update(str(item.get("save_path") or "").strip() for item in store.list_subscriptions())
        ordinary_paths.update(str(item.get("path") or "").strip() for item in store.list_organize_targets())
        ordinary_paths.discard("")
        for raw_path in configured_paths:
            path = Path(raw_path).expanduser()
            if not path.is_absolute():
                raise ValueError("刷流保存目录必须是绝对路径。")
            resolved = path.resolve(strict=False)
            if any(resolved == Path(item).expanduser().resolve(strict=False) for item in ordinary_paths):
                raise ValueError("刷流保存目录不能与普通下载或订阅目录相同。")
            resolved.mkdir(parents=True, exist_ok=True)
            if not resolved.is_dir():
                raise ValueError(f"刷流保存目录不可用：{resolved}")

    async def start(self, *, persist: bool = True) -> BrushStatus:
        settings = self.settings()
        if not settings.save_path.strip():
            raise ValueError("请先设置刷流专用保存目录。")
        self._validate_save_paths(settings)
        if persist and not settings.enabled:
            settings.enabled = True
            self.store_factory().set_config(SETTINGS_KEY, settings.model_dump(mode="json"))
        now = utc_now()
        self._next_brush_at = now + timedelta(minutes=settings.brush_interval_minutes)
        self._next_check_at = now + timedelta(seconds=10)
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._loop())
        return await self.status()

    async def stop(self, *, persist: bool = True) -> BrushStatus:
        if persist:
            settings = self.settings()
            settings.enabled = False
            self.store_factory().set_config(SETTINGS_KEY, settings.model_dump(mode="json"))
        task = self._task
        self._task = None
        if task and task is not asyncio.current_task():
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        self._next_brush_at = None
        self._next_check_at = None
        return await self.status()

    async def _loop(self) -> None:
        while True:
            settings = self.settings()
            if not settings.enabled:
                return
            now = utc_now()
            if self._next_brush_at is None or now >= self._next_brush_at:
                await self.run_brush(trigger="scheduler")
                self._next_brush_at = utc_now() + timedelta(minutes=settings.brush_interval_minutes)
            await asyncio.sleep(1)

    def _state(self) -> dict[str, Any]:
        return self.store_factory().get_config(STATE_KEY) or {}

    def _update_state(self, **changes: Any) -> None:
        state = self._state()
        state.update(changes)
        self.store_factory().set_config(STATE_KEY, state)

    async def status(self) -> BrushStatus:
        settings = self.settings()
        state = self._state()
        stats = self._stats(self.repository().list_tasks(include_archived=True))
        downloader_transfer = await self._downloader_transfer()
        running = self._task is not None and not self._task.done()
        return BrushStatus(
            enabled=settings.enabled,
            scheduler_running=running,
            current_operation=self._current_operation,
            next_brush_at=self._next_brush_at.isoformat() if self._next_brush_at else None,
            next_check_at=self._next_check_at.isoformat() if self._next_check_at else None,
            last_brush_at=state.get("last_brush_at"),
            last_check_at=state.get("last_check_at"),
            last_error=state.get("last_error"),
            message=(f"正在{self._current_operation}" if self._current_operation else ("运行中" if running else "站点刷流未启用")),
            stats=stats,
            downloader_transfer=downloader_transfer,
            transmission_delete_capability=self._transmission_delete_capability(settings),
        )

    async def _downloader_transfer(self) -> BrushDownloaderTransfer:
        downloader_type = stored_downloader_routing(self.store_factory()).brush_downloader
        downloader_name = downloader_display_name(downloader_type)
        fetched_at = now_iso()
        try:
            payload = await self._client_for_type(downloader_type).transfer_info()
            downloaded = payload.get("downloaded_bytes")
            uploaded = payload.get("uploaded_bytes")
            if not isinstance(downloaded, int) or isinstance(downloaded, bool) or downloaded < 0:
                raise DownloaderError(f"{downloader_name} 未返回有效的累计下载量。")
            if not isinstance(uploaded, int) or isinstance(uploaded, bool) or uploaded < 0:
                raise DownloaderError(f"{downloader_name} 未返回有效的累计上传量。")
            ratio = uploaded / downloaded if downloaded > 0 else (0.0 if uploaded == 0 else None)
            return BrushDownloaderTransfer(
                downloader_type=downloader_type,
                downloader_name=downloader_name,
                downloaded_bytes=downloaded,
                uploaded_bytes=uploaded,
                overall_ratio=ratio,
                fetched_at=fetched_at,
                available=True,
            )
        except Exception as exc:
            return BrushDownloaderTransfer(
                downloader_type=downloader_type,
                downloader_name=downloader_name,
                fetched_at=fetched_at,
                available=False,
                error=describe_downloader_error(downloader_type, exc),
            )

    def _transmission_delete_capability(self, settings: BrushSettings) -> BrushDeleteCapability:
        config = stored_transmission_config(self.store_factory())
        if config is None or not config.base_url:
            return BrushDeleteCapability(reason="Transmission 尚未配置。")
        try:
            mode = transmission_delete_mode(config.base_url)
        except TransmissionDeleteError as exc:
            return BrushDeleteCapability(reason=str(exc))
        if mode == BACKEND_LOCAL_MACOS:
            root = Path(settings.save_path).expanduser()
            if not settings.save_path.strip() or not root.is_dir():
                return BrushDeleteCapability(reason="刷流专用目录当前不可访问。")
            if root.is_symlink() or not os.access(root, os.R_OK | os.W_OK | os.X_OK):
                return BrushDeleteCapability(reason="Kisetsu 后端没有刷流目录的安全删除权限。")
        return BrushDeleteCapability(available=True, platform_mode=mode)

    @staticmethod
    def _stats(tasks: list[BrushTask]) -> BrushStats:
        active = [task for task in tasks if task.status not in {"deleted", "archived", "error"}]
        uploaded = sum(task.uploaded for task in tasks)
        downloaded = sum(task.downloaded for task in tasks)
        return BrushStats(
            total_tasks=len(tasks),
            active_tasks=len(active),
            downloading_tasks=sum(task.status == "downloading" for task in active),
            seeding_tasks=sum(task.status == "seeding" for task in active),
            deleted_tasks=sum(task.status == "deleted" for task in tasks),
            occupied_bytes=sum(task.size_bytes or 0 for task in active),
            uploaded_bytes=uploaded,
            downloaded_bytes=downloaded,
            overall_ratio=(uploaded / downloaded) if downloaded else 0,
        )

    def capabilities(self):
        return brush_site_capabilities(self.store_factory().get_runtime_config("site_settings") or {})

    def _enabled_site_ids(self, settings: BrushSettings) -> list[str]:
        return [site_id for group in self._enabled_groups(settings) for site_id in group.site_ids]

    @staticmethod
    def _enabled_groups(settings: BrushSettings) -> list[BrushGroup]:
        return [group for group in settings.groups if group.enabled and group.site_ids]

    @staticmethod
    def _group_for_site(settings: BrushSettings, site_id: str) -> BrushGroup | None:
        return next((group for group in settings.groups if site_id in group.site_ids), None)

    async def site_accounts(self, *, refresh: bool = False) -> list[BrushSiteAccount]:
        async with self._site_account_lock:
            settings = self.settings()
            site_settings = self.store_factory().get_runtime_config("site_settings") or {}
            now = utc_now()
            accounts: list[BrushSiteAccount] = []
            for site_id in self._enabled_site_ids(settings):
                cached = self._site_account_cache.get(site_id)
                if not refresh and cached and now - cached[0] < timedelta(minutes=10):
                    accounts.append(cached[1])
                    continue
                try:
                    adapter = get_brush_site_adapter(site_id, site_settings)
                    uploaded, downloaded, ratio = await adapter.account_stats()
                    account = BrushSiteAccount(
                        site_id=site_id,
                        site_name=adapter.adapter.info().display_name or adapter.adapter.name,
                        uploaded_bytes=uploaded,
                        downloaded_bytes=downloaded,
                        ratio=ratio,
                        fetched_at=now_iso(),
                    )
                except Exception as exc:
                    adapter_name = site_id
                    with suppress(Exception):
                        adapter_name = get_brush_site_adapter(site_id, site_settings).adapter.info().display_name
                    account = BrushSiteAccount(
                        site_id=site_id,
                        site_name=adapter_name or site_id,
                        fetched_at=now_iso(),
                        status="error",
                        error=describe_site_error(exc),
                    )
                self._site_account_cache[site_id] = (now, account)
                accounts.append(account)
            return accounts

    async def candidates(self, site_id: str, *, page: int = 1, page_size: int = 50) -> BrushCandidatePage:
        adapter = get_brush_site_adapter(site_id, self.store_factory().get_runtime_config("site_settings") or {})
        return await adapter.list_candidates(page=page, page_size=page_size)

    def _in_active_time(self, settings: BrushSettings) -> bool:
        if not settings.active_time_start or not settings.active_time_end:
            return True
        now_value = datetime.now().strftime("%H:%M")
        start, end = settings.active_time_start, settings.active_time_end
        return start <= now_value <= end if start <= end else now_value >= start or now_value <= end

    def _effective(self, settings: BrushSettings, site_id: str) -> tuple[BrushRule, str, str]:
        group = self._group_for_site(settings, site_id)
        if group is None:
            raise ValueError(f"站点 {site_id} 尚未分配刷流分组。")
        return group.rule, settings.save_path, settings.category

    def _candidate_allowed(
        self,
        candidate: BrushCandidate,
        rule: BrushRule,
    ) -> tuple[bool, str]:
        if not candidate.downloadable:
            return False, candidate.unavailable_reason or "资源缺少刷流必需字段"
        label = (candidate.promotion_label or "").upper()
        is_free = candidate.download_factor == 0 or label == "FREE" or "FREE" in label
        is_double_free = is_free and ((candidate.upload_factor or 0) >= 2 or "2X FREE" in label)
        candidate_promotion = "2xfree" if is_double_free else ("free" if is_free else None)
        selected_promotions = set(rule.promotion_modes)
        if selected_promotions and candidate_promotion not in selected_promotions:
            if selected_promotions == {"free"}:
                return False, "不是普通 FREE 资源"
            if selected_promotions == {"2xfree"}:
                return False, "不是双倍上传 FREE 资源"
            return False, "不是 FREE 资源"
        text = f"{candidate.title} {candidate.subtitle or ''}"
        try:
            if rule.include_pattern and not re.search(rule.include_pattern, text, flags=re.I):
                return False, "未命中包含规则"
            if rule.exclude_pattern and re.search(rule.exclude_pattern, text, flags=re.I):
                return False, "命中排除规则"
        except re.error as exc:
            return False, f"正则表达式无效：{exc}"
        size_gb = (candidate.size_bytes or 0) / 1024 ** 3
        if rule.size_min_gb is not None and size_gb < rule.size_min_gb:
            return False, "资源体积小于规则下限"
        if rule.size_max_gb is not None and size_gb > rule.size_max_gb:
            return False, "资源体积超过规则上限"
        if rule.seeders_min is not None and (candidate.seeders is None or candidate.seeders < rule.seeders_min):
            return False, "做种数低于规则下限"
        if rule.seeders_max is not None and (candidate.seeders is None or candidate.seeders > rule.seeders_max):
            return False, "做种数超过规则上限"
        published = parse_datetime(candidate.published_at)
        if rule.publish_age_min_minutes is not None or rule.publish_age_max_minutes is not None:
            if published is None:
                return False, "发布时间无法确认"
            age_minutes = max(0, (utc_now() - published).total_seconds() / 60)
            if rule.publish_age_min_minutes is not None and age_minutes < rule.publish_age_min_minutes:
                return False, "资源发布时间过新"
            if rule.publish_age_max_minutes is not None and age_minutes > rule.publish_age_max_minutes:
                return False, "资源发布时间超过规则上限"
        return True, "符合刷流规则"

    def _subscription_titles(self) -> list[str]:
        return [str(item.get("name") or "").strip().casefold() for item in self.store_factory().list_subscriptions() if item.get("name")]

    async def run_brush(self, *, trigger: str = "manual") -> BrushRun:
        async with self._lock:
            repository = self.repository()
            run = repository.create_run("brush", trigger=trigger)
            settings = self.settings()
            details: list[str] = []
            skip_reasons: Counter[str] = Counter()
            counters = {
                "candidates_count": 0,
                "added_count": 0,
                "skipped_count": 0,
                "error_count": 0,
                "matched_count": 0,
                "attempted_count": 0,
                "duplicate_count": 0,
                "submission_failed_count": 0,
            }
            site_diagnostics: list[dict[str, Any]] = []
            added_task_snapshots: list[dict[str, Any]] = []
            self._current_operation = "获取并筛选刷流资源"
            try:
                if not settings.enabled and trigger != "manual":
                    return repository.finish_run(run.id, status="skipped", summary="刷流未启用")
                if not self._in_active_time(settings):
                    return repository.finish_run(run.id, status="skipped", summary="当前不在刷流运行时段")
                self._validate_save_paths(settings)
                downloader_type = stored_downloader_routing(self.store_factory()).brush_downloader
                groups = self._enabled_groups(settings)
                if not groups:
                    return repository.finish_run(run.id, status="skipped", summary="没有已启用且包含站点的刷流分组")
                try:
                    clients, task_snapshots = await self._brush_task_snapshots(repository, downloader_type)
                    sync_result = await self._sync_tasks_locked(task_snapshots=task_snapshots, clients=clients)
                    if sync_result["deleted_count"]:
                        clients, task_snapshots = await self._brush_task_snapshots(repository, downloader_type)
                except Exception as exc:
                    summary = f"{str(exc) or '无法确认刷流任务数量'}，已跳过本轮"
                    return repository.finish_run(run.id, status="skipped", summary=summary, details=[summary])
                client = clients[downloader_type]
                group_counts = self._group_task_counts(repository, task_snapshots, settings)
                subscription_titles = self._subscription_titles() if any(group.exclude_subscriptions for group in groups) else []
                active_size = sum(task.size_bytes or 0 for task in repository.active_tasks())
                capacity_limit = int(settings.max_storage_gb * 1024 ** 3) if settings.max_storage_gb else None
                capacity_lock = asyncio.Lock()
                site_settings = self.store_factory().get_runtime_config("site_settings") or {}

                if len(groups) == 1:
                    group = groups[0]
                    group_count = group_counts.setdefault(group.id, {"tasks": 0, "downloading": 0})
                    if group.max_tasks is not None and group_count["tasks"] >= group.max_tasks:
                        summary = f"当前刷流任务 {group_count['tasks']} 条，最大 {group.max_tasks} 条，已跳过本轮"
                        return repository.finish_run(run.id, status="skipped", summary=summary, details=[summary])
                    if group.max_downloading is not None and group_count["downloading"] >= group.max_downloading:
                        return repository.finish_run(run.id, status="skipped", summary="当前下载任务数已达到刷流上限")

                async def reserve_capacity(size_bytes: int | None) -> bool:
                    nonlocal active_size
                    if capacity_limit is None:
                        return True
                    if not size_bytes:
                        return False
                    async with capacity_lock:
                        if active_size + size_bytes > capacity_limit:
                            return False
                        active_size += size_bytes
                        return True

                async def release_capacity(size_bytes: int | None) -> None:
                    nonlocal active_size
                    if capacity_limit is None or not size_bytes:
                        return
                    async with capacity_lock:
                        active_size = max(0, active_size - size_bytes)

                async def reconcile_capacity(reserved_bytes: int | None, actual_bytes: int | None) -> bool:
                    nonlocal active_size
                    if capacity_limit is None or not actual_bytes:
                        return True
                    async with capacity_lock:
                        active_size = max(0, active_size + actual_bytes - (reserved_bytes or 0))
                        return active_size <= capacity_limit

                async def process_group(group: BrushGroup) -> None:
                    group_count = group_counts.setdefault(group.id, {"tasks": 0, "downloading": 0})
                    if group.max_tasks is not None and group_count["tasks"] >= group.max_tasks:
                        details.append(f"{group.name}：当前任务 {group_count['tasks']} 条，已达到上限 {group.max_tasks} 条")
                        return
                    if group.max_tasks is not None:
                        remaining = group.max_tasks - group_count["tasks"]
                        prefix = "" if len(groups) == 1 else f"{group.name}："
                        details.append(
                            f"{prefix}当前刷流任务 {group_count['tasks']} 条，最大 {group.max_tasks} 条，"
                            f"剩余可新增 {remaining} 条"
                        )
                    if group.max_downloading is not None and group_count["downloading"] >= group.max_downloading:
                        details.append(f"{group.name}：当前下载任务已达到上限 {group.max_downloading} 条")
                        return
                    group_added = 0
                    site_ids = list(group.site_ids)
                    if not group.sequential_sites:
                        random.shuffle(site_ids)
                    for site_id in site_ids:
                        if group_added >= group.max_additions_per_run:
                            break
                        if group.max_tasks is not None and group_count["tasks"] >= group.max_tasks:
                            break
                        if group.max_downloading is not None and group_count["downloading"] >= group.max_downloading:
                            break
                        site_diagnostic: dict[str, Any] = {
                            "group_id": group.id,
                            "group_name": group.name,
                            "site_id": site_id,
                            "site_name": site_id,
                            "read_count": 0,
                            "matched_count": 0,
                            "attempted_count": 0,
                            "added_count": 0,
                            "duplicate_count": 0,
                            "submission_failed_count": 0,
                            "rejection_reasons": Counter(),
                            "error": None,
                        }
                        site_diagnostics.append(site_diagnostic)
                        try:
                            adapter = get_brush_site_adapter(site_id, site_settings)
                            page = await adapter.list_candidates(page=1, page_size=group.candidates_per_site)
                        except Exception as exc:
                            counters["error_count"] += 1
                            site_diagnostic["error"] = describe_site_error(exc)
                            details.append(f"{group.name} · {site_id}：{site_diagnostic['error']}")
                            await self._notify("error", site_id, describe_site_error(exc), run.id)
                            continue
                        site_diagnostic["site_name"] = page.site_name
                        site_diagnostic["read_count"] = len(page.candidates)
                        counters["candidates_count"] += len(page.candidates)
                        effective_group = group
                        rule, save_path, category = self._effective(settings, site_id)
                        for candidate in page.candidates:
                            if group_added >= group.max_additions_per_run:
                                prefix = "" if len(groups) == 1 else f"{group.name}："
                                details.append(f"{prefix}已达到单轮新增上限 {group.max_additions_per_run} 条")
                                break
                            if group.max_tasks is not None and group_count["tasks"] >= group.max_tasks:
                                if len(groups) == 1:
                                    details.append("已达到最大任务数，停止新增任务")
                                else:
                                    details.append(f"{group.name}：已达到最大任务数，停止本组新增")
                                break
                            if group.max_downloading is not None and group_count["downloading"] >= group.max_downloading:
                                details.append(f"{group.name}：已达到最大同时下载数，停止本组新增")
                                break
                            if repository.task_exists(candidate.site_id, candidate.resource_id):
                                counters["skipped_count"] += 1
                                counters["duplicate_count"] += 1
                                site_diagnostic["duplicate_count"] += 1
                                skip_reasons["资源已存在于刷流记录"] += 1
                                site_diagnostic["rejection_reasons"]["资源已存在于刷流记录"] += 1
                                continue
                            if group.exclude_subscriptions and subscription_titles and any(
                                title and title in candidate.title.casefold() for title in subscription_titles
                            ):
                                counters["skipped_count"] += 1
                                skip_reasons["命中现有订阅"] += 1
                                site_diagnostic["rejection_reasons"]["命中现有订阅"] += 1
                                continue
                            allowed, reason = self._candidate_allowed(candidate, rule)
                            if not allowed:
                                counters["skipped_count"] += 1
                                skip_reasons[reason] += 1
                                site_diagnostic["rejection_reasons"][reason] += 1
                                continue
                            counters["matched_count"] += 1
                            site_diagnostic["matched_count"] += 1
                            key = task_key(candidate.site_id, candidate.resource_id)
                            unique_tag = f"AP刷流-{key[:16]}"
                            tags = list(dict.fromkeys([
                                BASE_TAG,
                                *settings.tags,
                                unique_tag,
                                f"站点-{candidate.site_id}",
                                f"{GROUP_TAG_PREFIX}{effective_group.id}",
                            ]))
                            task_record = None
                            reserved_size: int | None = None
                            task_submitted = False
                            try:
                                content, filename = await adapter.download_torrent(candidate)
                                content_size = torrent_content_size_bytes(content)
                                reserved_size = content_size or candidate.size_bytes
                                if capacity_limit is not None and not reserved_size:
                                    counters["skipped_count"] += 1
                                    skip_reasons["无法确认资源体积"] += 1
                                    site_diagnostic["rejection_reasons"]["无法确认资源体积"] += 1
                                    continue
                                if not await reserve_capacity(reserved_size):
                                    counters["skipped_count"] += 1
                                    skip_reasons["达到刷流占用空间上限"] += 1
                                    site_diagnostic["rejection_reasons"]["达到刷流占用空间上限"] += 1
                                    continue
                                counters["attempted_count"] += 1
                                site_diagnostic["attempted_count"] += 1
                                task_record = repository.add_task({
                                    "task_key": key,
                                    "site_id": candidate.site_id,
                                    "site_name": candidate.site_name,
                                    "group_id": effective_group.id,
                                    "group_name": effective_group.name,
                                    "resource_id": candidate.resource_id,
                                    "title": candidate.title,
                                    "subtitle": candidate.subtitle,
                                    "size_bytes": content_size or candidate.size_bytes,
                                    "qbittorrent_hash": None,
                                    "downloader_type": downloader_type,
                                    "remote_task_id": None,
                                    "unique_tag": unique_tag,
                                    "category": category,
                                    "save_path": save_path,
                                    "status": "submitting",
                                    "rule_snapshot": {
                                        "group_id": effective_group.id,
                                        "group_name": effective_group.name,
                                        "rule": rule.model_dump(mode="json"),
                                        "reason": reason,
                                    },
                                    "torrent_tags": tags,
                                })
                                add_result = normalize_add_result(
                                    await client.add_torrent_bytes(
                                        content,
                                        filename=filename,
                                        save_path=save_path,
                                        category=category,
                                        tags=tags,
                                        automatic_management=effective_group.automatic_category,
                                        first_last_piece_priority=effective_group.first_last_piece_priority,
                                        lookup_tag=unique_tag,
                                    ),
                                    downloader_type,
                                )
                                task_submitted = True
                                if not add_result.task_identifier:
                                    raise DownloaderError("任务已提交，但下载器未返回任务标识，已停止记录。")
                                task_by_identity = getattr(client, "task_by_identity", None)
                                direct_item = await task_by_identity(add_result) if callable(task_by_identity) else None
                                added_items = [direct_item] if direct_item is not None else await client.list_torrents(tag=unique_tag)
                                if not added_items:
                                    all_items = await client.list_torrents()
                                    added_items = [
                                        item for item in all_items
                                        if (
                                            add_result.torrent_hash
                                            and str(item.get("hash") or "").casefold() == add_result.torrent_hash.casefold()
                                        )
                                        or (
                                            add_result.remote_task_id
                                            and str(item.get("remote_id") or "") == add_result.remote_task_id
                                        )
                                    ]
                                if len(added_items) == 1:
                                    added_item = added_items[0]
                                    actual_size = content_size or add_result.content_size or candidate.size_bytes
                                    if not actual_size:
                                        for size_key in ("total_size", "size", "totalSize"):
                                            size_value = added_item.get(size_key)
                                            if isinstance(size_value, int) and not isinstance(size_value, bool) and size_value > 0:
                                                actual_size = size_value
                                                break
                                    task_record = repository.update_task(
                                        task_record.id,
                                        qbittorrent_hash=str(added_item.get("hash") or "") or None,
                                        remote_task_id=str(added_item.get("remote_id")) if added_item.get("remote_id") is not None else None,
                                        status="downloading",
                                        error_message=None,
                                        size_bytes=actual_size,
                                    ) or task_record
                                if len(added_items) != 1 or not self._save_path_matches(task_record, added_items[0]):
                                    await client.pause_torrents([add_result.task_identifier])
                                    raise DownloaderError(f"{downloader_display_name(downloader_type)} 保存目录未保持在刷流专用目录，任务已暂停。")
                                if not await reconcile_capacity(reserved_size, task_record.size_bytes):
                                    await client.pause_torrents([add_result.task_identifier])
                                    raise DownloaderError("任务实际体积超过刷流占用空间上限，任务已暂停。")
                                group_count["tasks"] += 1
                                group_count["downloading"] += 1
                                group_added += 1
                                counters["added_count"] += 1
                                site_diagnostic["added_count"] += 1
                                added_task_snapshots.append({
                                    "task_id": task_record.id,
                                    "title": task_record.title,
                                    "site_id": task_record.site_id,
                                    "site_name": task_record.site_name,
                                    "group_id": task_record.group_id,
                                    "group_name": task_record.group_name,
                                    "size_bytes": task_record.size_bytes,
                                    "promotion_label": candidate.promotion_label,
                                    "downloader_type": task_record.downloader_type,
                                    "status": task_record.status,
                                    "added_at": task_record.added_at,
                                })
                                if settings.notifications_enabled:
                                    event = brush_task_added_event(
                                        run_id=run.id,
                                        task_id=task_record.id,
                                        title=task_record.title,
                                        site_name=task_record.site_name,
                                        size_bytes=task_record.size_bytes,
                                        downloader_type=task_record.downloader_type,
                                        discount_label=candidate.promotion_label,
                                    )
                                    store = self.store_factory()
                                    await send_or_defer_size_notification(
                                        store,
                                        event,
                                        [brush_size_target(task_record.id, task_record.size_bytes)],
                                    )
                            except Exception as exc:
                                if not task_submitted:
                                    await release_capacity(reserved_size)
                                if task_record is not None:
                                    repository.update_task(task_record.id, status="error", error_message=str(exc) or "添加刷流任务失败")
                                counters["error_count"] += 1
                                counters["submission_failed_count"] += 1
                                site_diagnostic["submission_failed_count"] += 1
                                details.append(f"{candidate.site_name}：添加任务失败：{exc}")

                group_results = await asyncio.gather(
                    *(process_group(group) for group in groups),
                    return_exceptions=True,
                )
                for group, result in zip(groups, group_results):
                    if isinstance(result, BaseException):
                        counters["error_count"] += 1
                        details.append(f"{group.name}：组内调度失败：{result}")
                if skip_reasons:
                    details.append(
                        "跳过原因：" + "、".join(
                            f"{reason} {count} 条"
                            for reason, count in skip_reasons.most_common()
                        )
                    )
                status = "success" if counters["error_count"] == 0 else "partial"
                if counters["matched_count"] == 0 and counters["candidates_count"]:
                    summary = f"读取 {counters['candidates_count']} 条 · 全部被规则排除"
                else:
                    summary = (
                        f"读取 {counters['candidates_count']} 条 · "
                        f"符合 {counters['matched_count']} 条 · 新增 {counters['added_count']} 条"
                    )
                diagnostics = {
                    "matched_count": counters["matched_count"],
                    "attempted_count": counters["attempted_count"],
                    "duplicate_count": counters["duplicate_count"],
                    "submission_failed_count": counters["submission_failed_count"],
                    "rejection_reasons": dict(skip_reasons),
                    "site_diagnostics": [
                        {**item, "rejection_reasons": dict(item["rejection_reasons"])}
                        for item in site_diagnostics
                    ],
                    "added_tasks": added_task_snapshots,
                }
                database_counters = {key: value for key, value in counters.items() if key in {
                    "candidates_count", "added_count", "skipped_count", "error_count"
                }}
                finished = repository.finish_run(
                    run.id,
                    status=status,
                    summary=summary,
                    details=details,
                    diagnostics=diagnostics,
                    **database_counters,
                )
                self._update_state(last_brush_at=now_iso(), last_error=details[-1] if counters["error_count"] else None)
                return finished
            except Exception as exc:
                safe = str(exc) or "刷流执行失败"
                self._update_state(last_brush_at=now_iso(), last_error=safe)
                await self._notify("error", "站点刷流", safe, run.id)
                return repository.finish_run(run.id, status="error", summary=safe, details=[*details, safe], error_count=counters["error_count"] + 1)
            finally:
                self._current_operation = None

    async def sync_tasks(
        self,
        *,
        task_snapshots: dict[str, list[dict[str, Any]]] | None = None,
        clients: dict[str, DownloaderClient] | None = None,
        snapshot_errors: dict[str, Exception] | None = None,
    ) -> dict[str, Any]:
        async with self._lock:
            self._current_operation = "检查刷流任务"
            try:
                return await self._sync_tasks_locked(
                    task_snapshots=task_snapshots,
                    clients=clients,
                    snapshot_errors=snapshot_errors,
                )
            except Exception as exc:
                safe = str(exc) or "刷流任务检查失败"
                self._update_state(last_check_at=now_iso(), last_error=safe)
                return {"checked_count": 0, "deleted_count": 0, "error_count": 1, "details": [safe]}
            finally:
                self._current_operation = None

    async def run_check(self, *, trigger: str = "manual") -> BrushRun:
        async with self._lock:
            repository = self.repository()
            run = repository.create_run("check", trigger=trigger)
            self._current_operation = "检查刷流任务"
            try:
                result = await self._sync_tasks_locked()
                summary = f"检查 {result['checked_count']} 条，清理 {result['deleted_count']} 条"
                return repository.finish_run(
                    run.id,
                    status="success" if result["error_count"] == 0 else "partial",
                    summary=summary,
                    details=result["details"],
                    checked_count=result["checked_count"],
                    deleted_count=result["deleted_count"],
                    error_count=result["error_count"],
                )
            except Exception as exc:
                safe = str(exc) or "刷流任务检查失败"
                self._update_state(last_check_at=now_iso(), last_error=safe)
                await self._notify("error", "站点刷流", safe, run.id)
                return repository.finish_run(run.id, status="error", summary=safe, details=[safe], error_count=1)
            finally:
                self._current_operation = None

    async def _sync_tasks_locked(
        self,
        *,
        task_snapshots: dict[str, list[dict[str, Any]]] | None = None,
        clients: dict[str, DownloaderClient] | None = None,
        snapshot_errors: dict[str, Exception] | None = None,
    ) -> dict[str, Any]:
        repository = self.repository()
        settings = self.settings()
        details: list[str] = []
        checked = deleted = errors = 0
        grouped: dict[str, list[BrushTask]] = {}
        for task in repository.checkable_tasks():
            grouped.setdefault(task.downloader_type, []).append(task)
        for downloader_type, tasks in grouped.items():
            try:
                if snapshot_errors and downloader_type in snapshot_errors:
                    raise snapshot_errors[downloader_type]
                client = (clients or {}).get(downloader_type) or self._client_for_type(downloader_type)
                if task_snapshots is not None and downloader_type in task_snapshots:
                    all_items = task_snapshots[downloader_type]
                else:
                    all_items = await client.list_torrents()
            except Exception as exc:
                errors += len(tasks)
                details.append(f"{downloader_display_name(downloader_type)}：{exc}")
                continue
            for task in tasks:
                checked += 1
                item = self._find_task_item(task, all_items)
                if item is None:
                    repository.update_task(
                        task.id,
                        status="missing",
                        last_checked_at=now_iso(),
                        error_message=f"{downloader_display_name(downloader_type)} 中未找到该刷流任务",
                    )
                    continue
                task = repository.update_task(
                    task.id,
                    qbittorrent_hash=str(item.get("hash") or "") or None,
                    remote_task_id=str(item.get("remote_id")) if item.get("remote_id") is not None else None,
                ) or task
                if not self._save_path_matches(task, item):
                    repository.update_task(task.id, status="error", last_checked_at=now_iso(), error_message="下载器保存目录已偏离刷流专用目录，禁止自动清理")
                    continue
                tags = split_tags(item.get("tags"))
                status = self._task_status(item)
                completed_at = task.completed_at or (now_iso() if status == "seeding" else None)
                updated = repository.update_task(
                    task.id,
                    status=status,
                    progress=float(item.get("progress") or 0),
                    download_speed=int(item.get("dlspeed") or 0),
                    upload_speed=int(item.get("upspeed") or 0),
                    downloaded=int(item.get("downloaded") or 0),
                    uploaded=int(item.get("uploaded") or 0),
                    size_bytes=task_total_size_bytes(item) or task.size_bytes,
                    ratio=float(item.get("ratio") or 0),
                    seeding_time=int(item.get("seeding_time") or 0),
                    completed_at=completed_at,
                    last_activity_at=self._activity_time(item),
                    last_checked_at=now_iso(),
                    torrent_tags=tags,
                    error_message=None,
                )
                reason = self._cleanup_reason(updated, item, settings) if updated else None
                if reason:
                    try:
                        await self._delete_owned_task(
                            updated,
                            item,
                            client,
                            reason=reason,
                            delete_files=settings.delete_files_on_cleanup,
                            all_items=all_items,
                        )
                        deleted += 1
                    except Exception as exc:
                        errors += 1
                        details.append(f"{task.site_name}：自动清理失败：{exc}")
            dynamic_deleted, dynamic_errors = await self._dynamic_cleanup(repository, tasks, all_items, client, settings, details)
            deleted += dynamic_deleted
            errors += dynamic_errors
        self._archive_old_tasks(repository, settings)
        self._next_check_at = utc_now() + timedelta(seconds=10)
        self._update_state(last_check_at=now_iso(), last_error=details[-1] if errors else None)
        return {
            "checked_count": checked,
            "deleted_count": deleted,
            "error_count": errors,
            "details": details,
        }

    @staticmethod
    def _task_status(item: dict[str, Any]) -> str:
        state = str(item.get("state") or "").lower()
        if "paused" in state or "stopped" in state:
            return "paused"
        if float(item.get("progress") or 0) >= 1:
            return "seeding"
        return "downloading"

    @staticmethod
    def _activity_time(item: dict[str, Any]) -> str | None:
        value = int(item.get("last_activity") or 0)
        return datetime.fromtimestamp(value, tz=timezone.utc).isoformat() if value > 0 else None

    def _cleanup_reason(self, task: BrushTask, item: dict[str, Any], settings: BrushSettings) -> str | None:
        if task.progress < 1 or float(item.get("progress") or 0) < 1:
            return None
        tags = set(split_tags(item.get("tags")))
        if tags.intersection(settings.cleanup_excluded_tags):
            return None
        snapshot = task.rule_snapshot or {}
        rule = BrushRule(**(snapshot.get("rule") or {}))
        if rule.seed_time_hours is not None and task.seeding_time >= rule.seed_time_hours * 3600:
            return f"做种时间达到 {rule.seed_time_hours:g} 小时"
        if rule.seed_ratio is not None and task.ratio >= rule.seed_ratio:
            return f"分享率达到 {rule.seed_ratio:g}"
        return None

    def _ownership_ok(self, task: BrushTask, item: dict[str, Any]) -> bool:
        expected_key = task_key(task.site_id, task.resource_id)
        tags = set(split_tags(item.get("tags")))
        persisted_tags = set(task.torrent_tags)
        persisted_base_tags = persisted_tags.intersection({BASE_TAG, *LEGACY_BASE_TAGS})
        identity_matches = bool(
            (task.remote_task_id and str(item.get("remote_id") or "") == task.remote_task_id)
            or (task.qbittorrent_hash and str(item.get("hash") or "").lower() == task.qbittorrent_hash.lower())
        )
        ownership_tags_ok = bool(
            task.unique_tag in tags
            and persisted_base_tags
            and persisted_base_tags.intersection(tags)
        )
        if task.downloader_type == "transmission" and not tags:
            ownership_tags_ok = identity_matches
        return bool(
            identity_matches
            and task.task_key == expected_key
            and task.unique_tag == f"AP刷流-{expected_key[:16]}"
            and ownership_tags_ok
            and self._save_path_matches(task, item)
        )

    @staticmethod
    def _find_task_item(task: BrushTask, items: list[dict[str, Any]]) -> dict[str, Any] | None:
        if task.remote_task_id:
            match = next((item for item in items if str(item.get("remote_id") or "") == task.remote_task_id), None)
            if match is not None:
                return match
        if task.qbittorrent_hash:
            match = next(
                (item for item in items if str(item.get("hash") or "").lower() == task.qbittorrent_hash.lower()),
                None,
            )
            if match is not None:
                return match
        tagged = [item for item in items if task.unique_tag in split_tags(item.get("tags")) and BASE_TAG in split_tags(item.get("tags"))]
        return tagged[0] if len(tagged) == 1 else None

    @staticmethod
    def _task_identifier(task: BrushTask, item: dict[str, Any] | None = None) -> str | None:
        if task.remote_task_id:
            return task.remote_task_id
        if task.qbittorrent_hash:
            return task.qbittorrent_hash
        if item is not None:
            return str(item.get("remote_id") or item.get("hash") or "") or None
        return None

    @staticmethod
    def _save_path_matches(task: BrushTask, item: dict[str, Any]) -> bool:
        item_save_path = str(item.get("save_path") or "").strip()
        return bool(
            item_save_path
            and Path(item_save_path).expanduser().resolve(strict=False)
            == Path(task.save_path).expanduser().resolve(strict=False)
        )

    @staticmethod
    def _transmission_manifest_matches(plan: dict[str, Any], item: dict[str, Any]) -> bool:
        planned = sorted(
            (str(file.get("relative_path") or ""), int(file.get("size") or 0))
            for file in plan.get("files") or []
            if isinstance(file, dict)
        )
        current = sorted(
            (str(file.get("name") or "").replace("\\", "/"), int(file.get("size") or 0))
            for file in item.get("files") or []
            if isinstance(file, dict)
        )
        return bool(planned) and planned == current

    @staticmethod
    def _transmission_snapshot_matches(before: dict[str, Any], after: dict[str, Any]) -> bool:
        identity_before = (
            str(before.get("remote_id") or ""),
            str(before.get("hash") or "").casefold(),
            str(before.get("save_path") or ""),
        )
        identity_after = (
            str(after.get("remote_id") or ""),
            str(after.get("hash") or "").casefold(),
            str(after.get("save_path") or ""),
        )
        files_before = sorted(
            (str(file.get("name") or "").replace("\\", "/"), int(file.get("size") or 0))
            for file in before.get("files") or [] if isinstance(file, dict)
        )
        files_after = sorted(
            (str(file.get("name") or "").replace("\\", "/"), int(file.get("size") or 0))
            for file in after.get("files") or [] if isinstance(file, dict)
        )
        return identity_before == identity_after and bool(files_before) and files_before == files_after

    @staticmethod
    def _paths_overlap(first: Path, second: Path) -> bool:
        return first == second or first in second.parents or second in first.parents

    async def _qbittorrent_referenced_paths(self, brush_root: str) -> set[str]:
        store = self.store_factory()
        if not downloader_configured(store, "qbittorrent"):
            return set()
        try:
            root = Path(brush_root).expanduser().resolve(strict=True)
            client = self._client_for_type("qbittorrent")
            items = await client.list_torrents()
            protected: set[str] = set()
            for item in items:
                raw_save_path = str(item.get("save_path") or "").strip()
                if not raw_save_path:
                    raise TransmissionDeleteError("qBittorrent 任务缺少保存目录，无法确认共享文件。")
                save_path = Path(raw_save_path).expanduser().resolve(strict=False)
                if not self._paths_overlap(root, save_path):
                    continue
                identifier = str(item.get("hash") or item.get("remote_id") or "").strip()
                if not identifier:
                    raise TransmissionDeleteError("qBittorrent 任务缺少稳定标识，无法确认共享文件。")
                files = item.get("files")
                if not isinstance(files, list) or not files:
                    files = await client.torrent_files(identifier)
                if not isinstance(files, list) or not files:
                    raise TransmissionDeleteError("qBittorrent 没有返回完整文件清单，无法确认共享文件。")
                for file in files:
                    if not isinstance(file, dict):
                        raise TransmissionDeleteError("qBittorrent 文件清单格式无效，无法确认共享文件。")
                    raw_name = str(file.get("name") or "")
                    relative = PurePosixPath(raw_name.replace("\\", "/"))
                    if (
                        not raw_name
                        or "\x00" in raw_name
                        or relative.is_absolute()
                        or any(part in {"", ".", ".."} for part in relative.parts)
                    ):
                        raise TransmissionDeleteError("qBittorrent 文件清单包含不安全路径，无法确认共享文件。")
                    target = save_path.joinpath(*relative.parts).resolve(strict=False)
                    protected.add(os.path.normcase(os.path.normpath(str(target))))
            return protected
        except TransmissionDeleteError:
            raise
        except Exception as exc:
            raise TransmissionDeleteError("无法确认 qBittorrent 是否引用相同文件，已阻止永久删除。") from exc

    async def _delete_transmission_task_and_files(
        self,
        task: BrushTask,
        item: dict[str, Any],
        client: DownloaderClient,
        *,
        all_items: list[dict[str, Any]],
    ) -> dict[str, str]:
        base_url = str(
            getattr(client, "base_url", "")
            or getattr(getattr(client, "config", None), "base_url", "")
        )
        mode = transmission_delete_mode(base_url)
        plans = DeletePlanStore(self.store_factory())
        existing = plans.get(task.id)
        if existing and existing.get("stage") in {"planned", "files_deleted"} and mode != BACKEND_LOCAL_MACOS:
            raise TransmissionDeleteError("删除计划创建后运行环境发生变化，已停止永久删除。")

        if mode == RPC_NATIVE:
            await client.delete_torrents([self._task_identifier(task, item) or ""], delete_files=True)
            return {"platform_mode": RPC_NATIVE, "stage": "task_removed"}

        async with self._delete_lock:
            task_id = self._task_identifier(task, item)
            if not task_id:
                raise TransmissionDeleteError("Transmission 任务缺少稳定标识，已阻止永久删除。")
            plan = plans.get(task.id)
            if plan and (
                plan.get("task_key") != task.task_key
                or str(plan.get("remote_id") or "") != str(task_id)
            ):
                raise TransmissionDeleteError("删除计划与当前任务身份不一致，已停止永久删除。")

            await client.pause_torrents([task_id])
            refreshed_items = await client.list_torrents()
            refreshed = self._find_task_item(task, refreshed_items)
            if refreshed is None or not self._ownership_ok(task, refreshed):
                raise TransmissionDeleteError("停止任务后无法再次确认任务归属，已阻止永久删除。")
            if not self._transmission_snapshot_matches(item, refreshed):
                raise TransmissionDeleteError("停止任务前后的身份或文件清单不一致，已阻止永久删除。")

            session_reader = getattr(client, "session_info", None)
            if not callable(session_reader):
                raise TransmissionDeleteError("无法读取 Transmission 临时文件设置，已阻止永久删除。")
            session = await session_reader()

            if plan and plan.get("stage") == "files_deleted":
                pass
            elif plan and plan.get("stage") == "planned":
                if not self._transmission_manifest_matches(plan, refreshed):
                    plans.update(task.id, stage="failed", error_code="manifest_changed")
                    raise TransmissionDeleteError("Transmission 文件清单在删除前发生变化，已停止永久删除。")
            else:
                plan = build_macos_delete_plan(
                    task_id=task.id,
                    task_key=task.task_key,
                    remote_id=str(task_id),
                    item=refreshed,
                    all_items=refreshed_items,
                    brush_root=self.settings().save_path,
                    session_info=session,
                )
                plan = plans.put(plan)

            if plan.get("stage") != "files_deleted":
                try:
                    protected_paths = await self._qbittorrent_referenced_paths(self.settings().save_path)
                    ensure_plan_paths_unshared(
                        plan,
                        brush_root=self.settings().save_path,
                        protected_paths=protected_paths,
                    )
                    delete_macos_plan_files(plan, brush_root=self.settings().save_path)
                except Exception as exc:
                    plans.update(task.id, stage="failed", error_code=type(exc).__name__)
                    raise
                plan = plans.update(task.id, stage="files_deleted") or plan

            try:
                await client.delete_torrents([task_id], delete_files=False)
            except Exception:
                remaining = await client.list_torrents()
                if self._find_task_item(task, remaining) is not None:
                    raise
            plans.update(task.id, stage="task_removed")
            return {"platform_mode": BACKEND_LOCAL_MACOS, "stage": "task_removed"}

    async def _recover_pending_transmission_deletes(self) -> None:
        plans = DeletePlanStore(self.store_factory())
        repository = self.repository()
        failures: list[str] = []
        for plan in plans.pending():
            task_id = int(plan.get("task_id") or 0)
            task = repository.get_task(task_id)
            if task is None or task.downloader_type != "transmission":
                plans.update(task_id, stage="failed", error_code="task_missing")
                continue
            try:
                client = self._client_for_type("transmission")
                items = await client.list_torrents()
                item = self._find_task_item(task, items)
                if item is None:
                    if plan.get("stage") != "files_deleted":
                        plans.update(task.id, stage="failed", error_code="remote_missing_before_files")
                        continue
                    plans.update(task.id, stage="task_removed")
                    repository.update_task(
                        task.id,
                        status="deleted",
                        deleted_at=now_iso(),
                        cleanup_reason=task.cleanup_reason or "恢复已完成的 Transmission 永久删除",
                        error_message=None,
                        download_speed=0,
                        upload_speed=0,
                    )
                    continue
                if not self._ownership_ok(task, item):
                    plans.update(task.id, stage="failed", error_code="ownership_changed")
                    continue
                await self._delete_owned_task(
                    task,
                    item,
                    client,
                    reason=task.cleanup_reason or "恢复 Transmission 永久删除",
                    delete_files=True,
                    all_items=items,
                )
            except Exception as exc:
                failures.append(str(exc) or "Transmission 删除计划恢复失败")
        if failures:
            raise TransmissionDeleteError(failures[-1])

    async def _delete_owned_task(
        self,
        task: BrushTask,
        item: dict[str, Any],
        client: DownloaderClient,
        *,
        reason: str,
        delete_files: bool,
        all_items: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        if not self._ownership_ok(task, item):
            self.repository().update_task(task.id, status="error", error_message="任务归属校验失败，禁止自动删除")
            raise DownloaderError("刷流任务归属校验失败，已禁止自动删除。")
        task_id = self._task_identifier(task, item)
        if not task_id:
            raise DownloaderError("刷流任务缺少远端标识，已禁止自动删除。")
        directory_target: ManagedDirectoryTarget | None = None
        directory_target_message: str | None = None
        if delete_files:
            directory_target, directory_target_message = await self._brush_directory_cleanup_target(
                task,
                item,
                client,
            )
        result: dict[str, Any] = {"stage": "task_removed"}
        if delete_files and task.downloader_type == "transmission":
            result = await self._delete_transmission_task_and_files(
                task,
                item,
                client,
                all_items=all_items or [item],
            )
        else:
            ensure_permanent_delete = getattr(client, "ensure_permanent_file_deletion", None)
            if delete_files and ensure_permanent_delete is not None:
                await ensure_permanent_delete()
            reannounce = getattr(client, "reannounce_torrents", None)
            if reannounce is not None:
                await reannounce([task_id])
            await client.delete_torrents([task_id], delete_files=delete_files)
        if delete_files:
            directory_cleanup = await self._cleanup_brush_directory_after_delete(
                client,
                directory_target,
                preparation_message=directory_target_message,
                already_verified=result.get("platform_mode") == BACKEND_LOCAL_MACOS,
            )
            result.update(directory_cleanup)
        self.repository().update_task(
            task.id,
            status="deleted",
            deleted_at=now_iso(),
            cleanup_reason=reason,
            download_speed=0,
            upload_speed=0,
        )
        await self._notify("deleted", task.site_name, f"{task.title} · {reason}", task.id)
        return result

    async def _brush_directory_cleanup_target(
        self,
        task: BrushTask,
        item: dict[str, Any],
        client: DownloaderClient,
    ) -> tuple[ManagedDirectoryTarget | None, str | None]:
        brush_root = self.settings().save_path.strip()
        if not brush_root:
            return None, "刷流专用目录未配置，未清理遗留目录。"
        task_root = Path(task.save_path).expanduser().absolute()
        configured_root = Path(brush_root).expanduser().absolute()
        if task_root != configured_root:
            return None, "任务保存目录与当前刷流专用目录不一致，未清理遗留目录。"
        snapshot = dict(item)
        if not isinstance(snapshot.get("files"), list) or not snapshot.get("files"):
            task_id = self._task_identifier(task, item)
            file_reader = getattr(client, "torrent_files", None)
            if task_id and callable(file_reader):
                try:
                    snapshot["files"] = await file_reader(task_id)
                except Exception:
                    logger.info("刷流任务文件清单读取失败，空目录清理将使用已确认的任务路径。")
        target = brush_task_directory(snapshot, brush_root=configured_root)
        if target is None:
            return None, "无法从下载器任务路径或文件清单确认专属目录，未清理遗留目录。"
        return target, None

    @staticmethod
    def _remaining_brush_task_usage(
        item: dict[str, Any],
        target: ManagedDirectoryTarget,
    ) -> bool | None:
        other_target = brush_task_directory(item, brush_root=target.root)
        if other_target is not None:
            return paths_overlap(other_target.path, target.path)
        save_path_text = str(item.get("save_path") or item.get("savePath") or "").strip()
        if not save_path_text:
            return None
        save_path = Path(save_path_text).expanduser().absolute()
        if save_path == target.path:
            return True
        if save_path == target.root:
            return None
        return paths_overlap(save_path, target.path)

    async def _cleanup_brush_directory_after_delete(
        self,
        client: DownloaderClient,
        target: ManagedDirectoryTarget | None,
        *,
        preparation_message: str | None,
        already_verified: bool,
    ) -> dict[str, Any]:
        if target is None:
            return {
                "directory_cleanup_status": "skipped",
                "directory_cleanup_message": preparation_message or "未找到可安全清理的刷流任务目录。",
                "directory_cleanup_deleted_count": 0,
            }
        if not already_verified:
            try:
                remaining_items = await client.list_torrents()
            except Exception as exc:
                return {
                    "directory_cleanup_status": "skipped",
                    "directory_cleanup_message": f"无法确认删除后的下载器任务，未清理遗留目录：{exc}",
                    "directory_cleanup_deleted_count": 0,
                }
            usage = [self._remaining_brush_task_usage(item, target) for item in remaining_items]
            if any(value is True for value in usage):
                return {
                    "directory_cleanup_status": "skipped",
                    "directory_cleanup_message": "仍有下载器任务使用该刷流目录，未清理。",
                    "directory_cleanup_deleted_count": 0,
                }
            if any(value is None for value in usage):
                return {
                    "directory_cleanup_status": "skipped",
                    "directory_cleanup_message": "无法确认其他下载器任务的文件路径，未清理刷流目录。",
                    "directory_cleanup_deleted_count": 0,
                }
        cleanup = prune_empty_managed_directory(target.path, managed_root=target.root)
        logger.info("刷流空目录清理结果：%s，%s", cleanup.status, cleanup.message)
        return {
            "directory_cleanup_status": cleanup.status,
            "directory_cleanup_message": cleanup.message,
            "directory_cleanup_deleted_count": cleanup.deleted_count,
        }

    async def _dynamic_cleanup(
        self,
        repository: BrushRepository,
        tasks: list[BrushTask],
        items: list[dict[str, Any]],
        client: DownloaderClient,
        settings: BrushSettings,
        details: list[str],
    ) -> tuple[int, int]:
        if settings.dynamic_cleanup_min_gb is None or settings.dynamic_cleanup_max_gb is None:
            return 0, 0
        tasks = [task for task in tasks if task.status not in {"deleted", "archived", "error"} and self._find_task_item(task, items) is not None]
        total = sum(task.size_bytes or 0 for task in tasks)
        if total <= settings.dynamic_cleanup_max_gb * 1024 ** 3:
            return 0, 0
        target = settings.dynamic_cleanup_min_gb * 1024 ** 3
        candidates = sorted(tasks, key=lambda task: (task.uploaded / max(task.seeding_time, 1), task.added_at))
        deleted = 0
        errors = 0
        for task in candidates:
            if total <= target:
                break
            item = self._find_task_item(task, items)
            if item is None:
                continue
            if set(split_tags(item.get("tags"))).intersection(settings.cleanup_excluded_tags):
                continue
            if self._cleanup_reason(task, item, settings) is None:
                continue
            try:
                await self._delete_owned_task(
                    task,
                    item,
                    client,
                    reason="动态空间回收",
                    delete_files=settings.delete_files_on_cleanup,
                    all_items=items,
                )
                total -= task.size_bytes or 0
                deleted += 1
            except Exception as exc:
                errors += 1
                details.append(f"{task.site_name}：动态空间回收失败：{exc}")
        return deleted, errors

    @staticmethod
    def _archive_old_tasks(repository: BrushRepository, settings: BrushSettings) -> None:
        if not settings.archive_after_days:
            return
        cutoff = utc_now() - timedelta(days=settings.archive_after_days)
        for task in repository.list_tasks(include_archived=True):
            if task.status not in {"deleted", "error", "missing"}:
                continue
            reference = parse_datetime(task.deleted_at or task.last_checked_at or task.added_at)
            if reference and reference <= cutoff:
                repository.update_task(task.id, status="archived")

    async def manage_task(self, task_id: int, action: str) -> BrushActionResponse:
        repository = self.repository()
        task = repository.get_task(task_id)
        if not task:
            return BrushActionResponse(ok=False, message="刷流任务不存在。")
        if action == "archive":
            repository.update_task(task.id, status="archived")
            return BrushActionResponse(ok=True, message="刷流任务已归档。", affected=1)
        client = self._client_for_type(task.downloader_type)
        all_items = await client.list_torrents()
        item = self._find_task_item(task, all_items)
        if not item:
            tag_matches = [item for item in all_items if task.unique_tag in split_tags(item.get("tags"))]
            if tag_matches:
                return BrushActionResponse(ok=False, message="任务唯一标签仍指向其他下载器任务，归属校验失败，操作已取消。")
            if action in {"delete", "delete_files"}:
                return await self._finish_missing_manual_delete(task, delete_files_requested=action == "delete_files")
            name = downloader_display_name(task.downloader_type)
            repository.update_task(task.id, status="missing", error_message=f"{name} 中未找到该任务")
            return BrushActionResponse(ok=False, message=f"{name} 中未找到该刷流任务。")
        if not self._ownership_ok(task, item):
            return BrushActionResponse(ok=False, message="任务归属校验失败，操作已取消。")
        task_id_value = self._task_identifier(task, item)
        if not task_id_value:
            return BrushActionResponse(ok=False, message="任务缺少远端标识，操作已取消。")
        result: dict[str, Any] = {}
        if action == "pause":
            await client.pause_torrents([task_id_value])
            repository.update_task(task.id, status="paused")
            message = "刷流任务已暂停。"
        elif action == "resume":
            await client.resume_torrents([task_id_value])
            repository.update_task(task.id, status=self._task_status(item))
            message = "刷流任务已恢复。"
        elif action in {"delete", "delete_files"}:
            try:
                result = await self._delete_owned_task(
                    task,
                    item,
                    client,
                    reason="用户手动删除",
                    delete_files=action == "delete_files",
                    all_items=all_items,
                )
            except Exception:
                remaining = await client.list_torrents()
                identity_still_exists = self._find_task_item(task, remaining) is not None
                tag_still_exists = any(task.unique_tag in split_tags(existing.get("tags")) for existing in remaining)
                if identity_still_exists or tag_still_exists:
                    raise
                return await self._finish_missing_manual_delete(task, delete_files_requested=action == "delete_files")
            message = "刷流任务和文件已永久删除，无法恢复。" if action == "delete_files" else "刷流任务已删除，文件已保留。"
        else:
            return BrushActionResponse(ok=False, message="不支持的刷流任务操作。")
        return BrushActionResponse(ok=True, message=message, affected=1, **result)

    async def _finish_missing_manual_delete(self, task: BrushTask, *, delete_files_requested: bool) -> BrushActionResponse:
        reason = f"{downloader_display_name(task.downloader_type)} 任务已不存在，用户清理本地记录"
        self.repository().update_task(
            task.id,
            status="deleted",
            deleted_at=now_iso(),
            cleanup_reason=reason,
            error_message=None,
            download_speed=0,
            upload_speed=0,
        )
        await self._notify("deleted", task.site_name, f"{task.title} · {reason}", task.id)
        message = f"{downloader_display_name(task.downloader_type)} 任务已不存在，已删除本地记录"
        if delete_files_requested:
            message += "，文件未处理"
        return BrushActionResponse(ok=True, message=f"{message}。", affected=1)

    async def batch_manage(self, task_ids: list[int], action: str) -> BrushActionResponse:
        affected = 0
        failures: list[str] = []
        for task_id in list(dict.fromkeys(task_ids)):
            try:
                response = await self.manage_task(task_id, action)
                if response.ok:
                    affected += response.affected
                else:
                    failures.append(response.message)
            except Exception as exc:
                failures.append(str(exc))
        if action in {"delete", "delete_files"}:
            message = f"成功清理 {affected} 条刷流任务，失败 {len(failures)} 条。"
        else:
            message = f"已处理 {affected} 条刷流任务" + (f"，{len(failures)} 条失败" if failures else "")
        return BrushActionResponse(
            ok=not failures,
            message=message,
            affected=affected,
        )

    async def _notify(self, kind: str, subject: str, body: str, identifier: int) -> None:
        if not self.settings().notifications_enabled:
            return
        titles = {"added": "新增刷流任务", "deleted": "刷流任务已清理", "error": "站点刷流异常"}
        event_types = {"added": "brush_task_added", "deleted": "brush_task_deleted", "error": "brush_error"}
        await NotificationService(self.store_factory()).send_best_effort(
            NotificationEvent(
                event_key=f"{event_types[kind]}:{identifier}:{hashlib.sha1(body.encode()).hexdigest()[:10]}",
                event_type=event_types[kind],
                title=f"{titles[kind]}：{subject}",
                body=body[:500],
                resource_title=body[:240],
            )
        )
