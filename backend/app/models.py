from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, field_validator, model_validator

from app.keyword_expression import KeywordExpressionError, normalize_keyword_expression_items


LEGACY_SITE_ID_ALIASES = {
    "dmhy": "dmhy",
    "share.dmhy.org": "dmhy",
    "dmhy.org": "dmhy",
    "https://share.dmhy.org": "dmhy",
    "http://share.dmhy.org": "dmhy",
    "https://dmhy.org": "dmhy",
    "http://dmhy.org": "dmhy",
    "mikan": "mikan",
    "mikanani.me": "mikan",
    "https://mikanani.me": "mikan",
    "http://mikanani.me": "mikan",
    "nyaa": "nyaa",
    "nyaa.si": "nyaa",
    "https://nyaa.si": "nyaa",
    "http://nyaa.si": "nyaa",
    "mteam": "mteam",
    "m-team": "mteam",
    "m-team.cc": "mteam",
    "kp.m-team.cc": "mteam",
    "https://kp.m-team.cc": "mteam",
    "https://kp.m-team.cc/index": "mteam",
    "https://m-team.cc": "mteam",
    "soulvoice": "soulvoice",
    "pt.soulvoice.club": "soulvoice",
    "https://pt.soulvoice.club": "soulvoice",
    "hddolby": "hddolby",
    "hd dolby": "hddolby",
    "hddolby.com": "hddolby",
    "www.hddolby.com": "hddolby",
    "https://www.hddolby.com": "hddolby",
    "https://www.hddolby.com/index.php": "hddolby",
}


def normalize_site_id(value: str) -> str:
    cleaned = value.strip().rstrip("/")
    lowered = cleaned.lower()
    if lowered in LEGACY_SITE_ID_ALIASES:
        return LEGACY_SITE_ID_ALIASES[lowered]
    parsed = urlparse(cleaned)
    host = (parsed.netloc or parsed.path).lower().strip("/")
    return LEGACY_SITE_ID_ALIASES.get(host, cleaned)


RESOLUTION_PRESETS = {"720p", "1080p", "2160p", "4k"}


class HealthResponse(BaseModel):
    ok: bool = True
    status: str = "ok"
    app: str = "Kisetsu"
    version: str = "0.1.0"
    message: str = "后端连接正常"
    time: datetime
    port: int | None = None
    database_status: str = "ok"
    qbittorrent_configured: bool = False
    transmission_configured: bool = False
    started_at: datetime | None = None
    pid: int | None = None


class SiteInfo(BaseModel):
    id: str
    name: str
    display_name: str | None = None
    base_url: str | None = None
    primary_url: str | None = None
    mirrors: list[str] = Field(default_factory=list)
    active_base_url: str | None = None
    enabled: bool = True
    brush_only: bool = False
    supports_search: bool = True
    supports_rss: bool = True
    supports_brush: bool = False
    auth_mode: Literal["none", "cookie", "api_key", "api_key_cookie"] = "none"
    auth_fields: list[str] = Field(default_factory=list)
    api_key_configured: bool = False
    api_key_masked: str | None = None
    cookie_configured: bool = False
    cookie_masked: str | None = None
    passkey_configured: bool = False
    passkey_masked: str | None = None
    authorization_configured: bool = False
    authorization_masked: str | None = None
    user_agent: str | None = None
    timeout_seconds: int | None = None
    rss_url: str | None = None
    rss_url_configured: bool = False
    rss_url_masked: str | None = None
    default_rss_url: str | None = None
    request_headers_configured: bool = False
    request_headers_masked: dict[str, str] = Field(default_factory=dict)


class SiteSettingsUpdate(BaseModel):
    display_name: str | None = None
    primary_url: str | None = None
    mirrors: list[str] = Field(default_factory=list)
    active_base_url: str | None = None
    enabled: bool = True
    brush_only: bool = False
    api_key: str | None = None
    clear_api_key: bool = False
    cookie: str | None = None
    clear_cookie: bool = False
    passkey: str | None = None
    clear_passkey: bool = False
    authorization: str | None = None
    clear_authorization: bool = False
    user_agent: str | None = None
    timeout_seconds: int | None = Field(default=None, ge=3, le=60)
    rss_url: str | None = None
    clear_rss_url: bool = False
    request_headers: dict[str, str] = Field(default_factory=dict)
    clear_request_headers: bool = False

    @model_validator(mode="after")
    def normalize_urls(self) -> SiteSettingsUpdate:
        def clean(value: str | None) -> str | None:
            if not value:
                return None
            cleaned = value.strip().rstrip("/")
            return cleaned or None

        self.primary_url = clean(self.primary_url)
        self.active_base_url = clean(self.active_base_url)
        self.mirrors = sorted({url for item in self.mirrors if (url := clean(item))})
        if self.active_base_url and self.primary_url and self.active_base_url != self.primary_url and self.active_base_url not in self.mirrors:
            self.mirrors.append(self.active_base_url)
        self.api_key = self.api_key.strip() if self.api_key and self.api_key.strip() else None
        self.cookie = self.cookie.strip() if self.cookie and self.cookie.strip() else None
        self.passkey = self.passkey.strip() if self.passkey and self.passkey.strip() else None
        self.authorization = self.authorization.strip() if self.authorization and self.authorization.strip() else None
        self.user_agent = self.user_agent.strip() if self.user_agent and self.user_agent.strip() else None
        self.rss_url = clean(self.rss_url)
        self.request_headers = {
            str(key).strip(): str(value).strip()
            for key, value in (self.request_headers or {}).items()
            if str(key).strip() and str(value).strip()
        }
        return self


class SiteMirrorRequest(BaseModel):
    url: str


class SiteCreateRequest(BaseModel):
    site_id: str


class SiteDomainTestRequest(BaseModel):
    url: str | None = None


class SiteDomainTestResponse(BaseModel):
    ok: bool
    url: str
    status_code: int | None = None
    message: str
    rate_limit_events: list[str] = Field(default_factory=list)


class SearchRequest(BaseModel):
    keyword: str = Field(min_length=1)
    sites: list[str] = Field(default_factory=lambda: ["dmhy", "mikan", "nyaa"])
    channels: list[str] | None = None
    limit: int = Field(default=5000, ge=1, le=5000)
    page: int | None = Field(default=None, ge=1, le=100)
    page_size: int = Field(default=50, ge=1, le=100)
    max_pages: int | None = Field(default=None, ge=1, le=100)
    deduplicate: bool = True
    stop_when_no_new_results: bool = True
    timeout_seconds: float | None = Field(default=None, ge=3, le=60)
    include_diagnostics: bool = True

    @model_validator(mode="after")
    def normalize_channels(self) -> SearchRequest:
        if self.channels:
            self.sites = self.channels
        self.sites = sorted({normalize_site_id(site) for site in self.sites if site.strip()})
        if not self.sites:
            raise ValueError("请至少选择一个搜索站点。")
        return self


class SearchResult(BaseModel):
    id: str
    title: str
    subtitle: str | None = None
    description: str | None = None
    published_at: str | None = None
    size: str | None = None
    size_bytes: int | None = None
    category: str | None = None
    language: str | None = None
    is_free: bool | None = None
    discount_label: str | None = None
    free_until: str | None = None
    free_remaining: str | None = None
    seeders: int | None = None
    leechers: int | None = None
    downloads: int | None = None
    download_factor: float | None = None
    upload_factor: float | None = None
    hit_and_run: bool | None = None
    is_pinned: bool | None = None
    is_downloaded: bool | None = None
    download_url: str | None = None
    magnet_url: str | None = None
    source: str
    detail_url: str | None = None
    source_url: str | None = None
    mikan_episode_id: str | None = None
    mikan_bangumi_id: str | None = None
    mikan_group_id: str | None = None
    mikan_group_name: str | None = None
    bangumi_url: str | None = None
    bangumi_id: str | None = None
    page: int | None = None
    parsed_fansub: str | None = None
    parsed_episode: int | None = None
    parsed_episode_start: int | None = None
    parsed_episode_end: int | None = None
    parsed_resolution: str | None = None
    parsed_subtitle_language: str | None = None
    normalized_title: str | None = None
    parsed_is_batch: bool = False
    parsed_is_multi_episode: bool = False
    parsed_is_special: bool = False
    parsed_resource_type: str | None = None
    parsed_season_number: int | None = None
    parsed_part_number: int | None = None
    parsed_absolute_episode_number: int | None = None
    parsed_absolute_episode_start: str | None = None
    parsed_absolute_episode_end: str | None = None
    parsed_absolute_episode_start_sort: float | None = None
    parsed_absolute_episode_end_sort: float | None = None
    parsed_season_episode_start: int | None = None
    parsed_season_episode_end: int | None = None
    parsed_display_episode_label: str | None = None
    parsed_parse_reason: str | None = None


class SiteSearchDiagnostics(BaseModel):
    site: str
    pages_fetched: int = 0
    total_fetched: int = 0
    total_unique: int = 0
    stop_reason: str | None = None
    reached_max_pages: bool = False
    completed_all_accessible_pages: bool = True
    reached_internal_safety_limit: bool = False
    has_more: bool = False
    supports_pagination: bool = False
    warnings: list[str] = Field(default_factory=list)
    rate_limit_events: list[str] = Field(default_factory=list)
    error: str | None = None


class SearchDiagnostics(BaseModel):
    pages_fetched: int = 0
    total_fetched: int = 0
    total_unique: int = 0
    stop_reasons: list[str] = Field(default_factory=list)
    reached_max_pages: bool = False
    completed_all_accessible_pages: bool = True
    reached_internal_safety_limit: bool = False
    has_more: bool = False
    site_diagnostics: list[SiteSearchDiagnostics] = Field(default_factory=list)


class SearchSettings(BaseModel):
    site_timeout_seconds: float = Field(default=15, ge=3, le=60)


class SearchResponse(BaseModel):
    results: list[SearchResult] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    raw_count: int = 0
    display_count: int = 0
    deduplicated_count: int = 0
    pages_fetched: int = 0
    total_fetched: int = 0
    total_unique: int = 0
    reached_max_pages: bool = False
    completed_all_accessible_pages: bool = True
    reached_internal_safety_limit: bool = False
    has_more: bool = False
    diagnostics: SearchDiagnostics | None = None


class MikanProjectSettings(BaseModel):
    auto_refresh_enabled: bool = True
    refresh_interval_hours: int = Field(default=1, ge=1, le=168)


MikanProjectSectionKind = Literal[
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "movie",
    "ova",
    "unknown",
]


class MikanProjectAnime(BaseModel):
    bangumi_id: str
    title: str
    original_title: str | None = None
    synopsis: str | None = None
    poster_url: str | None = None
    poster_original_url: str | None = None
    poster_local_url: str | None = None
    poster_palette: PosterPalette | None = None
    detail_url: str | None = None
    update_date: str | None = None
    air_date: str | None = None
    broadcast_day: str | None = None
    broadcast_start: str | None = None
    total_episodes: int | None = None
    official_url: str | None = None
    bangumi_url: str | None = None
    bangumi_subject_id: str | None = None
    section: MikanProjectSectionKind
    subscribed: bool = False
    is_grayscale: bool = False
    status_text: str | None = None
    resource_count: int | None = None


class MikanProjectSection(BaseModel):
    id: MikanProjectSectionKind
    name: str
    short_name: str
    items: list[MikanProjectAnime] = Field(default_factory=list)


class MikanProjectSeasonResponse(BaseModel):
    cache_version: int
    season_title: str
    year: int
    season: str
    cached_at: datetime | None = None
    last_refresh_started_at: datetime | None = None
    settings: MikanProjectSettings
    sections: list[MikanProjectSection] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


class MikanProjectResourceGroup(BaseModel):
    fansub_id: str | None = None
    fansub: str
    resources: list[SearchResult] = Field(default_factory=list)


class MikanProjectResourcesResponse(BaseModel):
    anime: MikanProjectAnime | None = None
    groups: list[MikanProjectResourceGroup] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


class QbittorrentConfig(BaseModel):
    base_url: str = "http://127.0.0.1:8080"
    username: str = ""
    password: str = ""
    default_save_path: str | None = None
    default_category: str | None = "anime"
    default_tags: list[str] = Field(default_factory=lambda: ["kisetsu"])
    password_configured: bool = False
    clear_password: bool = False


class TransmissionConfig(BaseModel):
    base_url: str = "http://127.0.0.1:9091"
    username: str = ""
    password: str = ""
    default_save_path: str | None = None
    default_labels: list[str] = Field(default_factory=lambda: ["kisetsu"])
    password_configured: bool = False
    clear_password: bool = False


DownloaderType = Literal["qbittorrent", "transmission"]


class DownloaderRoutingSettings(BaseModel):
    subscription_downloader: DownloaderType = "qbittorrent"
    brush_downloader: DownloaderType = "qbittorrent"
    manual_downloader: DownloaderType = "qbittorrent"


class DownloaderStatus(BaseModel):
    downloader: DownloaderType
    configured: bool = False
    verified: bool = False
    stage: Literal["resolve", "connect", "authenticate", "session", "version", "api"] | None = None
    error_code: str | None = None
    version: str | None = None
    checked_at: datetime | None = None
    message: str = "未配置"


class DownloaderRoutingResponse(DownloaderRoutingSettings):
    statuses: list[DownloaderStatus] = Field(default_factory=list)


class QbittorrentGlobalLimits(BaseModel):
    download_limit: int = Field(default=0, ge=0)
    upload_limit: int = Field(default=0, ge=0)


class QbittorrentGlobalLimitsUpdate(BaseModel):
    download_limit: int = Field(ge=0, le=10_000_000_000)
    upload_limit: int = Field(ge=0, le=10_000_000_000)


class TransmissionGlobalLimits(QbittorrentGlobalLimits):
    pass


class TransmissionGlobalLimitsUpdate(QbittorrentGlobalLimitsUpdate):
    pass


class MetadataSettings(BaseModel):
    tmdb_api_key: str | None = None
    clear_tmdb_api_key: bool = False


class MetadataSettingsResponse(BaseModel):
    tmdb_configured: bool = False
    tmdb_api_key_configured: bool = False
    tmdb_api_key_masked: str | None = None
    message: str = "TMDB API Key 未配置"


class TMDBTestRequest(BaseModel):
    tmdb_api_key: str | None = None


class OrganizePolicySettings(BaseModel):
    auto_organize_by_default: bool = True
    post_organize_action: Literal[
        "keep_seeding",
        "remove_task_keep_files",
        "remove_task_delete_files",
        "manual",
    ] = "remove_task_keep_files"
    delete_task_after_organize: bool = True
    delete_files_after_organize: bool = False
    keep_seeding: bool = False
    seeding_stop_ratio: float | None = Field(default=None, ge=0)
    seeding_stop_minutes: int | None = Field(default=None, ge=0)
    seeding_stop_mode: Literal["any", "all"] = "any"
    post_seeding_action: Literal[
        "pause",
        "remove_task_keep_files",
        "remove_task_delete_files",
        "manual",
    ] = "pause"
    clean_empty_download_dirs: bool = True

    @model_validator(mode="before")
    @classmethod
    def normalize_post_organize_action(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        payload = dict(data)
        action = payload.get("post_organize_action")
        legacy_keys = {
            "delete_task_after_organize",
            "delete_files_after_organize",
            "keep_seeding",
        }

        def apply_action(selected: str) -> dict[str, bool]:
            if selected == "keep_seeding":
                return {
                    "delete_task_after_organize": False,
                    "delete_files_after_organize": False,
                    "keep_seeding": True,
                }
            if selected == "remove_task_keep_files":
                return {
                    "delete_task_after_organize": True,
                    "delete_files_after_organize": False,
                    "keep_seeding": False,
                }
            if selected == "remove_task_delete_files":
                return {
                    "delete_task_after_organize": True,
                    "delete_files_after_organize": True,
                    "keep_seeding": False,
                }
            if selected == "manual":
                return {
                    "delete_task_after_organize": False,
                    "delete_files_after_organize": False,
                    "keep_seeding": False,
                }
            raise ValueError("INVALID_ORGANIZE_POLICY：未知的整理后任务处理策略。")

        if action:
            expected = apply_action(str(action))
            for key, value in expected.items():
                if key in payload and bool(payload[key]) != value:
                    raise ValueError("INVALID_ORGANIZE_POLICY：整理后任务处理策略存在冲突，请只选择一种处理方式。")
                payload[key] = value
            return payload

        legacy_present = any(key in payload for key in legacy_keys)
        if not legacy_present:
            payload.update(apply_action("remove_task_keep_files"))
            payload["post_organize_action"] = "remove_task_keep_files"
            return payload

        keep = bool(payload.get("keep_seeding", False))
        delete_task = bool(payload.get("delete_task_after_organize", False))
        delete_files = bool(payload.get("delete_files_after_organize", False))
        if keep and (delete_task or delete_files):
            raise ValueError("INVALID_ORGANIZE_POLICY：保留做种不能同时删除 qBittorrent 任务或原下载文件。")
        if delete_files and not delete_task:
            raise ValueError("INVALID_ORGANIZE_POLICY：删除原下载文件必须依赖移除 qBittorrent 任务。")
        if keep:
            action = "keep_seeding"
        elif delete_task and delete_files:
            action = "remove_task_delete_files"
        elif delete_task:
            action = "remove_task_keep_files"
        else:
            action = "manual"
        payload.update(apply_action(action))
        payload["post_organize_action"] = action
        return payload


class AppSettingsResponse(BaseModel):
    metadata: MetadataSettingsResponse
    organize_policy: OrganizePolicySettings


class QbittorrentTestResponse(BaseModel):
    ok: bool
    downloader: DownloaderType | None = None
    stage: Literal["resolve", "connect", "authenticate", "session", "version", "api"] | None = None
    error_code: str | None = None
    version: str | None = None
    message: str


class TransmissionTestResponse(QbittorrentTestResponse):
    rpc_version: int | None = None


class DownloadRequest(BaseModel):
    result: SearchResult
    qbittorrent: QbittorrentConfig | None = None
    downloader_type: DownloaderType | None = None
    save_path: str | None = None
    organize_target_id: int | None = None
    category: str | None = None
    tags: list[str] = Field(default_factory=list)
    dry_run: bool = False


class DownloadResponse(BaseModel):
    ok: bool
    message: str
    history_id: int | None = None
    organize_target_id: int | None = None


class QbittorrentTaskProgress(BaseModel):
    download_record_id: int | None = None
    subscription_id: int | None = None
    episode_number: int | None = None
    matched: bool = False
    match_confidence: float | None = None
    match_reason: str | None = None
    hash: str | None = None
    name: str | None = None
    state: str | None = None
    state_label: str | None = None
    progress: float | None = None
    progress_percent: float | None = None
    downloaded: int | None = None
    total_size: int | None = None
    download_speed: int | None = None
    upload_speed: int | None = None
    eta: int | None = None
    ratio: float | None = None
    seeding_time: int | None = None
    num_seeds: int | None = None
    num_complete: int | None = None
    num_incomplete: int | None = None
    num_leechs: int | None = None
    last_seen_at: datetime | None = None
    seeding_stop_condition: str | None = None
    post_seeding_action: str | None = None
    seeding_target_seconds: int | None = None
    seeding_remaining_seconds: int | None = None
    seeding_target_ratio: float | None = None
    seeding_target_reached: bool | None = None
    seeding_stop_mode: Literal["any", "all"] | None = None
    message: str = "进度未知（需下载器连接正常）"


class DownloadHistoryManageRequest(BaseModel):
    action: Literal["pause", "resume", "delete", "delete_files", "readd"]


class DownloadHistoryManageResponse(BaseModel):
    ok: bool
    history_id: int
    action: str
    status: str
    message: str
    command_sent: bool = True
    task_found: bool = True
    before_state: str | None = None
    after_state: str | None = None
    needs_refresh: bool = False


class DownloadHistoryDeleteResponse(BaseModel):
    ok: bool
    history_id: int
    message: str


class HistoryClearRequest(BaseModel):
    scope: Literal["download", "all"] = "download"
    subscription_id: int | None = None
    delete_qbittorrent_tasks: bool = False
    delete_files: bool = False
    confirm: bool = False


class HistoryClearResponse(BaseModel):
    ok: bool
    scope: str
    message: str
    download_history_deleted: int = 0
    subscription_matches_deleted: int = 0
    subscription_refreshes_deleted: int = 0
    organize_previews_deleted: int = 0
    organize_history_deleted: int = 0
    metadata_bindings_deleted: int = 0
    qbittorrent_tasks_deleted: int = 0
    warnings: list[str] = Field(default_factory=list)


class OrganizeHistoryClearRequest(BaseModel):
    confirm: bool = False


class OrganizeFailedHistoryDeleteRequest(BaseModel):
    confirm: bool = False
    subscription_id: int | None = None


class OrganizeFailedHistorySummary(BaseModel):
    subscription_id: int | None = None
    failed_count: int = 0


class OrganizeFailedHistoryDeleteResponse(BaseModel):
    ok: bool = True
    deleted_count: int = 0
    scope: str
    message: str


class OrganizeTargetCreate(BaseModel):
    name: str = Field(min_length=1)
    path: str = Field(min_length=1)
    media_type: str = "anime"
    is_default: bool = False
    enabled: bool = True


class OrganizeTargetUpdate(OrganizeTargetCreate):
    pass


class OrganizeTarget(OrganizeTargetCreate):
    id: int
    created_at: datetime
    updated_at: datetime | None = None


class OrganizeTargetPreview(BaseModel):
    target_name: str | None = None
    root_path: str | None = None
    show_directory: str | None = None
    season_directory: str | None = None
    show_path: str | None = None
    season_path: str | None = None
    message: str | None = None


class OrganizeTargetValidateResponse(BaseModel):
    ok: bool
    target_id: int
    message: str
    path_exists: bool
    is_directory: bool
    is_absolute: bool


class ResetSubscriptionRequest(BaseModel):
    confirm: bool = False


class SubscriptionHistoryClearRequest(BaseModel):
    scope: Literal["refresh", "download", "all"] = "refresh"
    confirm: bool = False


class ResetSubscriptionResponse(BaseModel):
    ok: bool
    subscription_id: int
    message: str
    download_history_deleted: int = 0
    subscription_matches_deleted: int = 0
    subscription_refreshes_deleted: int = 0
    organize_previews_deleted: int = 0
    organize_history_deleted: int = 0
    metadata_bindings_deleted: int = 0
    plex_mappings_deleted: int = 0
    poster_cache_deleted: int = 0


class SubscriptionDownloadRequest(BaseModel):
    match_ids: list[int] = Field(default_factory=list)
    all_matches: bool = False
    dry_run: bool = False


class SubscriptionDownloadResponse(BaseModel):
    subscription_id: int
    ok: bool
    message: str
    submitted: list[SearchResult] = Field(default_factory=list)
    skipped: list[SearchResult] = Field(default_factory=list)
    history_ids: list[int] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


class EpisodeParseRule(BaseModel):
    id: str
    name: str = Field(min_length=1)
    pattern: str = Field(min_length=1)
    enabled: bool = True
    priority: int = 0
    episode_group: str = "episode"
    start_group: str = "start"
    end_group: str = "end"
    final_group: str = "final"
    rule_type: Literal["builtin", "user"] = "user"
    mode: Literal["visual", "regex"] = "regex"
    sample_title: str | None = None
    example_title: str | None = None
    description: str | None = None
    visual_marks: list[EpisodeRuleVisualMark] = Field(default_factory=list)
    generated_pattern: str | None = None


class EpisodeRuleVisualMark(BaseModel):
    token_id: int
    token_text: str
    mark_type: Literal["episode", "start", "end", "final"]
    start_index: int
    end_index: int
    split_group_id: str | None = None


class EpisodeTitleToken(BaseModel):
    id: int
    text: str
    start_index: int
    end_index: int
    kind: Literal["text", "number", "separator", "final", "resolution", "bracket", "symbol"]
    split_group_id: str | None = None
    is_split: bool = False


class EpisodeRuleTokenizeRequest(BaseModel):
    title: str


class EpisodeRuleTokenizeResponse(BaseModel):
    title: str
    tokens: list[EpisodeTitleToken] = Field(default_factory=list)


class EpisodeRulePreviewRequest(BaseModel):
    title: str
    marks: list[EpisodeRuleVisualMark] = Field(default_factory=list)
    name: str | None = None


class EpisodeRulePreviewResponse(BaseModel):
    ok: bool
    message: str
    rule: EpisodeParseRule | None = None
    parsed_title: ParsedAnimeTitle | None = None
    tokens: list[EpisodeTitleToken] = Field(default_factory=list)
    suggestions: list[str] = Field(default_factory=list)
    generated_pattern: str | None = None
    confidence: float = 0
    explanation: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    marked_tokens: list[EpisodeRuleVisualMark] = Field(default_factory=list)
    positive_tests: list[str] = Field(default_factory=list)
    negative_tests: list[str] = Field(default_factory=list)


class EpisodeRuleSettingsResponse(BaseModel):
    builtin_rules: list[EpisodeParseRule] = Field(default_factory=list)
    user_rules: list[EpisodeParseRule] = Field(default_factory=list)


class EpisodeRuleSettingsUpdate(BaseModel):
    user_rules: list[EpisodeParseRule] = Field(default_factory=list)


class SubscriptionCreate(BaseModel):
    name: str = Field(min_length=1)
    keyword: str = Field(min_length=1)
    source_type: Literal["keyword", "mikan_bangumi", "rss"] = "keyword"
    identity_key: str | None = None
    sites: list[str] = Field(default_factory=lambda: ["dmhy", "mikan", "nyaa"])
    source_url: str | None = None
    mikan_bangumi_url: str | None = None
    aliases: list[str] = Field(default_factory=list)
    rss_urls: list[str] = Field(default_factory=list)
    regex: str | None = None
    regex_enabled: bool = False
    episode_filter: str | None = None
    include_keywords: list[str] = Field(default_factory=list)
    exclude_keywords: list[str] = Field(default_factory=list)
    filter_order: Literal["include_first", "exclude_first"] = "include_first"
    fansub: str | None = None
    resolution: str | None = None
    resolution_mode: Literal["any", "preset", "custom"] = "any"
    resolution_preset: str | None = None
    resolution_custom: str | None = None
    min_size_bytes: int | None = Field(default=None, gt=0)
    max_size_bytes: int | None = Field(default=None, gt=0)
    season: int | None = Field(default=None, ge=0)
    episode: int | None = Field(default=None, ge=1)
    episode_start: int = Field(default=1, ge=1)
    episode_offset: int = 0
    batch_resource_policy: Literal["ignore", "show_only", "allow_auto_download"] = "show_only"
    episode_parse_rules: list[EpisodeParseRule] = Field(default_factory=list)
    total_episodes: int | None = Field(default=None, ge=1)
    total_episodes_source: Literal["manual", "bangumi", "tmdb", "mikan", "unknown"] | None = None
    metadata_episode_count: int | None = Field(default=None, ge=1)
    enabled: bool = True
    auto_download: bool = True
    organize_target_id: int | None = None
    auto_organize: bool = False
    post_organize_action: Literal[
        "keep_seeding",
        "remove_task_keep_files",
        "remove_task_delete_files",
        "manual",
    ] | None = None
    delete_task_after_organize: bool | None = None
    delete_files_after_organize: bool | None = None
    keep_seeding: bool | None = None
    seeding_policy_mode: Literal["inherit", "custom"] = "inherit"
    seeding_stop_ratio: float | None = Field(default=None, gt=0)
    seeding_stop_minutes: int | None = Field(default=None, gt=0)
    seeding_stop_mode: Literal["any", "all"] = "any"
    post_seeding_action: Literal[
        "pause",
        "remove_task_keep_files",
        "remove_task_delete_files",
        "manual",
    ] = "pause"
    save_path: str | None = None
    category: str | None = "anime"
    tags: list[str] = Field(default_factory=lambda: ["kisetsu"])

    @field_validator("include_keywords", "exclude_keywords", mode="before")
    @classmethod
    def normalize_keyword_expressions(cls, value: Any) -> Any:
        if value is None:
            return []
        if not isinstance(value, (list, tuple)):
            return value
        try:
            return normalize_keyword_expression_items(value)
        except KeywordExpressionError as exc:
            raise ValueError(str(exc)) from exc

    @field_validator("episode_start", mode="before")
    @classmethod
    def normalize_episode_start(cls, value: Any) -> Any:
        if value is None or value == "":
            return 1
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return value
        if parsed < 1:
            raise ValueError("起始集数必须大于等于 1")
        return parsed

    @model_validator(mode="after")
    def normalize_sites_and_resolution(self) -> SubscriptionCreate:
        self.sites = sorted({normalize_site_id(site) for site in self.sites if site.strip()})
        if "source_type" not in self.model_fields_set:
            if self.rss_urls:
                self.source_type = "rss"
            elif self.mikan_bangumi_url or self.source_url:
                self.source_type = "mikan_bangumi"
            elif re.search(r"^https?://", self.keyword, flags=re.I) and re.search(r"(rss|feed|xml)", self.keyword, flags=re.I):
                self.source_type = "rss"
                self.rss_urls = [self.keyword]
            elif re.search(r"mikanani\.me/.*/Bangumi/\d+|/Home/Bangumi/\d+", self.keyword, flags=re.I):
                self.source_type = "mikan_bangumi"
                self.mikan_bangumi_url = self.keyword
                self.source_url = self.keyword
        if self.source_type == "mikan_bangumi" and "mikan" not in self.sites:
            self.sites = sorted({*self.sites, "mikan"})
        legacy_resolution = (self.resolution or "").strip()
        custom_resolution = (self.resolution_custom or "").strip()
        preset_resolution = (self.resolution_preset or "").strip()
        if self.resolution_mode == "any":
            if custom_resolution:
                self.resolution_mode = "custom"
            elif preset_resolution:
                self.resolution_mode = "preset"
            elif legacy_resolution:
                if legacy_resolution.casefold() in RESOLUTION_PRESETS:
                    self.resolution_mode = "preset"
                    preset_resolution = legacy_resolution
                else:
                    self.resolution_mode = "custom"
                    custom_resolution = legacy_resolution
        if self.resolution_mode == "preset":
            preset_resolution = preset_resolution or legacy_resolution
            self.resolution_preset = preset_resolution or None
            self.resolution_custom = None
            self.resolution = self.resolution_preset
        elif self.resolution_mode == "custom":
            custom_resolution = custom_resolution or legacy_resolution
            if not custom_resolution:
                self.resolution_mode = "any"
                self.resolution = None
                self.resolution_preset = None
                self.resolution_custom = None
            else:
                self.resolution_custom = custom_resolution
                self.resolution_preset = None
                self.resolution = custom_resolution
        else:
            self.resolution = None
            self.resolution_preset = None
            self.resolution_custom = None
        if "seeding_policy_mode" not in self.model_fields_set and (
            self.seeding_stop_ratio is not None or self.seeding_stop_minutes is not None
        ):
            self.seeding_policy_mode = "custom"
        if self.post_organize_action == "keep_seeding" and self.seeding_policy_mode == "custom":
            if self.seeding_stop_ratio is None and self.seeding_stop_minutes is None:
                raise ValueError("订阅自定义做种规则至少需要启用做种时间或分享率目标。")
        if self.min_size_bytes is not None and self.max_size_bytes is not None:
            if self.min_size_bytes > self.max_size_bytes:
                raise ValueError("最小视频体积不能大于最大视频体积。")
        return self


class Subscription(SubscriptionCreate):
    id: int
    created_at: datetime
    updated_at: datetime | None = None


class SubscriptionSuggestionRequest(BaseModel):
    result: SearchResult
    sites: list[str] = Field(default_factory=list)
    organize_target_id: int | None = None
    save_path: str | None = None
    category: str | None = "anime"
    tags: list[str] = Field(default_factory=lambda: ["kisetsu"])


class SubscriptionSuggestionResponse(BaseModel):
    ok: bool
    message: str
    parsed_title: ParsedAnimeTitle
    suggestion: SubscriptionCreate | None = None
    confidence: float = 0.0
    warnings: list[str] = Field(default_factory=list)
    duplicate_subscription_id: int | None = None
    duplicate_subscription_name: str | None = None


class MatchDiagnosticSample(BaseModel):
    title: str
    source: str
    reason: str
    parsed_fansub: str | None = None
    site_fansub_id: str | None = None
    site_fansub: str | None = None
    parsed_resolution: str | None = None
    parsed_episode: int | None = None
    parsed_episode_start: int | None = None
    parsed_episode_end: int | None = None
    resource_type: str | None = None
    display_episode_label: str | None = None
    is_batch: bool = False
    is_multi_episode: bool = False
    absolute_episode_start: str | None = None
    absolute_episode_end: str | None = None
    season_episode_start: int | None = None
    season_episode_end: int | None = None
    is_final: bool = False
    parse_rule_name: str | None = None
    parse_failure_reason: str | None = None
    explicit_season_number: int | None = None
    inferred_season_number: int | None = None
    context_season_number: int | None = None
    effective_season_number: int | None = None
    season_source: str = "unknown"
    season_conflict: bool = False
    season_conflict_reason: str | None = None
    title_match_source: Literal["title", "subtitle", "metadata", "unknown"] = "unknown"
    episode_parse_source: Literal["title", "subtitle", "unknown"] = "unknown"
    season_parse_source: Literal["title", "subtitle", "unknown"] = "unknown"
    fansub_parse_source: Literal["title", "subtitle", "unknown"] = "unknown"
    resolution_parse_source: Literal["title", "subtitle", "unknown"] = "unknown"
    parse_conflict_reason: str | None = None


class MatchDiagnostics(BaseModel):
    total_fetched: int = 0
    total_unique: int = 0
    pages_fetched: int = 0
    stop_reasons: list[str] = Field(default_factory=list)
    reached_max_pages: bool = False
    completed_all_accessible_pages: bool = True
    reached_internal_safety_limit: bool = False
    has_more: bool = False
    matched_count: int = 0
    matched_by_subtitle: int = 0
    episode_parsed_from_subtitle: int = 0
    excluded_by_title: int = 0
    excluded_by_fansub: int = 0
    excluded_by_include: int = 0
    excluded_by_exclude: int = 0
    excluded_by_resolution: int = 0
    excluded_by_size: int = 0
    excluded_by_regex: int = 0
    excluded_by_episode_filter: int = 0
    excluded_by_batch_policy: int = 0
    excluded_by_episode_coverage: int = 0
    season_matched_count: int = 0
    excluded_by_season_mismatch: int = 0
    excluded_by_metadata_mismatch: int = 0
    excluded_by_bangumi_id_mismatch: int = 0
    duplicate_count: int = 0
    parse_failed_count: int = 0
    search_diagnostics: SearchDiagnostics | None = None
    sample_excluded_items: list[MatchDiagnosticSample] = Field(default_factory=list)


class SubscriptionTestMatchRequest(SubscriptionCreate):
    limit: int = Field(default=30, ge=1, le=100)


class SubscriptionTestMatchResponse(BaseModel):
    ok: bool
    message: str
    matched: list[SearchResult] = Field(default_factory=list)
    matched_samples: list[MatchDiagnosticSample] = Field(default_factory=list)
    excluded: list[MatchDiagnosticSample] = Field(default_factory=list)
    diagnostics: MatchDiagnostics = Field(default_factory=MatchDiagnostics)
    warnings: list[str] = Field(default_factory=list)


class RssTestRequest(BaseModel):
    url: str | None = None
    site: str = "dmhy"
    site_settings: SiteSettingsUpdate | None = None
    keyword: str | None = None
    category: str | None = None
    limit: int = Field(default=100, ge=1, le=500)
    page: int = Field(default=1, ge=1, le=1000)
    page_size: int = Field(default=25, ge=1, le=100)

    @model_validator(mode="after")
    def normalize_site(self) -> RssTestRequest:
        self.site = normalize_site_id(self.site)
        self.keyword = self.keyword.strip() if self.keyword and self.keyword.strip() else None
        self.category = self.category.strip() if self.category and self.category.strip() else None
        return self


class RssTestResponse(BaseModel):
    ok: bool
    message: str
    site: str
    url: str | None = None
    count: int = 0
    page: int = 1
    page_size: int = 25
    total_pages: int = 0
    has_previous: bool = False
    has_next: bool = False
    elapsed_ms: int | None = None
    categories: list[str] = Field(default_factory=list)
    results: list[SearchResult] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    diagnostics: SearchDiagnostics = Field(default_factory=SearchDiagnostics)


class RefreshResponse(BaseModel):
    subscription_id: int
    refresh_history_id: int | None = None
    matched: list[SearchResult] = Field(default_factory=list)
    added: list[SearchResult] = Field(default_factory=list)
    skipped: list[SearchResult] = Field(default_factory=list)
    pending: list[SearchResult] = Field(default_factory=list)
    match_records: list[SubscriptionMatch] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    diagnostics: MatchDiagnostics = Field(default_factory=MatchDiagnostics)


class RefreshAllResponse(BaseModel):
    refreshed: int
    responses: list[RefreshResponse] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    skipped: int = 0


class SchedulerStartRequest(BaseModel):
    interval_seconds: int = Field(default=1800, ge=1, le=86400)


class AutomationIntervalRequest(BaseModel):
    model_config = {"extra": "forbid"}
    interval_seconds: int = Field(ge=1, le=86400, strict=True)


class SchedulerStatus(BaseModel):
    running: bool
    interval_seconds: int
    last_run_at: str | None = None
    last_error: str | None = None
    next_run_at: str | None = None
    last_success_at: str | None = None
    last_error_at: str | None = None
    last_error_message: str | None = None
    current_job_id: str | None = None


class AutomationSettingsRequest(BaseModel):
    auto_refresh_enabled: bool = False
    auto_refresh_interval_seconds: int = Field(default=1800, ge=1, le=86400)
    auto_download_enabled: bool = True
    auto_organize_enabled: bool = True
    notifications_enabled: bool = True


class AutomationStatus(BaseModel):
    backend_running: bool = True
    scheduler_running: bool = False
    auto_refresh_enabled: bool = False
    auto_refresh_interval_seconds: int = 1800
    auto_download_enabled: bool = True
    auto_organize_enabled: bool = True
    notifications_enabled: bool = True
    last_run_at: str | None = None
    next_run_at: str | None = None
    last_success_at: str | None = None
    last_error_at: str | None = None
    last_error_message: str | None = None
    current_job_id: str | None = None
    current_job: dict[str, Any] | None = None
    message: str = "已停止"


class AutomationJobRecord(BaseModel):
    job_id: str
    started_at: str
    finished_at: str | None = None
    status: Literal["running", "success", "error", "skipped"] = "running"
    refreshed_count: int = 0
    matched_count: int = 0
    downloaded_count: int = 0
    organized_count: int = 0
    notified_count: int = 0
    error_count: int = 0
    error_message: str | None = None


class AutomationRunNowResponse(BaseModel):
    ok: bool
    message: str
    status: AutomationStatus
    job: AutomationJobRecord | None = None


class DownloadHistory(BaseModel):
    id: int
    fingerprint: str
    title: str
    source: str
    download_url: str | None = None
    qbittorrent_hash: str | None = None
    downloader_type: DownloaderType = "qbittorrent"
    remote_task_id: str | None = None
    torrent_name: str | None = None
    save_path: str | None = None
    subscription_id: int | None = None
    status: str
    organize_status: str = "未整理"
    task_status: str = "未知"
    derived_status: str = "未知"
    derived_status_detail: str | None = None
    organize_available: bool = False
    organize_block_reason: str | None = None
    created_at: datetime
    qbittorrent: QbittorrentTaskProgress | None = None


class SubscriptionRefreshHistory(BaseModel):
    id: int
    subscription_id: int
    matched_count: int = 0
    added_count: int = 0
    skipped_count: int = 0
    error_count: int = 0
    warnings: list[str] = Field(default_factory=list)
    logs: list[str] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)
    summary: str | None = None
    created_at: datetime


class SubscriptionEpisodeStatus(BaseModel):
    match_id: int
    download_history_id: int | None = None
    title: str
    source: str
    episode: int | None = None
    season: int | None = None
    resolution: str | None = None
    match_status: str
    download_status: str
    completion_status: str = "未知（暂未检测）"
    qbittorrent: QbittorrentTaskProgress | None = None
    organize_preview_status: str = "未知"
    derived_status: str = "未匹配资源"
    derived_status_detail: str | None = None
    last_seen_at: datetime


class SubscriptionEpisodeResource(BaseModel):
    match_id: int
    raw_title: str
    site: str
    fansub_group: str | None = None
    resolution: str | None = None
    size: str | None = None
    publish_time: str | None = None
    download_link: str | None = None
    magnet: str | None = None
    torrent_hash: str | None = None
    download_record_id: int | None = None
    match_score: float | None = None
    status: str
    download_status: str
    organize_status: str
    qbittorrent: QbittorrentTaskProgress | None = None
    derived_status: str = "已匹配，未下载"
    derived_status_detail: str | None = None
    resource_type: str = "unknown"
    display_episode_label: str | None = None
    episode_start: int | None = None
    episode_end: int | None = None
    absolute_episode_start: str | None = None
    absolute_episode_end: str | None = None
    season_episode_start: int | None = None
    season_episode_end: int | None = None
    logical_episode_start: int | None = None
    logical_episode_end: int | None = None
    episode_offset_applied: int = 0
    episode_mapping_label: str | None = None
    is_batch: bool = False
    is_multi_episode: bool = False


class SubscriptionLogicalEpisodeStatus(BaseModel):
    season_number: int
    episode_number: int
    episode_title: str | None = None
    display_title: str
    metadata_source: str = "local"
    matched_resources: list[SubscriptionEpisodeResource] = Field(default_factory=list)
    download_status: str = "未匹配资源"
    organize_status: str = "未知"
    auto_organize_status: str = "未开启"
    derived_status: str = "未匹配资源"
    derived_status_detail: str | None = None
    organize_available: bool = False
    excluded_by_episode_start: bool = False
    selected: bool = False
    last_matched_at: datetime | None = None


class SubscriptionHierarchyEpisode(BaseModel):
    match_id: int
    download_history_id: int | None = None
    title: str
    source: str
    episode_number: int | None = None
    resolution: str | None = None
    download_status: str
    qbittorrent: QbittorrentTaskProgress | None = None
    organize_status: str
    derived_status: str = "未匹配资源"
    derived_status_detail: str | None = None
    downloaded: bool = False
    organized: bool = False


class SubscriptionHierarchySeason(BaseModel):
    season_number: int
    title: str
    episodes: list[SubscriptionHierarchyEpisode] = Field(default_factory=list)


class PosterPalette(BaseModel):
    primary: str
    secondary: str
    accent: str
    background: str
    text_contrast: Literal["light", "dark"] = "dark"


class SubscriptionMetadataHierarchy(BaseModel):
    source: Literal["bangumi", "tmdb", "local"]
    source_label: str
    external_id: str | None = None
    title: str
    original_title: str | None = None
    chinese_title: str | None = None
    aliases: list[str] = Field(default_factory=list)
    subtitle: str | None = None
    summary: str | None = None
    poster_url: str | None = None
    backdrop_url: str | None = None
    poster_local_url: str | None = None
    poster_palette: PosterPalette | None = None
    air_date: str | None = None
    total_episodes: int | None = None
    episode_titles: dict[str, str] = Field(default_factory=dict)
    rating: float | None = None
    tags: list[str] = Field(default_factory=list)
    season_number: int | None = None
    episode_count: int | None = None
    external_ids: dict[str, str] = Field(default_factory=dict)
    seasons: list[SubscriptionHierarchySeason] = Field(default_factory=list)


class SubscriptionCoverageSummary(BaseModel):
    total_episodes: int = 0
    catalog_total_episodes: int | None = None
    target_total_episodes: int | None = None
    skipped_before_start: int = 0
    downloaded_count: int = 0
    organized_count: int = 0
    downloaded_ranges: list[str] = Field(default_factory=list)
    organized_ranges: list[str] = Field(default_factory=list)
    has_batch_download: bool = False
    has_batch_organized: bool = False
    batch_status_label: str | None = None


class SubscriptionDetail(BaseModel):
    subscription: Subscription
    organize_target: OrganizeTarget | None = None
    organize_target_preview: OrganizeTargetPreview | None = None
    matches: list[SubscriptionMatch] = Field(default_factory=list)
    history: list[DownloadHistory] = Field(default_factory=list)
    refresh_history: list[SubscriptionRefreshHistory] = Field(default_factory=list)
    metadata_bindings: list[MetadataBindingRecord] = Field(default_factory=list)
    metadata_hierarchy: list[SubscriptionMetadataHierarchy] = Field(default_factory=list)
    plex_mappings: list[PlexMappingRecord] = Field(default_factory=list)
    episodes: list[SubscriptionEpisodeStatus] = Field(default_factory=list)
    episode_statuses: list[SubscriptionLogicalEpisodeStatus] = Field(default_factory=list)
    unmatched_resources: list[SubscriptionEpisodeResource] = Field(default_factory=list)
    auto_organize_status: str = "未开启"
    matched_count: int = 0
    queued_count: int = 0
    skipped_count: int = 0
    error_count: int = 0
    latest_refresh_at: datetime | None = None
    latest_refresh_summary: str | None = None
    latest_organized_at: datetime | None = None
    latest_error: str | None = None
    coverage: SubscriptionCoverageSummary | None = None


class SubscriptionListItem(Subscription):
    matched_count: int = 0
    queued_count: int = 0
    skipped_count: int = 0
    error_count: int = 0
    episode_count: int = 0
    downloaded_count: int = 0
    organized_count: int = 0
    latest_refresh_at: datetime | None = None
    latest_refresh_summary: str | None = None
    latest_organized_at: datetime | None = None
    latest_error: str | None = None
    metadata_binding_count: int = 0
    metadata_titles: list[str] = Field(default_factory=list)
    poster_url: str | None = None
    poster_local_url: str | None = None
    poster_palette: PosterPalette | None = None
    summary: str | None = None
    coverage: SubscriptionCoverageSummary | None = None


class OverviewActionTarget(BaseModel):
    target_type: Literal["download_history", "subscription", "organize_history", "organize_preview", "organize_preview_record", "search", "settings", "none"]
    target_id: int | str | None = None
    subscription_id: int | None = None
    action: Literal["open", "organize", "download", "refresh", "review", "none"] = "open"


class OverviewItem(BaseModel):
    id: str
    title: str
    subtitle: str | None = None
    detail: str | None = None
    status: str | None = None
    severity: Literal["info", "success", "warning", "error"] = "info"
    system_image: str | None = None
    created_at: datetime | None = None
    target: OverviewActionTarget


class OverviewSubscriptionSummary(BaseModel):
    total: int = 0
    enabled: int = 0
    refreshing: int = 0
    failed: int = 0
    latest_refresh_summary: str | None = None
    latest_error: str | None = None


class OverviewOrganizedMedia(BaseModel):
    id: str
    subscription_id: int | None = None
    history_id: int
    title: str
    media_type: str
    episodes: list[int] = Field(default_factory=list)
    season: int | None = None
    completed_at: datetime


class OverviewRuntimeItem(BaseModel):
    id: str
    title: str
    detail: str
    state: Literal["configured", "success", "failed", "unknown", "running", "stopped"]
    checked_at: str | None = None
    next_at: str | None = None


class OverviewSubscription(Subscription):
    poster_url: str | None = None
    poster_local_url: str | None = None
    poster_palette: PosterPalette | None = None
    episode_count: int = 0
    downloaded_count: int = 0
    organized_count: int = 0
    latest_refresh_at: datetime | None = None
    latest_organized_at: datetime | None = None
    summary: str | None = None
    coverage: SubscriptionCoverageSummary | None = None


class OverviewResponse(BaseModel):
    downloading_items: list[OverviewItem] = Field(default_factory=list)
    pending_organize_items: list[OverviewItem] = Field(default_factory=list)
    issues: list[OverviewItem] = Field(default_factory=list)
    recent_completed: list[OverviewItem] = Field(default_factory=list)
    subscription_summary: OverviewSubscriptionSummary = Field(default_factory=OverviewSubscriptionSummary)
    downloading_count: int = 0
    pending_organize_count: int = 0
    issues_count: int = 0
    recent_completed_count: int = 0
    generated_at: datetime | None = None
    recently_organized: list[OverviewOrganizedMedia] = Field(default_factory=list)
    runtime_items: list[OverviewRuntimeItem] = Field(default_factory=list)
    subscription_items: list[OverviewSubscription] = Field(default_factory=list)


class MetadataSearchRequest(BaseModel):
    query: str = Field(min_length=1)
    year: int | None = None
    media_type: Literal["tv", "anime", "movie"] = "anime"
    sources: list[Literal["bangumi", "tmdb"]] = Field(default_factory=lambda: ["bangumi", "tmdb"])


class MetadataCandidate(BaseModel):
    source: Literal["bangumi", "tmdb"]
    external_id: str
    title: str
    media_type: Literal["tv", "anime", "movie"] | None = None
    original_title: str | None = None
    chinese_title: str | None = None
    aliases: list[str] = Field(default_factory=list)
    summary: str | None = None
    poster_url: str | None = None
    backdrop_url: str | None = None
    air_date: str | None = None
    total_episodes: int | None = None
    episode_titles: dict[str, str] = Field(default_factory=dict)
    rating: float | None = None
    tags: list[str] = Field(default_factory=list)
    season_number: int | None = None
    episode_count: int | None = None
    external_ids: dict[str, str] = Field(default_factory=dict)
    match_score: float | None = None
    match_reason: list[str] = Field(default_factory=list)
    raw: dict[str, Any] = Field(default_factory=dict)


class MetadataSearchResponse(BaseModel):
    candidates: list[MetadataCandidate] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    parsed_title: ParsedAnimeTitle | None = None
    recommended_candidate_id: str | None = None
    suggested_mapping: PlexSeasonMapping | None = None
    merge_summary: str | None = None


class MetadataMatchRequest(BaseModel):
    title: str
    year: int | None = None
    download_record_id: int | None = None
    media_type: Literal["tv", "anime", "movie"] = "anime"


class MetadataBindRequest(BaseModel):
    target_type: Literal["subscription", "resource"]
    target_id: str
    bangumi_id: str | None = None
    tmdb_id: str | None = None
    media_type: Literal["tv", "anime", "movie"] | None = None
    selected_title: str | None = None
    original_title: str | None = None
    chinese_title: str | None = None
    aliases: list[str] = Field(default_factory=list)
    summary: str | None = None
    poster_url: str | None = None
    backdrop_url: str | None = None
    poster_local_url: str | None = None
    local_poster_path: str | None = None
    air_date: str | None = None
    total_episodes: int | None = None
    episode_titles: dict[str, str] = Field(default_factory=dict)
    rating: float | None = None
    tags: list[str] = Field(default_factory=list)
    season_number: int | None = None
    episode_count: int | None = None
    external_ids: dict[str, str] = Field(default_factory=dict)
    notes: str | None = None


class MetadataBindResponse(BaseModel):
    ok: bool
    binding_id: int


class MetadataBindingRecord(BaseModel):
    id: int
    target_type: Literal["subscription", "resource"]
    target_id: str
    media_type: Literal["tv", "anime", "movie"] | None = None
    bangumi_id: str | None = None
    tmdb_id: str | None = None
    selected_title: str | None = None
    original_title: str | None = None
    chinese_title: str | None = None
    aliases: list[str] = Field(default_factory=list)
    summary: str | None = None
    poster_url: str | None = None
    backdrop_url: str | None = None
    poster_local_url: str | None = None
    local_poster_path: str | None = None
    poster_cached_at: datetime | None = None
    poster_palette: PosterPalette | None = None
    air_date: str | None = None
    total_episodes: int | None = None
    episode_titles: dict[str, str] = Field(default_factory=dict)
    rating: float | None = None
    tags: list[str] = Field(default_factory=list)
    season_number: int | None = None
    episode_count: int | None = None
    external_ids: dict[str, str] = Field(default_factory=dict)
    notes: str | None = None
    created_at: datetime


class TitleParseRequest(BaseModel):
    title: str
    episode_parse_rules: list[EpisodeParseRule] = Field(default_factory=list)


class EpisodeRuleTestCase(BaseModel):
    title: str
    expected_match: bool = True


class EpisodeRuleTestItem(BaseModel):
    title: str
    expected_match: bool
    matched: bool
    passed: bool
    parsed_title: ParsedAnimeTitle
    message: str


class EpisodeRuleTestRequest(BaseModel):
    title: str
    episode_parse_rules: list[EpisodeParseRule] = Field(default_factory=list)
    tests: list[EpisodeRuleTestCase] = Field(default_factory=list)


class EpisodeRuleTestResponse(BaseModel):
    ok: bool = True
    parsed_title: ParsedAnimeTitle
    message: str
    results: list[EpisodeRuleTestItem] = Field(default_factory=list)


AIProviderName = Literal["none", "openai_compatible", "xai", "deepseek"]


class AIProviderProfile(BaseModel):
    base_url: str | None = None
    model: str | None = None
    api_key: str | None = None


class AIProviderProfileResponse(BaseModel):
    base_url: str | None = None
    model: str | None = None
    api_key_configured: bool = False
    api_key_masked: str | None = None


class AISettings(BaseModel):
    enabled: bool = False
    provider: AIProviderName = "none"
    base_url: str | None = None
    model: str | None = None
    api_key: str | None = None
    use_ai_for_smart_subscription: bool = False
    clear_api_key: bool = False
    provider_profiles: dict[str, AIProviderProfile] = Field(default_factory=dict)


class AISettingsResponse(BaseModel):
    enabled: bool = False
    provider: AIProviderName = "none"
    base_url: str | None = None
    model: str | None = None
    api_key_configured: bool = False
    api_key_masked: str | None = None
    use_ai_for_smart_subscription: bool = False
    configured: bool = False
    message: str = "未配置 AI，可在 设置 → AI 辅助分析 中配置"
    provider_profiles: dict[str, AIProviderProfileResponse] = Field(default_factory=dict)


class AISettingsTestRequest(BaseModel):
    enabled: bool = False
    provider: AIProviderName = "none"
    base_url: str | None = None
    model: str | None = None
    api_key: str | None = None


class AIModelListRequest(BaseModel):
    provider: AIProviderName = "none"
    base_url: str | None = None
    api_key: str | None = None
    selected_model: str | None = None


class AIModelInfo(BaseModel):
    id: str
    name: str | None = None
    owned_by: str | None = None
    created: int | None = None


class AIModelListResponse(BaseModel):
    ok: bool = True
    models: list[AIModelInfo] = Field(default_factory=list)
    selected_model: str | None = None
    message: str
    error_code: str | None = None


class AITitleAnalyzeRequest(BaseModel):
    title: str
    subscription_name: str | None = None
    aliases: list[str] = Field(default_factory=list)
    site: str | None = None
    local_parse: ParsedAnimeTitle | None = None


class AITitleAnalysisResponse(BaseModel):
    ok: bool = False
    message: str = "未配置 AI，可在 设置 → AI 辅助分析 中配置"
    raw_title: str | None = None
    fansub: str | None = None
    anime_title: str | None = None
    anime_title_original: str | None = None
    anime_title_aliases: list[str] = Field(default_factory=list)
    episode_number: int | None = None
    episode_start: int | None = None
    episode_end: int | None = None
    is_batch: bool = False
    is_final: bool | None = None
    final_confidence: float = 0.0
    resolution: str | None = None
    subtitle_language: str | None = None
    source_tags: list[str] = Field(default_factory=list)
    format_tags: list[str] = Field(default_factory=list)
    release_group: str | None = None
    confidence: float = 0
    reason: str | None = None
    suggested_regex: str | None = None
    warnings: list[str] = Field(default_factory=list)
    requires_confirmation: bool = True
    error_code: str | None = None


class SmartSubscriptionPrefillRequest(SubscriptionSuggestionRequest):
    use_ai: bool | None = None


class SmartSubscriptionPrefillResponse(BaseModel):
    ok: bool
    message: str
    form_defaults: SubscriptionCreate | None = None
    ai_result: AITitleAnalysisResponse | None = None
    local_result: ParsedAnimeTitle
    source: Literal["ai", "local", "mixed"] = "local"
    warnings: list[str] = Field(default_factory=list)
    duplicate_subscription_id: int | None = None
    duplicate_subscription_name: str | None = None
    identity_key: str | None = None
    match_status: Literal["none", "matched", "ambiguous"] = "none"
    match_reason: str | None = None
    match_candidate_ids: list[int] = Field(default_factory=list)
    matched_subscription: Subscription | None = None


class EpisodeRulesUpdateRequest(BaseModel):
    episode_parse_rules: list[EpisodeParseRule] = Field(default_factory=list)


class ParsedAnimeTitle(BaseModel):
    original_title: str
    title: str | None = None
    episode: int | None = None
    episode_number: int | None = None
    episode_start: int | None = None
    episode_end: int | None = None
    is_batch: bool = False
    is_multi_episode: bool = False
    is_final: bool = False
    is_special: bool = False
    resource_type: Literal["single_episode", "episode_range", "batch", "special", "unknown"] = "unknown"
    display_episode_label: str | None = None
    parse_rule_name: str | None = None
    parse_reason: str | None = None
    parse_confidence: float = 0.0
    parse_failure_reason: str | None = None
    season: int | None = None
    season_number: int | None = None
    explicit_season_number: int | None = None
    inferred_season_number: int | None = None
    context_season_number: int | None = None
    effective_season_number: int | None = None
    season_source: Literal["subscription", "metadata", "title_explicit", "mikan", "default", "unknown"] = "unknown"
    season_conflict: bool = False
    season_conflict_reason: str | None = None
    part_number: int | None = None
    absolute_episode_number: int | None = None
    absolute_episode_start: str | None = None
    absolute_episode_end: str | None = None
    absolute_episode_start_sort: float | None = None
    absolute_episode_end_sort: float | None = None
    season_episode_start: int | None = None
    season_episode_end: int | None = None
    batch_title: str | None = None
    fansub: str | None = None
    resolution: str | None = None
    subtitle_language: str | None = None
    version: str | None = None
    file_size: str | None = None
    confidence: float = 0.0
    needs_confirmation: bool = True

    @model_validator(mode="after")
    def derive_resource_fields(self) -> "ParsedAnimeTitle":
        if self.effective_season_number is None:
            self.effective_season_number = self.season_number or self.season
        if self.season_number is None:
            self.season_number = self.effective_season_number or self.season
        if self.season is None:
            self.season = self.effective_season_number or self.season_number
        if self.season_number is None:
            self.season_number = self.season
        elif self.season is None:
            self.season = self.season_number
        if self.episode is None and self.episode_number is not None:
            self.episode = self.episode_number
        if self.episode_number is None and self.episode is not None:
            self.episode_number = self.episode
        if self.episode_start is None and self.episode is not None:
            self.episode_start = self.episode
        if self.absolute_episode_number is None and self.episode is not None and not self.is_batch:
            self.absolute_episode_number = self.episode
        if self.absolute_episode_start_sort is None and self.absolute_episode_start is not None:
            try:
                self.absolute_episode_start_sort = float(self.absolute_episode_start)
            except ValueError:
                self.absolute_episode_start_sort = None
        if self.absolute_episode_end_sort is None and self.absolute_episode_end is not None:
            try:
                self.absolute_episode_end_sort = float(self.absolute_episode_end)
            except ValueError:
                self.absolute_episode_end_sort = None
        if self.episode_end is not None and self.episode_start is not None and self.episode_end < self.episode_start:
            self.episode_end = self.episode_start
        has_range = self.episode_start is not None and self.episode_end is not None and self.episode_end > self.episode_start
        if self.is_batch:
            self.resource_type = "batch"
        elif self.is_special:
            self.resource_type = "special"
        elif has_range:
            self.resource_type = "episode_range"
        elif self.episode is not None:
            self.resource_type = "single_episode"
        else:
            self.resource_type = "unknown"
        self.is_multi_episode = self.resource_type in {"episode_range", "batch"}
        if not self.display_episode_label:
            if self.resource_type == "batch" and self.absolute_episode_start and self.absolute_episode_end:
                self.display_episode_label = f"合集 {self.absolute_episode_start}–{self.absolute_episode_end}"
            elif self.resource_type == "batch" and self.episode_start is not None and self.episode_end is not None:
                self.display_episode_label = f"合集 {self.episode_start}–{self.episode_end}"
            elif self.resource_type == "batch":
                self.display_episode_label = "合集"
            elif self.resource_type == "episode_range" and self.episode_start is not None and self.episode_end is not None:
                self.display_episode_label = f"第 {self.episode_start}–{self.episode_end} 集"
            elif self.resource_type == "single_episode" and self.episode is not None:
                self.display_episode_label = f"第 {self.episode} 集"
            elif self.resource_type == "special":
                self.display_episode_label = "特典"
            else:
                self.display_episode_label = "集数未识别"
        if not self.parse_reason:
            self.parse_reason = self.parse_rule_name or self.parse_failure_reason
        return self


class SubscriptionMatch(BaseModel):
    id: int
    subscription_id: int
    fingerprint: str
    result: SearchResult
    parsed_title: ParsedAnimeTitle
    status: str
    first_seen_at: datetime
    last_seen_at: datetime
    logical_episode_start: int | None = None
    logical_episode_end: int | None = None
    episode_offset_applied: int = 0
    episode_mapping_label: str | None = None


class PlexSeasonMapping(BaseModel):
    subject_key: str
    show_name: str
    show_year: int | None = None
    season_number: int = Field(default=1, ge=0)
    episode_offset: int = 0
    special_episode_numbers: dict[str, int] = Field(default_factory=dict)


class PlexMappingResponse(BaseModel):
    ok: bool
    mapping_id: int


class PlexMappingRecord(BaseModel):
    id: int
    mapping: PlexSeasonMapping
    created_at: datetime
    updated_at: datetime | None = None


class OrganizePreviewFileOverride(BaseModel):
    id: str
    season_number: int = Field(default=1, ge=0)
    episode_number: int | None = Field(default=None, ge=1)
    is_special: bool = False
    skipped: bool = False


class OrganizePreviewRequest(BaseModel):
    source_path: str = ""
    media_type: Literal["tv", "anime", "movie"] = "anime"
    select_files: bool = False
    download_record_id: int | None = None
    library_root: str = "Anime Library"
    organize_target_id: int | None = None
    original_filename: str = ""
    parsed_title: ParsedAnimeTitle | None = None
    mapping: PlexSeasonMapping
    episode_title: str | None = None
    is_special: bool = False
    single_file_mode: Literal["as_batch_file", "episode_range", "specials_batch"] | None = None
    file_mapping_overrides: list[OrganizePreviewFileOverride] = Field(default_factory=list)


class OrganizeSubtitleMapping(BaseModel):
    source_path: str
    original_filename: str
    target_filename: str
    target_path: str
    language_suffix: str = ""
    extension: str
    status: Literal["ready", "skipped", "error"] = "ready"
    message: str = "可整理"


class OrganizePreviewFileMapping(BaseModel):
    id: str
    source_path: str
    original_filename: str
    parsed_episode: int | None = None
    season_number: int = Field(default=1, ge=0)
    episode_number: int | None = Field(default=None, ge=1)
    is_special: bool = False
    target_filename: str
    target_path: str
    status: Literal["ready", "needs_confirmation", "skipped", "error"] = "ready"
    message: str = ""
    manual_override: bool = False
    override_reason: str | None = None
    warnings: list[str] = Field(default_factory=list)
    subtitle_mappings: list[OrganizeSubtitleMapping] = Field(default_factory=list)


class OrganizePreviewItem(BaseModel):
    preview_id: int | None = None
    media_type: Literal["tv", "anime", "movie"] = "anime"
    download_record_id: int | None = None
    organize_target_id: int | None = None
    source_path: str
    library_root: str = "Anime Library"
    show_directory: str
    season_directory: str
    filename: str
    destination_preview: str
    will_move: bool = False
    can_apply: bool = False
    block_reason: str | None = None
    warnings: list[str] = Field(default_factory=list)
    is_batch: bool = False
    batch_mode: Literal["none", "multi_file", "single_file"] = "none"
    single_file_mode: Literal["none", "as_batch_file", "episode_range", "specials_batch"] = "none"
    episode_start: int | None = None
    episode_end: int | None = None
    partial_batch: bool = False
    file_mappings: list[OrganizePreviewFileMapping] = Field(default_factory=list)
    subtitle_mappings: list[OrganizeSubtitleMapping] = Field(default_factory=list)


class OrganizePreviewRecord(BaseModel):
    id: int
    request: OrganizePreviewRequest
    preview: OrganizePreviewItem
    created_at: datetime
    remaining_source_paths: list[str] | None = None


class OrganizeHistoryRecord(BaseModel):
    id: int
    source_path: str
    destination_path: str
    status: str
    message: str
    preview: OrganizePreviewItem
    qbittorrent_task_deleted: bool = False
    delete_files_from_qbittorrent: bool = False
    cleanup_attempted: bool = False
    cleanup_status: str | None = None
    cleanup_path: str | None = None
    cleanup_message: str | None = None
    subscription_id: int | None = None
    subscription_season: int | None = None
    resource_explicit_season: int | None = None
    effective_season: int | None = None
    season_source: str | None = None
    manual_override: bool = False
    override_reason: str | None = None
    created_at: datetime


class OrganizeApplyRequest(BaseModel):
    preview: OrganizePreviewItem
    confirm_real_move: bool = False


class OrganizeApplyResponse(BaseModel):
    ok: bool
    status: Literal["moved", "skipped", "error"]
    message: str
    source_path: str
    destination_path: str
    history_id: int
    subtitle_mappings: list[OrganizeSubtitleMapping] = Field(default_factory=list)


class SubscriptionOrganizeRequest(BaseModel):
    episode_numbers: list[int] = Field(default_factory=list)
    match_ids: list[int] = Field(default_factory=list)
    organize_target_id: int | None = None
    delete_qbittorrent_task_after_success: bool | None = None
    delete_files_from_qbittorrent: bool | None = None
    keep_seeding: bool | None = None
    dry_run: bool = False
    confirm: bool = False
    manual_override: bool = False
    override_reason: str | None = None


class SubscriptionOrganizeEpisodeResult(BaseModel):
    episode_number: int | None = None
    match_id: int | None = None
    title: str
    status: Literal[
        "moved",
        "skipped",
        "error",
        "preview",
        "needs_review",
        "waiting_download",
        "batch_needs_review",
        "batch_partially_organized",
    ]
    message: str
    source_path: str | None = None
    destination_path: str | None = None
    history_id: int | None = None
    qbittorrent_task_deleted: bool = False
    delete_files_from_qbittorrent: bool = False
    cleanup_attempted: bool = False
    cleanup_status: str | None = None
    cleanup_path: str | None = None
    cleanup_message: str | None = None
    subtitle_mappings: list[OrganizeSubtitleMapping] = Field(default_factory=list)


class SubscriptionOrganizeResponse(BaseModel):
    ok: bool
    subscription_id: int
    message: str
    organized: int = 0
    skipped: int = 0
    failed: int = 0
    dry_run: bool = False
    target: OrganizeTarget | None = None
    results: list[SubscriptionOrganizeEpisodeResult] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
