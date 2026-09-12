from __future__ import annotations

import re
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


BrushPromotionMode = Literal["free", "2xfree", "any"]
BrushPromotionChoice = Literal["free", "2xfree"]
BrushTaskStatus = Literal["submitting", "downloading", "seeding", "paused", "missing", "deleted", "error", "archived"]


class BrushCapabilities(BaseModel):
    site_id: str
    supports_promotion: bool = True
    supports_double_upload: bool = False
    supports_seeders: bool = True
    supports_pagination: bool = True
    missing_fields: list[str] = Field(default_factory=list)


class BrushCandidate(BaseModel):
    site_id: str
    site_name: str
    resource_id: str
    title: str
    subtitle: str | None = None
    size_bytes: int | None = None
    published_at: str | None = None
    seeders: int | None = None
    leechers: int | None = None
    completed: int | None = None
    download_factor: float | None = None
    upload_factor: float | None = None
    promotion_label: str | None = None
    promotion_until: str | None = None
    page: int = 1
    downloadable: bool = True
    unavailable_reason: str | None = None
    download_url: str | None = Field(default=None, exclude=True)
    detail_url: str | None = Field(default=None, exclude=True)
    source_result: dict = Field(default_factory=dict, exclude=True)


class BrushCandidatePage(BaseModel):
    site_id: str
    site_name: str
    page: int
    has_more: bool
    capabilities: BrushCapabilities
    candidates: list[BrushCandidate] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


class BrushRule(BaseModel):
    promotion_mode: BrushPromotionMode = "free"
    promotion_modes: list[BrushPromotionChoice] = Field(default_factory=lambda: ["free", "2xfree"])
    include_pattern: str | None = None
    exclude_pattern: str | None = None
    size_min_gb: float | None = Field(default=None, ge=0)
    size_max_gb: float | None = Field(default=None, ge=0)
    seeders_min: int | None = Field(default=None, ge=0)
    seeders_max: int | None = Field(default=None, ge=0)
    publish_age_min_minutes: int | None = Field(default=None, ge=0)
    publish_age_max_minutes: int | None = Field(default=120, ge=0)
    seed_time_hours: float | None = Field(default=72, ge=0)
    seed_ratio: float | None = Field(default=2, ge=0)
    uploaded_gb: float | None = Field(default=None, ge=0)
    download_timeout_hours: float | None = Field(default=None, ge=0)
    minimum_average_upload_kib: float | None = Field(default=None, ge=0)
    inactive_minutes: float | None = Field(default=None, ge=0)

    @model_validator(mode="before")
    @classmethod
    def migrate_legacy_promotion_mode(cls, value: object) -> object:
        if not isinstance(value, dict):
            return value
        migrated = dict(value)
        if migrated.get("promotion_modes") is None:
            migrated["promotion_modes"] = {
                "free": ["free", "2xfree"],
                "2xfree": ["2xfree"],
                "any": [],
            }.get(str(migrated.get("promotion_mode") or "free"), ["free", "2xfree"])
        return migrated

    @field_validator("promotion_modes")
    @classmethod
    def normalize_promotion_modes(cls, value: list[BrushPromotionChoice]) -> list[BrushPromotionChoice]:
        return [mode for mode in ("free", "2xfree") if mode in value]

    @model_validator(mode="after")
    def validate_ranges(self) -> BrushRule:
        selected_promotions = set(self.promotion_modes)
        if not selected_promotions:
            self.promotion_mode = "any"
        elif selected_promotions == {"2xfree"}:
            self.promotion_mode = "2xfree"
        else:
            self.promotion_mode = "free"
        if self.size_min_gb is not None and self.size_max_gb is not None and self.size_min_gb > self.size_max_gb:
            raise ValueError("刷流资源最小体积不能大于最大体积。")
        if self.seeders_min is not None and self.seeders_max is not None and self.seeders_min > self.seeders_max:
            raise ValueError("最少做种数不能大于最多做种数。")
        if (
            self.publish_age_min_minutes is not None
            and self.publish_age_max_minutes is not None
            and self.publish_age_min_minutes > self.publish_age_max_minutes
        ):
            raise ValueError("最短发布时间不能大于最大发布时间。")
        return self


class BrushSiteOverride(BaseModel):
    enabled: bool = True
    rule: BrushRule | None = None
    seed_time_hours: float | None = Field(default=None, ge=0)
    seed_ratio: float | None = Field(default=None, ge=0)

    @model_validator(mode="before")
    @classmethod
    def migrate_legacy_cleanup_overrides(cls, value: object) -> object:
        if not isinstance(value, dict):
            return value
        migrated = dict(value)
        legacy_rule = migrated.get("rule")
        if isinstance(legacy_rule, dict):
            if "seed_time_hours" not in migrated and legacy_rule.get("seed_time_hours") is not None:
                migrated["seed_time_hours"] = legacy_rule.get("seed_time_hours")
            if "seed_ratio" not in migrated and legacy_rule.get("seed_ratio") is not None:
                migrated["seed_ratio"] = legacy_rule.get("seed_ratio")
        return migrated


class BrushGroup(BaseModel):
    id: str
    name: str
    enabled: bool = True
    site_ids: list[str] = Field(default_factory=list)
    rule: BrushRule = Field(default_factory=BrushRule)
    exclude_subscriptions: bool = True
    max_tasks: int | None = Field(default=None, ge=1)
    max_downloading: int | None = Field(default=3, ge=1)
    max_additions_per_run: int = Field(default=1, ge=1, le=100)
    candidates_per_site: int = Field(default=50, ge=1, le=100)
    sequential_sites: bool = False
    automatic_category: bool = False
    first_last_piece_priority: bool = False

    @field_validator("id")
    @classmethod
    def validate_id(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", normalized):
            raise ValueError("刷流分组 ID 格式无效。")
        return normalized

    @field_validator("name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("刷流分组名称不能为空。")
        if len(normalized) > 40:
            raise ValueError("刷流分组名称不能超过 40 个字符。")
        return normalized

    @field_validator("site_ids")
    @classmethod
    def normalize_site_ids(cls, value: list[str]) -> list[str]:
        allowed = {"mteam", "hddolby", "soulvoice", "opencd"}
        return [site for site in dict.fromkeys(item.strip().lower() for item in value) if site in allowed]


class BrushSettings(BaseModel):
    enabled: bool = False
    notifications_enabled: bool = True
    selected_sites: list[str] = Field(default_factory=lambda: ["mteam", "hddolby", "soulvoice", "opencd"])
    save_path: str = ""
    category: str = "Kisetsu刷流"
    tags: list[str] = Field(default_factory=lambda: ["Kisetsu刷流"])
    brush_interval_minutes: int = Field(default=10, ge=1, le=1440)
    check_interval_minutes: int = Field(default=5, ge=1, le=1440)
    active_time_start: str | None = None
    active_time_end: str | None = None
    sequential_sites: bool = False
    exclude_subscriptions: bool = True
    max_storage_gb: float | None = Field(default=None, gt=0)
    max_tasks: int | None = Field(default=None, ge=1)
    max_downloading: int | None = Field(default=3, ge=1)
    max_additions_per_run: int = Field(default=1, ge=1, le=100)
    automatic_category: bool = False
    first_last_piece_priority: bool = False
    proxy_download: bool = False
    delete_files_on_cleanup: bool = True
    cleanup_excluded_tags: list[str] = Field(default_factory=list)
    dynamic_cleanup_min_gb: float | None = Field(default=None, ge=0)
    dynamic_cleanup_max_gb: float | None = Field(default=None, ge=0)
    archive_after_days: int | None = Field(default=30, ge=1)
    candidates_per_site: int = Field(default=50, ge=1, le=100)
    global_rule: BrushRule = Field(default_factory=BrushRule)
    site_overrides: dict[str, BrushSiteOverride] = Field(default_factory=dict)
    groups: list[BrushGroup] = Field(default_factory=list)

    @model_validator(mode="before")
    @classmethod
    def migrate_legacy_groups(cls, value: object) -> object:
        if not isinstance(value, dict):
            return value
        migrated = dict(value)
        existing_groups = migrated.get("groups")
        if existing_groups is not None:
            if isinstance(existing_groups, list):
                legacy_sequential = migrated.get("sequential_sites", False)
                migrated["groups"] = [
                    {
                        **group,
                        "sequential_sites": group.get("sequential_sites", legacy_sequential),
                    }
                    if isinstance(group, dict)
                    else group
                    for group in existing_groups
                ]
            return migrated

        allowed_sites = ["mteam", "hddolby", "soulvoice", "opencd"]
        selected = migrated.get("selected_sites")
        if not isinstance(selected, list):
            selected = allowed_sites
        selected = [
            site for site in dict.fromkeys(str(item).strip().lower() for item in selected)
            if site in allowed_sites
        ]
        global_rule = dict(migrated.get("global_rule") or {})
        overrides = migrated.get("site_overrides") or {}
        if not isinstance(overrides, dict):
            overrides = {}
        shared = {
            "exclude_subscriptions": migrated.get("exclude_subscriptions", True),
            "max_tasks": migrated.get("max_tasks"),
            "max_downloading": migrated.get("max_downloading", 3),
            "max_additions_per_run": migrated.get("max_additions_per_run", 1),
            "candidates_per_site": migrated.get("candidates_per_site", 50),
            "sequential_sites": migrated.get("sequential_sites", False),
            "automatic_category": migrated.get("automatic_category", False),
            "first_last_piece_priority": migrated.get("first_last_piece_priority", False),
        }
        site_names = {
            "mteam": "M-Team",
            "hddolby": "HD Dolby",
            "soulvoice": "SoulVoice",
            "opencd": "OpenCD",
        }
        default_sites: list[str] = []
        groups: list[dict[str, object]] = []
        for site_id in selected:
            override = overrides.get(site_id)
            if not isinstance(override, dict):
                override = {}
            if override.get("enabled") is False:
                continue
            override_rule = override.get("rule")
            has_custom_rule = isinstance(override_rule, dict)
            has_custom_cleanup = override.get("seed_time_hours") is not None or override.get("seed_ratio") is not None
            if not has_custom_rule and not has_custom_cleanup:
                default_sites.append(site_id)
                continue
            rule = dict(override_rule) if has_custom_rule else dict(global_rule)
            if override.get("seed_time_hours") is not None:
                rule["seed_time_hours"] = override.get("seed_time_hours")
            if override.get("seed_ratio") is not None:
                rule["seed_ratio"] = override.get("seed_ratio")
            groups.append({
                "id": f"site-{site_id}",
                "name": f"{site_names.get(site_id, site_id)} 分组",
                "site_ids": [site_id],
                "rule": rule,
                **shared,
            })
        if default_sites or not groups:
            groups.insert(0, {
                "id": "default",
                "name": "默认分组",
                "site_ids": default_sites,
                "rule": global_rule,
                **shared,
            })
        migrated["groups"] = groups
        return migrated

    @field_validator("selected_sites")
    @classmethod
    def normalize_sites(cls, value: list[str]) -> list[str]:
        allowed = {"mteam", "hddolby", "soulvoice", "opencd"}
        return [site for site in dict.fromkeys(item.strip().lower() for item in value) if site in allowed]

    @field_validator("tags", "cleanup_excluded_tags")
    @classmethod
    def normalize_tags(cls, value: list[str]) -> list[str]:
        return [tag for tag in dict.fromkeys(item.strip() for item in value) if tag]

    @field_validator("active_time_start", "active_time_end")
    @classmethod
    def validate_clock(cls, value: str | None) -> str | None:
        if value in (None, ""):
            return None
        try:
            datetime.strptime(value, "%H:%M")
        except ValueError as exc:
            raise ValueError("活动时间必须使用 HH:mm 格式。") from exc
        return value

    @model_validator(mode="after")
    def validate_settings(self) -> BrushSettings:
        group_ids: set[str] = set()
        group_names: set[str] = set()
        assigned_sites: set[str] = set()
        ordered_sites: list[str] = []
        for group in self.groups:
            if group.id in group_ids:
                raise ValueError("刷流分组 ID 不能重复。")
            group_ids.add(group.id)
            normalized_name = group.name.casefold()
            if normalized_name in group_names:
                raise ValueError("刷流分组名称不能重复。")
            group_names.add(normalized_name)
            duplicated = assigned_sites.intersection(group.site_ids)
            if duplicated:
                raise ValueError(f"站点不能同时属于多个刷流分组：{sorted(duplicated)[0]}")
            assigned_sites.update(group.site_ids)
            ordered_sites.extend(group.site_ids)
        self.selected_sites = ordered_sites
        if self.groups:
            compatibility_group = next((group for group in self.groups if group.enabled and group.site_ids), self.groups[0])
            self.global_rule = compatibility_group.rule.model_copy(deep=True)
            self.exclude_subscriptions = compatibility_group.exclude_subscriptions
            self.max_tasks = compatibility_group.max_tasks
            self.max_downloading = compatibility_group.max_downloading
            self.max_additions_per_run = compatibility_group.max_additions_per_run
            self.candidates_per_site = compatibility_group.candidates_per_site
            self.sequential_sites = compatibility_group.sequential_sites
            self.automatic_category = compatibility_group.automatic_category
            self.first_last_piece_priority = compatibility_group.first_last_piece_priority
            compatible_overrides = dict(self.site_overrides)
            for group in self.groups:
                for site_id in group.site_ids:
                    compatible_overrides[site_id] = BrushSiteOverride(
                        enabled=group.enabled,
                        rule=group.rule.model_copy(deep=True),
                        seed_time_hours=group.rule.seed_time_hours,
                        seed_ratio=group.rule.seed_ratio,
                    )
            self.site_overrides = compatible_overrides
        if self.enabled and not any(group.enabled and group.site_ids for group in self.groups):
            raise ValueError("请至少选择一个刷流站点。")
        if self.enabled and not self.save_path.strip():
            raise ValueError("请设置刷流专用保存目录。")
        if (
            self.dynamic_cleanup_min_gb is not None
            and self.dynamic_cleanup_max_gb is not None
            and self.dynamic_cleanup_min_gb >= self.dynamic_cleanup_max_gb
        ):
            raise ValueError("动态清理下限必须小于上限。")
        return self


class BrushTask(BaseModel):
    id: int
    task_key: str
    site_id: str
    site_name: str
    group_id: str | None = None
    group_name: str | None = None
    resource_id: str
    title: str
    subtitle: str | None = None
    size_bytes: int | None = None
    qbittorrent_hash: str | None = None
    downloader_type: Literal["qbittorrent", "transmission"] = "qbittorrent"
    remote_task_id: str | None = None
    unique_tag: str
    category: str
    save_path: str
    status: BrushTaskStatus
    progress: float = 0
    download_speed: int = 0
    upload_speed: int = 0
    downloaded: int = 0
    uploaded: int = 0
    ratio: float = 0
    seeding_time: int = 0
    added_at: str
    completed_at: str | None = None
    last_activity_at: str | None = None
    last_checked_at: str | None = None
    deleted_at: str | None = None
    cleanup_reason: str | None = None
    error_message: str | None = None
    rule_snapshot: dict = Field(default_factory=dict)
    torrent_tags: list[str] = Field(default_factory=list)


class BrushRunTaskSnapshot(BaseModel):
    task_id: int
    title: str
    site_id: str
    site_name: str
    group_id: str | None = None
    group_name: str | None = None
    size_bytes: int | None = None
    promotion_label: str | None = None
    downloader_type: Literal["qbittorrent", "transmission"] = "qbittorrent"
    status: BrushTaskStatus
    added_at: str


class BrushRun(BaseModel):
    id: int
    run_type: Literal["brush", "check"]
    status: Literal["running", "success", "partial", "error", "skipped"]
    started_at: str
    finished_at: str | None = None
    candidates_count: int = 0
    added_count: int = 0
    checked_count: int = 0
    deleted_count: int = 0
    skipped_count: int = 0
    error_count: int = 0
    summary: str | None = None
    details: list[str] = Field(default_factory=list)
    matched_count: int = 0
    attempted_count: int = 0
    duplicate_count: int = 0
    submission_failed_count: int = 0
    rejection_reasons: dict[str, int] = Field(default_factory=dict)
    site_diagnostics: list[BrushSiteRunDiagnostic] = Field(default_factory=list)
    trigger: str | None = None
    added_tasks: list[BrushRunTaskSnapshot] = Field(default_factory=list)


class BrushSiteRunDiagnostic(BaseModel):
    group_id: str | None = None
    group_name: str | None = None
    site_id: str
    site_name: str
    read_count: int = 0
    matched_count: int = 0
    attempted_count: int = 0
    added_count: int = 0
    duplicate_count: int = 0
    submission_failed_count: int = 0
    rejection_reasons: dict[str, int] = Field(default_factory=dict)
    error: str | None = None


class BrushSiteAccount(BaseModel):
    site_id: str
    site_name: str
    uploaded_bytes: int | None = None
    downloaded_bytes: int | None = None
    ratio: float | None = None
    fetched_at: str
    status: Literal["success", "error"] = "success"
    error: str | None = None


class BrushStats(BaseModel):
    total_tasks: int = 0
    active_tasks: int = 0
    downloading_tasks: int = 0
    seeding_tasks: int = 0
    deleted_tasks: int = 0
    occupied_bytes: int = 0
    uploaded_bytes: int = 0
    downloaded_bytes: int = 0
    overall_ratio: float = 0


class BrushDownloaderTransfer(BaseModel):
    downloader_type: Literal["qbittorrent", "transmission"]
    downloader_name: str
    downloaded_bytes: int | None = Field(default=None, ge=0)
    uploaded_bytes: int | None = Field(default=None, ge=0)
    overall_ratio: float | None = Field(default=None, ge=0)
    fetched_at: str | None = None
    available: bool = False
    error: str | None = None


class BrushDeleteCapability(BaseModel):
    available: bool = False
    platform_mode: Literal["backend_local_macos", "rpc_native"] | None = None
    reason: str | None = None


class BrushStatus(BaseModel):
    enabled: bool = False
    scheduler_running: bool = False
    current_operation: str | None = None
    next_brush_at: str | None = None
    next_check_at: str | None = None
    last_brush_at: str | None = None
    last_check_at: str | None = None
    last_error: str | None = None
    message: str = "站点刷流未启用"
    stats: BrushStats = Field(default_factory=BrushStats)
    downloader_transfer: BrushDownloaderTransfer | None = None
    transmission_delete_capability: BrushDeleteCapability = Field(default_factory=BrushDeleteCapability)


class BrushActionRequest(BaseModel):
    action: Literal["pause", "resume", "delete", "delete_files", "archive"]


class BrushBatchActionRequest(BaseModel):
    task_ids: list[int]
    action: Literal["pause", "resume", "delete", "delete_files", "archive"]


class BrushActionResponse(BaseModel):
    ok: bool
    message: str
    affected: int = 0
    platform_mode: Literal["backend_local_macos", "rpc_native"] | None = None
    stage: Literal["planned", "files_deleted", "task_removed", "failed"] | None = None
    directory_cleanup_status: str | None = None
    directory_cleanup_message: str | None = None
    directory_cleanup_deleted_count: int = 0


class BrushRunResponse(BaseModel):
    ok: bool
    message: str
    status: BrushStatus
    run: BrushRun | None = None


class BrushClearRequest(BaseModel):
    include_active: bool = False
    confirm: bool = False
