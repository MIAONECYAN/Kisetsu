from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import json
import logging
import re
import time
import threading
import unicodedata
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any, Literal
from urllib.parse import parse_qs, urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse

from app.automation import AutomationService
from app.core.downloader import DownloaderAddResult
from app.core.qbittorrent import QbittorrentClient, QbittorrentError, describe_qbittorrent_error
from app.core.downloaders import (
    describe_downloader_error,
    downloader_client,
    downloader_configured,
    downloader_display_name,
    merge_downloader_secret,
    public_downloader_config,
    stored_downloader_routing,
    stored_qbittorrent_config as load_qbittorrent_config,
    stored_transmission_config,
)
from app.core.transmission import TransmissionClient, TransmissionError, describe_transmission_error
from app.db import Store
from app.dependencies import get_store
from app.settings import DATA_DIR
from app.models import (
    AIProviderProfile,
    AIProviderProfileResponse,
    AISettings,
    AIModelInfo,
    AIModelListRequest,
    AIModelListResponse,
    AISettingsResponse,
    AISettingsTestRequest,
    AITitleAnalyzeRequest,
    AITitleAnalysisResponse,
    AppSettingsResponse,
    AutomationJobRecord,
    AutomationRunNowResponse,
    AutomationSettingsRequest,
    AutomationIntervalRequest,
    AutomationStatus,
    DownloadHistory,
    DownloadHistoryDeleteResponse,
    DownloadHistoryManageRequest,
    DownloadHistoryManageResponse,
    DownloadRequest,
    DownloadResponse,
    DownloaderRoutingResponse,
    DownloaderRoutingSettings,
    DownloaderStatus,
    EpisodeParseRule,
    EpisodeRulePreviewRequest,
    EpisodeRulePreviewResponse,
    EpisodeRuleSettingsResponse,
    EpisodeRuleSettingsUpdate,
    EpisodeRuleTestCase,
    EpisodeRuleTestItem,
    EpisodeRuleTestRequest,
    EpisodeRuleTestResponse,
    EpisodeRuleTokenizeRequest,
    EpisodeRuleTokenizeResponse,
    EpisodeRuleVisualMark,
    EpisodeTitleToken,
    EpisodeRulesUpdateRequest,
    HistoryClearRequest,
    HistoryClearResponse,
    MetadataBindRequest,
    MetadataBindResponse,
    MetadataBindingRecord,
    MatchDiagnosticSample,
    MetadataSettings,
    MetadataSettingsResponse,
    SubscriptionHierarchyEpisode,
    SubscriptionHierarchySeason,
    SubscriptionEpisodeResource,
    SubscriptionLogicalEpisodeStatus,
    SubscriptionMetadataHierarchy,
    MetadataMatchRequest,
    MetadataSearchRequest,
    MetadataSearchResponse,
    MikanProjectResourcesResponse,
    MikanProjectSeasonResponse,
    MikanProjectSettings,
    OrganizeApplyRequest,
    OrganizeApplyResponse,
    OrganizePreviewFileMapping,
    OrganizeFailedHistoryDeleteRequest,
    OrganizeFailedHistoryDeleteResponse,
    OrganizeFailedHistorySummary,
    OrganizeHistoryClearRequest,
    OrganizeHistoryRecord,
    OrganizePolicySettings,
    OrganizePreviewItem,
    OrganizePreviewRecord,
    OrganizePreviewRequest,
    OrganizeTarget,
    OrganizeTargetCreate,
    OrganizeTargetPreview,
    OrganizeTargetUpdate,
    OrganizeTargetValidateResponse,
    OverviewActionTarget,
    OverviewItem,
    OverviewResponse,
    OverviewSubscriptionSummary,
    PosterPalette,
    PlexMappingResponse,
    PlexMappingRecord,
    PlexSeasonMapping,
    ParsedAnimeTitle,
    QbittorrentConfig,
    QbittorrentGlobalLimits,
    QbittorrentGlobalLimitsUpdate,
    QbittorrentTaskProgress,
    QbittorrentTestResponse,
    TransmissionConfig,
    TransmissionGlobalLimits,
    TransmissionGlobalLimitsUpdate,
    TransmissionTestResponse,
    RefreshAllResponse,
    RefreshResponse,
    ResetSubscriptionRequest,
    ResetSubscriptionResponse,
    RssTestRequest,
    RssTestResponse,
    SchedulerStartRequest,
    SchedulerStatus,
    SearchDiagnostics,
    SearchRequest,
    SearchResult,
    SearchResponse,
    SearchSettings,
    SiteDomainTestRequest,
    SiteDomainTestResponse,
    SiteCreateRequest,
    SiteMirrorRequest,
    SiteSearchDiagnostics,
    SiteInfo,
    SiteSettingsUpdate,
    SmartSubscriptionPrefillRequest,
    SmartSubscriptionPrefillResponse,
    Subscription,
    SubscriptionCreate,
    SubscriptionGroup,
    SubscriptionGroupName,
    SubscriptionGroupDeleteRequest,
    SubscriptionDetail,
    SubscriptionCoverageSummary,
    SubscriptionDownloadRequest,
    SubscriptionDownloadResponse,
    SubscriptionHistoryClearRequest,
    SubscriptionRefreshHistory,
    SubscriptionEpisodeStatus,
    SubscriptionOrganizeEpisodeResult,
    SubscriptionOrganizeRequest,
    SubscriptionOrganizeResponse,
    SubscriptionListItem,
    SubscriptionMatch,
    SubscriptionSuggestionRequest,
    SubscriptionSuggestionResponse,
    SubscriptionTestMatchRequest,
    SubscriptionTestMatchResponse,
    TMDBTestRequest,
    TitleParseRequest,
    normalize_site_id,
)
from app.metadata.bangumi import total_episodes_from_subject
from app.metadata.tmdb import TMDBAdapter
from app.notifications import NotificationEvent, NotificationService, NotificationSettings, NotificationTestRequest, NotificationTestResponse, notification_settings_response
from app.notifications.models import NotificationSettingsResponse
from app.notifications.pending import history_size_target, send_or_defer_size_notification
from app.notifications.service import notification_settings_from_payload, stored_notification_settings
from app.notifications.templates import download_completed_event, download_failed_event, download_started_event, organize_completed_event, organize_failed_event, organize_needs_review_event, subscription_metadata_bound_event, subscription_refresh_failed_event
from app.services.metadata_matcher import match_metadata_title, search_metadata
from app.services.ai_provider import (
    AIProviderFailure,
    ai_endpoint_url,
    ai_request_timeout,
    build_chat_completion_payload,
    extract_chat_completion_content,
    extract_model_items,
    failure_from_request_error,
    failure_from_response,
    normalize_ai_base_url,
    provider_default_base_url,
    provider_default_model,
    provider_label,
)
from app.services.downloads import PRIVATE_TORRENT_SITES, confirmed_task_size_bytes, release_subscription_download_tag, resource_total_size_bytes, submit_result_to_downloader, subscription_download_tag
from app.services.episode_fulfillment import (
    EpisodeMediaIndex as _EpisodeMediaIndex,
    EpisodeOrganizeState as _EpisodeOrganizeState,
    build_episode_media_index as build_shared_episode_media_index,
    covered_episode_numbers as shared_covered_episode_numbers,
    current_subscription_metadata_binding as shared_current_subscription_metadata_binding,
    mapping_for_subscription as shared_mapping_for_subscription,
    media_target_for_subscription as shared_media_target_for_subscription,
    subscription_detail_metadata_bindings as shared_subscription_detail_metadata_bindings,
    subscription_detail_plex_mappings as shared_subscription_detail_plex_mappings,
    subscription_episode_in_target_scope as shared_subscription_episode_in_target_scope,
    subscription_logical_episode_numbers as shared_subscription_logical_episode_numbers,
    subscription_target_episode_counts as shared_subscription_target_episode_counts,
)
from app.services.managed_directories import (
    ManagedDirectoryTarget,
    paths_overlap,
    prune_empty_managed_directory,
    subscription_directory_targets,
    subscription_download_directory,
)
from app.services.mikan_project import (
    cache_mikan_project_poster,
    fetch_mikan_project_resources,
    fetch_bangumi_subject_with_episodes,
    load_cached_mikan_project_season,
    mikan_project_cache_is_stale,
    mikan_project_poster_path,
    refresh_mikan_project_season,
    save_mikan_project_settings,
    stored_mikan_project_settings,
)
from app.services.organizer import (
    OrganizeApplyError,
    OrganizeApplyResult,
    apply_preview,
    build_preview,
    destination_path_for_preview,
    is_ignored_media_metadata_path,
    organize_preview_availability,
    preview_targets_already_organized,
    subtitle_mappings_for_preview,
)
from app.services.plex_naming import clean_path_component, season_directory, show_directory
from app.services.search import search_multi_site
from app.services.search_result_analysis import enrich_search_result, is_collection_parsed
from app.services.subscription import (
    analyze_match,
    filter_results_by_subscription_size,
    fingerprint_result,
    match_results_with_diagnostics,
    parse_episode_filter,
    record_processed,
)
from app.services.subscription_identity import (
    mikan_bangumi_id_from_value,
    normalized_identity_text,
    subscription_mikan_bangumi_ids,
    title_identity_keys,
)
from app.services.subscription_runner import fetch_subscription_results, reconcile_pending_confirmations, refresh_all_enabled, refresh_subscription as run_subscription_refresh
from app.services.title_parser import normalize_resolution_preset, parse_title
from app.settings import default_organize_policy, mask_secret, mask_url_secret, set_runtime_tmdb_api_key, tmdb_api_key
from app.sites import default_site_settings, describe_site_error, get_site_adapter, list_sites, merge_site_settings, site_usage_restriction
from app.sites.rate_limiter import drain_rate_limit_events

router = APIRouter(prefix="/api")
logger = logging.getLogger("kisetsu.api")
DOWNLOAD_HISTORY_CACHE_KEY = "download_history_state_cache"
_ORGANIZING_SUBSCRIPTION_IDS: set[int] = set()


def stored_qbittorrent_config(store: Store) -> QbittorrentConfig | None:
    return load_qbittorrent_config(store)


def _configured_downloader_client(store: Store, downloader_type: str):
    if downloader_type == "qbittorrent":
        config = stored_qbittorrent_config(store)
        if config is None or (
            isinstance(config, QbittorrentConfig)
            and (not config.username or not config.password)
        ):
            raise ValueError("qBittorrent 用户名或密码未配置")
        return QbittorrentClient(config)
    return downloader_client(store, downloader_type)


def stored_metadata_settings(store: Store) -> MetadataSettings:
    data = store.get_runtime_config("metadata") or {}
    return MetadataSettings(**data)


def _notification_service(store: Store) -> NotificationService:
    return NotificationService(store)


def stored_organize_policy(store: Store) -> OrganizePolicySettings:
    data = store.get_config("organize_policy") or {}
    try:
        return OrganizePolicySettings(**data)
    except ValueError:
        return default_organize_policy()


def stored_site_settings(store: Store) -> dict[str, dict]:
    return store.get_runtime_config("site_settings") or {}


def merged_site_settings_payload(store: Store) -> dict[str, dict]:
    return {site_id: settings.model_dump(mode="json") for site_id, settings in merge_site_settings(stored_site_settings(store)).items()}


def managed_site_ids(store: Store) -> list[str]:
    known = set(default_site_settings())
    return [site_id for site_id in stored_site_settings(store) if site_id in known]


def save_managed_site_settings(store: Store, site_id: str, settings: SiteSettingsUpdate) -> None:
    raw = dict(stored_site_settings(store))
    raw[site_id] = settings.model_dump(mode="json")
    store.set_runtime_config("site_settings", raw)


def merge_site_secret_fields(current: dict, incoming: SiteSettingsUpdate) -> dict:
    data = incoming.model_dump(mode="json")
    for field, clear_field in (
        ("api_key", "clear_api_key"),
        ("cookie", "clear_cookie"),
        ("passkey", "clear_passkey"),
        ("authorization", "clear_authorization"),
        ("rss_url", "clear_rss_url"),
    ):
        if data.get(clear_field):
            data[field] = None
        elif not data.get(field):
            data[field] = current.get(field)
        data[clear_field] = False
    if data.get("clear_request_headers"):
        data["request_headers"] = {}
    elif not data.get("request_headers"):
        data["request_headers"] = current.get("request_headers") or {}
    data["clear_request_headers"] = False
    return data


def delete_managed_site_settings(store: Store, site_id: str) -> bool:
    raw = dict(stored_site_settings(store))
    if site_id not in raw:
        return False
    raw.pop(site_id, None)
    store.set_runtime_config("site_settings", raw)
    return True


def builtin_episode_rules() -> list[EpisodeParseRule]:
    return [
        EpisodeParseRule(id="builtin-star-single", name="星号分隔的单集", pattern=r"★\s*(?<episode>\d{1,3})(?:v\d+)?\s*★", priority=0, rule_type="builtin", example_title="番名★12★1080p", description="识别为第 12 集"),
        EpisodeParseRule(id="builtin-star-range", name="星号分隔的合集", pattern=r"★\s*(?<start>\d{1,3})\s*[~～-]\s*(?<end>\d{1,3})\s*(?<final>\(完\)|（完）)?\s*★", priority=1, rule_type="builtin", example_title="番名★01~12(完)★1080p", description="识别为第 1-12 集合集，并标记完结"),
        EpisodeParseRule(id="builtin-bracket-single", name="方括号单集", pattern=r"\[(?<episode>\d{1,3})(?:v\d+)?\]", priority=2, rule_type="builtin", example_title="[字幕组][番名][03][1080p]", description="识别为第 3 集"),
        EpisodeParseRule(id="builtin-bracket-range", name="方括号合集", pattern=r"\[(?<start>\d{1,3})\s*[-~～]\s*(?<end>\d{1,3})\]", priority=3, rule_type="builtin", example_title="[番名][1-12][合集]", description="识别为第 1-12 集合集"),
        EpisodeParseRule(id="builtin-episode-word", name="中文第几话", pattern=r"第\s*(?<episode>\d{1,3})\s*[话話集]", priority=4, rule_type="builtin", example_title="番名 第 08 话", description="识别为第 8 集"),
        EpisodeParseRule(id="builtin-plain-v2", name="带版本号的单集", pattern=r"(?:^|[^\d])(?<episode>\d{1,3})v\d+(?=$|[^\d])", priority=5, rule_type="builtin", example_title="番名 01v2", description="识别为第 1 集，并忽略 v2 修正版标记"),
        EpisodeParseRule(id="builtin-final", name="带完结标记", pattern=r"(?:^|[^\d])(?<episode>\d{1,3})\s*(?<final>\(完\)|（完）)", priority=6, rule_type="builtin", example_title="番名 12(完)", description="识别为第 12 集并标记完结"),
    ]


def stored_global_episode_rules(store: Store) -> list[EpisodeParseRule]:
    data = store.get_config("episode_parse_rules") or {}
    return [EpisodeParseRule(**item) for item in data.get("user_rules", []) if isinstance(item, dict)]


def _effective_episode_rules(subscription: Subscription, store: Store) -> list[EpisodeParseRule]:
    rules = [*subscription.episode_parse_rules, *stored_global_episode_rules(store)]
    normalized: list[EpisodeParseRule] = []
    for index, rule in enumerate(rules):
        normalized.append(rule.model_copy(update={"priority": index}))
    return normalized


EPISODE_TOKEN_RE = re.compile(
    r"(\(完\)|（完）|\bEND\b|\bFin\b|\d{3,4}x\d{3,4}|\d+|[~～\-]|[★\[\]【】()\s_/／]+|[^\d~～\-★\[\]【】()\s_/／]+)",
    re.I,
)


def _token_kind(text: str) -> str:
    if re.fullmatch(r"\d{3,4}x\d{3,4}", text, flags=re.I):
        return "resolution"
    if re.fullmatch(r"\d+", text):
        return "number"
    if re.fullmatch(r"\(完\)|（完）|\bEND\b|\bFin\b", text, flags=re.I):
        return "final"
    if re.fullmatch(r"[~～\-]", text):
        return "separator"
    if any(ch in text for ch in "[]【】()"):
        return "bracket"
    if any(ch in text for ch in "★_/／") or text.isspace():
        return "symbol"
    return "text"


def tokenize_episode_title(title: str) -> list[EpisodeTitleToken]:
    tokens: list[EpisodeTitleToken] = []
    for index, match in enumerate(EPISODE_TOKEN_RE.finditer(title)):
        text = match.group(0)
        if not text:
            continue
        tokens.append(
            EpisodeTitleToken(
                id=index,
                text=text,
                start_index=match.start(),
                end_index=match.end(),
                kind=_token_kind(text),
            )
        )
    return tokens


def _visual_rule_name(title: str, marks: list[EpisodeRuleVisualMark], fallback: str | None = None) -> str:
    if fallback and fallback.strip():
        return fallback.strip()
    title_key = title.split("★")[0].strip(" []【】") if "★" in title else ""
    mark_types = {mark.mark_type for mark in marks}
    if "start" in mark_types and "end" in mark_types:
        return f"{title_key}合集规则" if title_key else "自定义合集规则"
    return f"{title_key}单集规则" if title_key else "自定义单集规则"


NOISE_DIGIT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b(?:720|1080|2160)p\b", re.I), "分辨率"),
    (re.compile(r"\b4K\b", re.I), "分辨率"),
    (re.compile(r"\bH\.(?:264|265)\b", re.I), "编码格式"),
    (re.compile(r"\bx(?:264|265)\b", re.I), "编码格式"),
    (re.compile(r"\bSRTx\d+\b", re.I), "字幕轨数量"),
    (re.compile(r"\b(?:AAC|HEVC)\b", re.I), "编码信息"),
]


def _find_mark_token(tokens: list[EpisodeTitleToken], mark: EpisodeRuleVisualMark) -> tuple[int, EpisodeTitleToken] | None:
    for index, token in enumerate(tokens):
        if token.id == mark.token_id or (token.start_index == mark.start_index and token.end_index == mark.end_index):
            return index, token
    return None


def _near_text(tokens: list[EpisodeTitleToken], index: int, direction: int, limit: int = 3) -> str:
    values: list[str] = []
    cursor = index + direction
    while 0 <= cursor < len(tokens) and len(values) < limit:
        text = tokens[cursor].text
        if direction < 0:
            values.insert(0, text)
        else:
            values.append(text)
        cursor += direction
    return "".join(values)


def _noise_warnings(title: str, selected_texts: set[str] | None = None) -> list[str]:
    selected_texts = selected_texts or set()
    warnings: list[str] = []
    for pattern, label in NOISE_DIGIT_PATTERNS:
        for match in pattern.finditer(title):
            value = match.group(0)
            if value in selected_texts:
                warnings.append(f"你标记的数字看起来像{label} {value}，确定要作为集数吗？")
            else:
                warnings.append(f"忽略 {value}，因为它更像{label}。")
    return list(dict.fromkeys(warnings))


def _single_episode_pattern(
    tokens: list[EpisodeTitleToken],
    mark: EpisodeRuleVisualMark,
    title: str,
) -> tuple[str, float, list[str], list[str]]:
    located = _find_mark_token(tokens, mark)
    previous_text = ""
    next_text = ""
    if located:
        index, _ = located
        previous_text = _near_text(tokens, index, -1)
        next_text = _near_text(tokens, index, 1)
    window = previous_text + mark.token_text + next_text
    explanation: list[str] = []
    warnings = _noise_warnings(title, {mark.token_text})

    if re.search(r"EP\s*$", previous_text, re.I):
        explanation.append(f"识别到 {mark.token_text} 前有 EP 前缀，因此生成 EP 集数规则。")
        return r".*(?:^|[\s\-_])EP\s*(?P<episode>\d{1,3})(?:\b|[^\d]).*", 0.94, explanation, warnings
    if "第" in previous_text and re.search(r"^[\s]*(?:话|話|集)", next_text):
        explanation.append(f"识别到“第{mark.token_text}话/集”结构，因此生成中文集数规则。")
        return r".*第\s*(?P<episode>\d{1,3})\s*[话話集].*", 0.93, explanation, warnings
    if "★" in previous_text and "★" in next_text:
        explanation.append(f"识别到 {mark.token_text} 被 ★ 分隔，因此生成星号单集规则。")
        return r".*★\s*(?P<episode>\d{1,3})(?:v\d+)?\s*(?P<final>[\(（]?(?:完|完结|END|Fin)[\)）]?)?\s*★.*", 0.92, explanation, warnings
    if re.search(r"[\[【]\s*$", previous_text) and re.search(r"^\s*[\]】]", next_text):
        explanation.append(f"识别到 {mark.token_text} 位于括号中，因此生成括号集数规则。")
        return r".*[\[【]\s*(?P<episode>\d{1,3})\s*[\]】].*", 0.88, explanation, warnings
    if re.search(r"^\s*[\(（]?(?:完|完结|END|Fin)", next_text, re.I):
        explanation.append(f"识别到 {mark.token_text} 后带完结标记，因此生成完结单集规则。")
        return r".*(?:^|[^\d])(?P<episode>\d{1,3})\s*(?P<final>[\(（]?(?:完|完结|END|Fin)[\)）]?)(?:$|[^\d]).*", 0.84, explanation, warnings
    if "-" in previous_text and re.search(r"^\s*[\[【]", next_text):
        explanation.append(f"识别到 {mark.token_text} 位于“标题 - 集数 [规格]”结构，因此生成横线单集规则。")
        return r".*-\s*(?P<episode>\d{1,3})(?=\s*[\[【]).*", 0.86, explanation, warnings

    explanation.append(f"仅识别到数字 {mark.token_text}，上下文较少。")
    warnings.append("这个规则上下文较少，可能误匹配其他数字。建议标记包含 EP、括号或分隔符的完整片段。")
    if window.strip():
        warnings.append(f"附近上下文：{window.strip()}")
    return r".*(?<![A-Za-z0-9])(?P<episode>\d{1,3})(?![A-Za-z0-9]).*", 0.55, explanation, warnings


def _range_episode_pattern(
    tokens: list[EpisodeTitleToken],
    start: EpisodeRuleVisualMark,
    end: EpisodeRuleVisualMark,
    title: str,
) -> tuple[str, float, list[str], list[str]]:
    located_start = _find_mark_token(tokens, start)
    located_end = _find_mark_token(tokens, end)
    previous_text = _near_text(tokens, located_start[0], -1) if located_start else ""
    next_text = _near_text(tokens, located_end[0], 1) if located_end else ""
    explanation = [f"识别到 {start.token_text}~{end.token_text} 范围，因此生成合集范围规则。"]
    warnings = _noise_warnings(title, {start.token_text, end.token_text})
    final_group = r"(?P<final>[\(（]?(?:完|完结|END|Fin)[\)）]?)?"
    if "★" in previous_text and "★" in next_text:
        explanation.append("范围两侧有 ★ 分隔，保留星号上下文。")
        return rf".*★\s*(?P<start>\d{{1,3}})\s*[~～\-]\s*(?P<end>\d{{1,3}})\s*{final_group}\s*★.*", 0.92, explanation, warnings
    return rf".*(?:^|[^\d])(?P<start>\d{{1,3}})\s*[~～\-]\s*(?P<end>\d{{1,3}})\s*{final_group}(?:$|[^\d]).*", 0.78, explanation, warnings


def visual_rule_from_marks(
    title: str,
    marks: list[EpisodeRuleVisualMark],
    *,
    name: str | None = None,
    rule_id: str = "visual-preview",
    priority: int = 0,
) -> tuple[EpisodeParseRule | None, list[str], float, list[str], list[str]]:
    tokens = tokenize_episode_title(title)
    ordered_marks = sorted(marks, key=lambda item: (item.start_index, item.end_index))
    suggestions: list[str] = []
    by_type: dict[str, EpisodeRuleVisualMark] = {}
    for mark in ordered_marks:
        if mark.mark_type in by_type:
            suggestions.append(f"“{mark.mark_type}”只能标记一次，请清除重复标记。")
        by_type[mark.mark_type] = mark
    has_episode = "episode" in by_type
    has_range = "start" in by_type or "end" in by_type
    if not has_episode and not has_range:
        return None, ["请选择单集集数，或同时选择合集开始和合集结束。"], 0, [], []
    if has_episode and has_range:
        return None, ["单集和合集范围不能同时标记，请保留一种。"], 0, [], []
    if has_range and ("start" not in by_type or "end" not in by_type):
        return None, ["你选择了合集开始，但还没有选择合集结束。" if "start" in by_type else "你选择了合集结束，但还没有选择合集开始。"], 0, [], []

    if has_episode:
        pattern, confidence, explanation, warnings = _single_episode_pattern(tokens, by_type["episode"], title)
    else:
        pattern, confidence, explanation, warnings = _range_episode_pattern(tokens, by_type["start"], by_type["end"], title)
    rule = EpisodeParseRule(
        id=rule_id,
        name=_visual_rule_name(title, marks, name),
        pattern=pattern,
        enabled=True,
        priority=priority,
        rule_type="user",
        mode="visual",
        sample_title=title,
        example_title=title,
        description="由可视化标记生成",
        visual_marks=ordered_marks,
        generated_pattern=pattern,
    )
    return rule, suggestions, confidence, explanation, warnings


def normalize_episode_rule(rule: EpisodeParseRule, priority: int) -> EpisodeParseRule:
    if rule.mode == "visual" and rule.sample_title and rule.visual_marks:
        generated, suggestions, _, _, _ = visual_rule_from_marks(
            rule.sample_title,
            rule.visual_marks,
            name=rule.name,
            rule_id=rule.id,
            priority=priority,
        )
        if generated is None:
            raise ValueError("；".join(suggestions))
        return generated.model_copy(update={"enabled": rule.enabled, "priority": priority})
    return rule.model_copy(update={"priority": priority, "rule_type": "user"})


def episode_rule_preview_message(parsed, suggestions: list[str]) -> tuple[bool, str, list[str]]:
    if parsed.episode is None:
        reason = parsed.parse_failure_reason or "没有找到集数。请标记标题中的集数数字。"
        return False, reason, suggestions or [reason]
    if parsed.is_batch:
        final = " · 完结" if parsed.is_final else ""
        return True, f"识别结果：合集 · 第 {parsed.episode_start or parsed.episode}-{parsed.episode_end or parsed.episode} 集{final}", suggestions
    final = " · 完结" if parsed.is_final else ""
    return True, f"识别结果：第 {parsed.episode} 集{final}", suggestions


def _mark_number(mark: EpisodeRuleVisualMark | None) -> int | None:
    if mark is None:
        return None
    match = re.search(r"\d{1,4}", mark.token_text)
    if not match:
        return None
    try:
        return int(match.group(0))
    except ValueError:
        return None


def _parsed_title_from_visual_marks(
    title: str,
    rule: EpisodeParseRule,
    marks: list[EpisodeRuleVisualMark],
    confidence: float,
) -> ParsedAnimeTitle:
    by_type = {mark.mark_type: mark for mark in marks}
    local = parse_title(title)
    is_final = "final" in by_type or local.is_final
    if "episode" in by_type:
        episode = _mark_number(by_type.get("episode"))
        return local.model_copy(
            update={
                "episode": episode,
                "episode_number": episode,
                "episode_start": episode,
                "episode_end": episode,
                "is_batch": False,
                "is_final": is_final,
                "parse_rule_name": rule.name,
                "parse_confidence": confidence,
                "parse_failure_reason": None if episode is not None else "标记的片段中没有可用集数数字。",
                "confidence": confidence,
                "needs_confirmation": confidence < 0.75,
            }
        )
    start = _mark_number(by_type.get("start"))
    end = _mark_number(by_type.get("end"))
    episode = start if start is not None else end
    return local.model_copy(
        update={
            "episode": episode,
            "episode_number": episode,
            "episode_start": start,
            "episode_end": end,
            "is_batch": start is not None and end is not None and start != end,
            "is_final": is_final,
            "parse_rule_name": rule.name,
            "parse_confidence": confidence,
            "parse_failure_reason": None if start is not None and end is not None else "合集开始或结束标记缺少可用数字。",
            "confidence": confidence,
            "needs_confirmation": confidence < 0.75,
        }
    )


def _episode_rule_test_item(test: EpisodeRuleTestCase, rules: list[EpisodeParseRule]) -> EpisodeRuleTestItem:
    parsed = parse_title(test.title, rules)
    matched = parsed.episode is not None
    passed = matched == test.expected_match
    ok, message, _ = episode_rule_preview_message(parsed, [])
    if not ok and parsed.parse_failure_reason:
        message = parsed.parse_failure_reason
    if test.expected_match and not matched:
        message = f"应该匹配，但未识别：{message}"
    elif not test.expected_match and matched:
        message = f"不应该匹配，但识别为第 {parsed.episode} 集。"
    elif not test.expected_match:
        message = "符合预期：没有识别出集数。"
    return EpisodeRuleTestItem(
        title=test.title,
        expected_match=test.expected_match,
        matched=matched,
        passed=passed,
        parsed_title=parsed,
        message=message,
    )


def _suggest_rule_tests(title: str, pattern: str) -> tuple[list[str], list[str]]:
    negative = [
        "弱弱老师 1080p H.264 AAC",
        "弱弱老师 SRTx2",
        "弱弱老师 2025 1080p",
    ]
    if "EP" in pattern:
        return [
            "弱弱老师 - EP10 [简／繁] (1080p H.264 AAC)",
            "弱弱老师 EP11 1080p",
            "Yowayowa Sensei - EP12",
        ], negative
    if "★" in pattern:
        return [title, "番名★08★1080p"], negative
    if "start" in pattern and "end" in pattern:
        return [title], negative
    return [title], negative


def sync_runtime_settings(store: Store) -> None:
    if tmdb_api_key() is None:
        set_runtime_tmdb_api_key(stored_metadata_settings(store).tmdb_api_key)


def metadata_settings_response(settings: MetadataSettings) -> MetadataSettingsResponse:
    key = tmdb_api_key() or settings.tmdb_api_key
    configured = bool(key)
    return MetadataSettingsResponse(
        tmdb_configured=configured,
        tmdb_api_key_configured=configured,
        tmdb_api_key_masked=mask_secret(key),
        message="TMDB API Key 已配置" if configured else "TMDB API Key 未配置，可在 设置 → 元数据 中配置。",
    )


def stored_ai_settings(store: Store) -> AISettings:
    data = store.get_runtime_config("ai_settings") or {}
    settings = AISettings(**data)
    if settings.provider == "none":
        return settings
    profiles = dict(settings.provider_profiles)
    current = profiles.get(settings.provider)
    if current is None:
        profiles[settings.provider] = AIProviderProfile(
            base_url=settings.base_url,
            model=settings.model,
            api_key=settings.api_key,
        )
    elif settings.api_key and not current.api_key:
        profiles[settings.provider] = current.model_copy(update={"api_key": settings.api_key})
    return settings.model_copy(update={"provider_profiles": profiles})


def stored_search_settings(store: Store) -> SearchSettings:
    data = store.get_config("search_settings") or {}
    return SearchSettings(**data)


def normalize_ai_settings(
    settings: AISettings | AISettingsTestRequest,
    existing_settings: AISettings | None = None,
) -> AISettings:
    provider = settings.provider
    existing = existing_settings or AISettings()
    profiles = dict(existing.provider_profiles)
    if isinstance(settings, AISettings):
        profiles.update(settings.provider_profiles)
    existing_profile = profiles.get(provider)
    existing_base_url = existing_profile.base_url if existing_profile else (existing.base_url if existing.provider == provider else None)
    existing_model = existing_profile.model if existing_profile else (existing.model if existing.provider == provider else None)
    existing_api_key = existing_profile.api_key if existing_profile else (existing.api_key if existing.provider == provider else None)

    requested_base_url = settings.base_url.strip() if settings.base_url and settings.base_url.strip() else existing_base_url
    base_url = normalize_ai_base_url(provider, requested_base_url)
    requested_model = settings.model.strip() if settings.model and settings.model.strip() else existing_model
    model = requested_model or provider_default_model(provider)
    api_key = settings.api_key.strip() if settings.api_key and settings.api_key.strip() else existing_api_key
    smart_subscription = settings.use_ai_for_smart_subscription if isinstance(settings, AISettings) else False
    if isinstance(settings, AISettings) and settings.clear_api_key:
        api_key = None
    if provider == "none":
        return AISettings(
            enabled=False,
            provider="none",
            base_url=None,
            model=None,
            api_key=None,
            use_ai_for_smart_subscription=False,
            provider_profiles=profiles,
        )
    if base_url is None:
        base_url = provider_default_base_url(provider)
    profiles[provider] = AIProviderProfile(base_url=base_url, model=model, api_key=api_key)
    configured = bool(settings.enabled and provider != "none" and base_url and model and api_key)
    return AISettings(
        enabled=settings.enabled,
        provider=provider,
        base_url=base_url,
        model=model,
        api_key=api_key,
        use_ai_for_smart_subscription=bool(smart_subscription and configured),
        provider_profiles=profiles,
    )


def _ai_api_base_url(provider: str, base_url: str | None) -> str | None:
    return normalize_ai_base_url(provider, base_url)


def ai_settings_response(settings: AISettings) -> AISettingsResponse:
    api_key_configured = bool(settings.api_key)
    configured = bool(settings.enabled and settings.provider != "none" and settings.base_url and settings.model and settings.api_key)
    profiles = {
        provider: AIProviderProfileResponse(
            base_url=profile.base_url,
            model=profile.model,
            api_key_configured=bool(profile.api_key),
            api_key_masked=mask_secret(profile.api_key),
        )
        for provider, profile in settings.provider_profiles.items()
        if provider in {"openai_compatible", "xai", "deepseek"}
    }
    label = provider_label(settings.provider)
    return AISettingsResponse(
        enabled=settings.enabled,
        provider=settings.provider,
        base_url=settings.base_url,
        model=settings.model,
        api_key_configured=api_key_configured,
        api_key_masked=mask_secret(settings.api_key),
        use_ai_for_smart_subscription=bool(settings.use_ai_for_smart_subscription and configured),
        configured=configured,
        message=f"{label} 已配置" if configured else "未配置 AI，可在 设置 → AI 辅助分析 中配置",
        provider_profiles=profiles,
    )


def _ai_not_configured_response() -> AITitleAnalysisResponse:
    return AITitleAnalysisResponse(
        ok=False,
        message="未配置 AI，可在 设置 → AI 辅助分析 中配置",
        warnings=["AI 辅助默认关闭；本地解析、可视化规则和订阅刷新仍可正常使用。"],
    )


FINAL_MARKER_RE = re.compile(r"(完结|完|END|Final|Fin)", re.I)
BATCH_MARKER_RE = re.compile(r"(\d{1,3}\s*[-~～]\s*\d{1,3}|合集|全集)")
FORMAT_TAGS = {"MP4", "MKV", "AVI", "WEB-DL", "WEBRIP", "BDRIP", "AAC", "AVC", "HEVC", "H264", "H.264", "H265", "H.265"}
LANGUAGE_TAGS = {"CHS", "CHT", "GB", "BIG5", "简体", "繁体", "简中", "繁中"}


def _string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def _int_or_none(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _float_or_zero(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _bool_or_none(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if value is None:
        return None
    if isinstance(value, str):
        lowered = value.strip().casefold()
        if lowered in {"true", "yes", "1", "是"}:
            return True
        if lowered in {"false", "no", "0", "否", "unknown", "未知", "不确定"}:
            return None if lowered in {"unknown", "未知", "不确定"} else False
    return None


def _bracket_tokens(title: str) -> list[str]:
    return [token.strip() for token in re.findall(r"\[([^\]]+)\]|\(([^\)]+)\)", title) for token in token if token and token.strip()]


def _title_source_tags(raw_title: str, parsed: ParsedAnimeTitle) -> tuple[list[str], list[str]]:
    source_tags: list[str] = []
    format_tags: list[str] = []
    ignored = {parsed.fansub, parsed.resolution, parsed.subtitle_language}
    for token in _bracket_tokens(raw_title):
        if token in ignored:
            continue
        upper = token.upper()
        if token in LANGUAGE_TAGS or upper in LANGUAGE_TAGS:
            continue
        if re.fullmatch(r"\d{1,3}(?:\s*[-~～]\s*\d{1,3})?", token):
            continue
        if upper in FORMAT_TAGS or any(part in FORMAT_TAGS for part in upper.replace(".", "").split()):
            format_tags.append(token)
        source_tags.append(token)
    deduped_source = list(dict.fromkeys(source_tags))
    deduped_format = list(dict.fromkeys(format_tags))
    return deduped_source, deduped_format


def _final_state(raw_title: str, value: Any) -> tuple[bool | None, float]:
    if FINAL_MARKER_RE.search(raw_title):
        return True, 0.95
    parsed = _bool_or_none(value)
    if parsed is True:
        return None, 0.25
    if parsed is False:
        return False, 0.6
    return None, 0.0


def _batch_state(raw_title: str, parsed: ParsedAnimeTitle, value: Any) -> bool:
    if parsed.is_batch:
        return True
    candidate = _bool_or_none(value)
    if candidate is True and BATCH_MARKER_RE.search(raw_title):
        return True
    return False


def _structured_title_analysis(
    raw_title: str,
    data: dict[str, Any] | None,
    *,
    suggested_rule: bool = False,
    message: str | None = None,
    warnings: list[str] | None = None,
) -> AITitleAnalysisResponse:
    parsed = parse_title(raw_title)
    data = data or {}
    source_tags, format_tags = _title_source_tags(raw_title, parsed)
    ai_source_tags = _string_list(data.get("source_tags"))
    ai_format_tags = _string_list(data.get("format_tags"))
    is_final, final_confidence = _final_state(raw_title, data.get("is_final"))
    is_batch = _batch_state(raw_title, parsed, data.get("is_batch"))
    episode = _int_or_none(data.get("episode_number")) or parsed.episode_number or parsed.episode
    episode_start = _int_or_none(data.get("episode_start")) or parsed.episode_start or episode
    episode_end = _int_or_none(data.get("episode_end")) or parsed.episode_end
    anime_title = str(data.get("anime_title") or data.get("title") or parsed.title or "").strip() or None
    fansub = str(data.get("fansub") or parsed.fansub or "").strip() or None
    resolution = str(data.get("resolution") or parsed.resolution or "").strip() or None
    subtitle_language = str(data.get("subtitle_language") or parsed.subtitle_language or "").strip() or None
    confidence = _float_or_zero(data.get("confidence")) or parsed.confidence
    suggested_regex = data.get("suggested_regex") if suggested_rule else None
    if suggested_regex:
        try:
            re.compile(str(suggested_regex))
        except re.error as exc:
            warnings = [*(warnings or []), f"AI 建议正则不可用，已忽略：{exc}"]
            suggested_regex = None
    return AITitleAnalysisResponse(
        ok=True,
        message=message or ("AI 已生成规则草稿，测试确认后再应用。" if suggested_rule else "AI 已解析标题结构，可采用到当前流程。"),
        raw_title=raw_title,
        fansub=fansub,
        anime_title=anime_title,
        anime_title_original=data.get("anime_title_original"),
        anime_title_aliases=_string_list(data.get("anime_title_aliases")),
        episode_number=episode,
        episode_start=episode_start,
        episode_end=episode_end,
        is_batch=is_batch,
        is_final=is_final,
        final_confidence=final_confidence,
        resolution=resolution,
        subtitle_language=subtitle_language,
        source_tags=list(dict.fromkeys([*ai_source_tags, *source_tags])),
        format_tags=list(dict.fromkeys([*ai_format_tags, *format_tags])),
        release_group=str(data.get("release_group") or fansub or "").strip() or None,
        confidence=min(max(confidence, 0), 1),
        reason=data.get("reason"),
        suggested_regex=str(suggested_regex) if suggested_regex else None,
        warnings=warnings or _string_list(data.get("warnings")),
        requires_confirmation=True,
    )


async def _call_ai_title_analysis(settings: AISettings, request: AITitleAnalyzeRequest, *, suggest_rule: bool = False) -> AITitleAnalysisResponse:
    api_base_url = _ai_api_base_url(settings.provider, settings.base_url)
    if not (settings.enabled and settings.provider != "none" and api_base_url and settings.model and settings.api_key):
        return _ai_not_configured_response()
    local_summary = request.local_parse.model_dump(mode="json") if request.local_parse else parse_title(request.title).model_dump(mode="json")
    messages = [
            {
                "role": "system",
                "content": (
                    "你是 Kisetsu 的标题结构分析助手。只分析资源标题文本，输出 JSON。"
                    "不要请求或推断密码、Cookie、下载路径、API Key、qBittorrent 信息。"
                    + (
                        "本次任务是生成一条可测试的集数识别规则草稿。"
                        "必须在 suggested_regex 字段给出 Python 命名捕获组正则，例如 (?P<episode>...)、(?P<start>...)、(?P<end>...)、(?P<final>...)。"
                        "字段：fansub, anime_title, anime_title_original, anime_title_aliases, episode_number, episode_start, episode_end, "
                        "is_batch, is_final, final_confidence, resolution, subtitle_language, source_tags, format_tags, release_group, "
                        "confidence, reason, suggested_regex, warnings。"
                        if suggest_rule
                        else
                        "本次任务只解析标题结构，帮助用户理解番名、集数、分辨率、字幕组等信息，不要生成正则。"
                        "必须返回 JSON 对象，字段：fansub, anime_title, anime_title_original, anime_title_aliases, episode_number, episode_start, episode_end, "
                        "is_batch, is_final, final_confidence, resolution, subtitle_language, source_tags, format_tags, release_group, confidence, reason, warnings。"
                        "只有标题明确出现 完、完结、END、Final、Fin 才把 is_final 标为 true；没有明确标记时 is_final 返回 null。"
                        "只有 01-12、01~12、合集、全集等才把 is_batch 标为 true；单独 - 12 是单集。"
                    )
                ),
            },
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "title": request.title,
                        "subscription_name": request.subscription_name,
                        "aliases": request.aliases,
                        "site": request.site,
                        "local_parse": local_summary,
                    },
                    ensure_ascii=False,
                ),
            },
        ]
    payload = build_chat_completion_payload(settings.provider, settings.model, messages)
    url = ai_endpoint_url(settings.provider, api_base_url, "chat/completions")
    if not url:
        return AITitleAnalysisResponse(
            ok=False,
            message="Base URL 无效",
            warnings=["AI Base URL 必须是有效的 HTTP 或 HTTPS 地址。"],
            error_code="AI_BASE_URL_INVALID",
        )
    try:
        async with httpx.AsyncClient(timeout=ai_request_timeout(settings.provider)) as client:
            response = await client.post(
                url,
                headers={"Authorization": f"Bearer {settings.api_key}", "Content-Type": "application/json"},
                json=payload,
            )
    except httpx.RequestError as exc:
        failure = failure_from_request_error(settings.provider, exc)
        return AITitleAnalysisResponse(ok=False, message=failure.message, warnings=[failure.detail], error_code=failure.code)
    failure = failure_from_response(settings.provider, response)
    if failure:
        return AITitleAnalysisResponse(ok=False, message=failure.message, warnings=[failure.detail], error_code=failure.code)
    try:
        data = extract_chat_completion_content(response)
    except AIProviderFailure as exc:
        return AITitleAnalysisResponse(ok=False, message=exc.message, warnings=[exc.detail], error_code=exc.code)
    warnings = [str(item) for item in data.get("warnings") or []]
    return _structured_title_analysis(
        request.title,
        data,
        suggested_rule=suggest_rule,
        message="AI 已生成规则草稿，测试确认后再应用。" if suggest_rule else "AI 已解析标题结构，可采用到当前流程。",
        warnings=warnings,
    )


async def _fetch_ai_models(request: AIModelListRequest) -> AIModelListResponse:
    if request.provider == "none":
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message="未配置 AI，可在 设置 → AI 辅助分析 中配置", error_code="AI_BASE_URL_INVALID")
    if not request.api_key or not request.api_key.strip():
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message="未配置 API Key，无法获取模型列表", error_code="AI_API_KEY_MISSING")
    url = ai_endpoint_url(request.provider, request.base_url, "models")
    if not url:
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message="Base URL 无效", error_code="AI_BASE_URL_INVALID")
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(30, connect=15)) as client:
            response = await client.get(url, headers={"Authorization": f"Bearer {request.api_key.strip()}"})
    except httpx.RequestError as exc:
        failure = failure_from_request_error(request.provider, exc)
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message=failure.message, error_code=failure.code)
    failure = failure_from_response(request.provider, response)
    if failure:
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message=failure.message, error_code=failure.code)
    try:
        raw_models = extract_model_items(response)
    except AIProviderFailure as exc:
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message=exc.message, error_code=exc.code)
    models = [
        AIModelInfo(
            id=str(item.get("id") or item.get("name") or ""),
            name=item.get("name"),
            owned_by=item.get("owned_by"),
            created=item.get("created"),
        )
        for item in raw_models
        if item.get("id") or item.get("name")
    ]
    models.sort(key=lambda item: item.id)
    selected = request.selected_model if request.selected_model in {item.id for item in models} else (models[0].id if models else request.selected_model)
    if not models:
        return AIModelListResponse(ok=False, models=[], selected_model=request.selected_model, message="获取失败：模型列表为空，可手动填写模型名", error_code="AI_MODEL_LIST_FAILED")
    return AIModelListResponse(ok=True, models=models, selected_model=selected, message=f"已获取 {len(models)} 个模型")


def _site_adapter(site_id: str, site_settings: dict | None = None):
    try:
        return get_site_adapter(site_id, site_settings)
    except TypeError as exc:
        if "positional" not in str(exc) and "argument" not in str(exc):
            raise
        return get_site_adapter(site_id)


def _poster_cache_root() -> Path:
    return DATA_DIR / "cache" / "posters" / "subscriptions"


def _poster_cache_dir(subscription_id: int) -> Path:
    return _poster_cache_root() / str(subscription_id)


def _poster_local_url(subscription_id: int) -> str:
    return f"/api/subscriptions/{subscription_id}/poster"


def _poster_palette_path(subscription_id: int) -> Path:
    return _poster_cache_dir(subscription_id) / "palette.json"


def _poster_extension(content_type: str, poster_url: str) -> str:
    normalized = content_type.split(";", 1)[0].strip().lower()
    if normalized in {"image/jpeg", "image/jpg"}:
        return ".jpg"
    if normalized == "image/png":
        return ".png"
    if normalized == "image/webp":
        return ".webp"
    suffix = Path(urlparse(poster_url).path).suffix.lower()
    return suffix if suffix in {".jpg", ".jpeg", ".png", ".webp"} else ".jpg"


def _cached_subscription_poster_path(subscription_id: int) -> Path | None:
    cache_dir = _poster_cache_dir(subscription_id)
    if not cache_dir.exists():
        return None
    candidates = sorted(
        [item for item in cache_dir.iterdir() if item.is_file() and item.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}],
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def _remove_subscription_poster_cache(subscription_id: int) -> int:
    cache_dir = _poster_cache_dir(subscription_id)
    if not cache_dir.exists():
        return 0
    removed = 0
    for item in cache_dir.iterdir():
        if item.is_file():
            with suppress(OSError):
                item.unlink()
                removed += 1
    with suppress(OSError):
        cache_dir.rmdir()
    return removed


def _hex_color(rgb: tuple[int, int, int]) -> str:
    return "#{:02X}{:02X}{:02X}".format(*rgb)


def _relative_luminance(rgb: tuple[int, int, int]) -> float:
    values: list[float] = []
    for channel in rgb:
        normalized = channel / 255
        values.append(normalized / 12.92 if normalized <= 0.03928 else ((normalized + 0.055) / 1.055) ** 2.4)
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]


def _color_saturation(rgb: tuple[int, int, int]) -> float:
    high = max(rgb) / 255
    low = min(rgb) / 255
    if high == 0:
        return 0
    return (high - low) / high


def _color_distance(left: tuple[int, int, int], right: tuple[int, int, int]) -> float:
    return sum((left[index] - right[index]) ** 2 for index in range(3)) ** 0.5


def _weighted_average(colors: list[tuple[int, int, int]], fallback: tuple[int, int, int]) -> tuple[int, int, int]:
    if not colors:
        return fallback
    return tuple(int(sum(color[index] for color in colors) / len(colors)) for index in range(3))


def _bucket_color(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    return tuple(min(255, max(0, round(channel / 24) * 24)) for channel in rgb)


def _extract_poster_palette(path: Path) -> PosterPalette | None:
    try:
        from PIL import Image
    except Exception as exc:  # pragma: no cover - Pillow is available in packaged builds, but keep fallback safe.
        logger.warning("poster palette skipped: Pillow unavailable: %s", exc)
        return None
    try:
        with Image.open(path) as image:
            image = image.convert("RGB")
            image.thumbnail((96, 144))
            width, height = image.size
            pixels = image.load()
            edge_width = max(2, int(width * 0.16))
            edge_height = max(2, int(height * 0.12))
            edge_pixels: list[tuple[int, int, int]] = []
            all_pixels: list[tuple[int, int, int]] = []
            for y in range(height):
                for x in range(width):
                    rgb = pixels[x, y]
                    all_pixels.append(rgb)
                    if x < edge_width or x >= width - edge_width or y < edge_height:
                        edge_pixels.append(rgb)
    except Exception as exc:
        logger.warning("poster palette extraction failed for %s: %s", path, exc)
        return None

    def usable(rgb: tuple[int, int, int]) -> bool:
        luminance = _relative_luminance(rgb)
        return 0.04 < luminance < 0.94 and _color_saturation(rgb) > 0.12

    candidates = [rgb for rgb in edge_pixels if usable(rgb)]
    if len(candidates) < 12:
        candidates = [rgb for rgb in all_pixels if usable(rgb)]
    if not candidates:
        return None

    buckets: dict[tuple[int, int, int], float] = {}
    for rgb in candidates:
        bucket = _bucket_color(rgb)
        luminance = _relative_luminance(rgb)
        saturation = _color_saturation(rgb)
        weight = 0.45 + saturation * 0.85 + (1 - abs(luminance - 0.42)) * 0.35
        buckets[bucket] = buckets.get(bucket, 0) + weight

    ranked = [item[0] for item in sorted(buckets.items(), key=lambda item: item[1], reverse=True)]
    background = _weighted_average(candidates, ranked[0])
    primary = ranked[0]
    secondary = next((rgb for rgb in ranked[1:] if _color_distance(rgb, primary) > 42), ranked[min(1, len(ranked) - 1)])
    saturated = sorted(ranked, key=lambda rgb: (_color_saturation(rgb), _color_distance(rgb, primary)), reverse=True)
    accent = next((rgb for rgb in saturated if _color_distance(rgb, primary) > 36), primary)
    contrast = "light" if _relative_luminance(background) < 0.42 else "dark"
    return PosterPalette(
        primary=_hex_color(primary),
        secondary=_hex_color(secondary),
        accent=_hex_color(accent),
        background=_hex_color(background),
        text_contrast=contrast,
    )


def _poster_palette_for_path(subscription_id: int, path: Path | None) -> PosterPalette | None:
    if path is None or not path.exists():
        return None
    palette_path = _poster_palette_path(subscription_id)
    if palette_path.exists() and palette_path.stat().st_mtime >= path.stat().st_mtime:
        with suppress(Exception):
            return PosterPalette(**json.loads(palette_path.read_text(encoding="utf-8")))
    palette = _extract_poster_palette(path)
    if palette is not None:
        with suppress(OSError):
            palette_path.parent.mkdir(parents=True, exist_ok=True)
            palette_path.write_text(palette.model_dump_json(), encoding="utf-8")
    return palette


def _poster_palette_from_metadata_rows(rows: list[dict], subscription_id: int) -> PosterPalette | None:
    for row in rows:
        stored_palette = row.get("poster_palette")
        if isinstance(stored_palette, dict):
            with suppress(Exception):
                return PosterPalette(**stored_palette)
        local_path = row.get("local_poster_path")
        if local_path:
            palette = _poster_palette_for_path(subscription_id, Path(local_path))
            if palette is not None:
                return palette
    return _poster_palette_for_path(subscription_id, _cached_subscription_poster_path(subscription_id))


async def _cache_subscription_poster(
    subscription_id: int,
    poster_url: str | None,
    *,
    metadata_source: str | None = None,
    metadata_id: str | None = None,
) -> dict[str, Any] | None:
    if not poster_url:
        return None
    parsed = urlparse(poster_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None
    try:
        async with httpx.AsyncClient(timeout=12, follow_redirects=True) as client:
            response = await client.get(poster_url, headers={"User-Agent": "Kisetsu/0.1"})
            response.raise_for_status()
    except Exception as exc:
        logger.warning("poster cache failed for subscription %s: %s", subscription_id, exc)
        return None
    content_type = response.headers.get("content-type", "")
    if not content_type.lower().startswith("image/") or not response.content:
        logger.warning("poster cache skipped for subscription %s: non-image response %s", subscription_id, content_type)
        return None
    cache_dir = _poster_cache_dir(subscription_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    digest_payload = "|".join(
        [str(subscription_id), metadata_source or "", metadata_id or "", poster_url, str(time.time_ns())]
    )
    filename = f"{hashlib.sha1(digest_payload.encode('utf-8')).hexdigest()[:20]}{_poster_extension(content_type, poster_url)}"
    path = cache_dir / filename
    path.write_bytes(response.content)
    with suppress(OSError):
        _poster_palette_path(subscription_id).unlink()
    palette = _poster_palette_for_path(subscription_id, path)
    return {
        "poster_local_url": _poster_local_url(subscription_id),
        "local_poster_path": str(path),
        "poster_cached_at": datetime.now(timezone.utc).isoformat(),
        "poster_palette": palette.model_dump(mode="json") if palette else None,
    }


def _finalize_subscription_poster_cache(subscription_id: int, keep_path: str | None) -> None:
    cache_dir = _poster_cache_dir(subscription_id)
    if not cache_dir.exists():
        return
    keep = Path(keep_path) if keep_path else None
    for item in cache_dir.iterdir():
        if keep is not None and item == keep:
            continue
        if keep is not None and item == _poster_palette_path(subscription_id):
            continue
        if item.is_file():
            with suppress(OSError):
                item.unlink()
    with suppress(OSError):
        cache_dir.rmdir()


def _discard_staged_subscription_poster(subscription_id: int, staged_path: str | None) -> None:
    if not staged_path:
        return
    with suppress(OSError):
        Path(staged_path).unlink()
    with suppress(OSError):
        _poster_palette_path(subscription_id).unlink()
    with suppress(OSError):
        _poster_cache_dir(subscription_id).rmdir()


@router.get("/sites", response_model=list[SiteInfo])
async def sites(store: Store = Depends(get_store)) -> list[SiteInfo]:
    return list_sites(stored_site_settings(store), managed_site_ids(store))


@router.post("/sites", response_model=SiteInfo)
async def create_site_from_template(
    request: SiteCreateRequest,
    store: Store = Depends(get_store),
) -> SiteInfo:
    normalized_site_id = normalize_site_id(request.site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="暂不支持的资源站点模板")
    current = settings[normalized_site_id]
    save_managed_site_settings(store, normalized_site_id, SiteSettingsUpdate(**{**current.model_dump(mode="json"), "enabled": True}))
    return _site_adapter(normalized_site_id, stored_site_settings(store)).info()


@router.get("/settings/sites", response_model=list[SiteInfo])
async def settings_sites(store: Store = Depends(get_store)) -> list[SiteInfo]:
    return list_sites(stored_site_settings(store), managed_site_ids(store))


@router.delete("/sites/{site_id}", response_model=list[SiteInfo])
@router.delete("/settings/sites/{site_id}", response_model=list[SiteInfo])
async def delete_site_settings(
    site_id: str,
    store: Store = Depends(get_store),
) -> list[SiteInfo]:
    normalized_site_id = normalize_site_id(site_id)
    if normalized_site_id not in default_site_settings():
        raise HTTPException(status_code=404, detail="资源站点不存在")
    if not delete_managed_site_settings(store, normalized_site_id):
        raise HTTPException(status_code=404, detail="资源站点未添加")
    return list_sites(stored_site_settings(store), managed_site_ids(store))


@router.post("/sites/{site_id}/test", response_model=SiteDomainTestResponse)
@router.post("/settings/sites/{site_id}/test", response_model=SiteDomainTestResponse)
async def test_site_domain(
    site_id: str,
    request: SiteDomainTestRequest | None = None,
    store: Store = Depends(get_store),
) -> SiteDomainTestResponse:
    normalized_site_id = normalize_site_id(site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="资源站点不存在")
    adapter = _site_adapter(normalized_site_id, stored_site_settings(store))
    url = (request.url if request and request.url else adapter.base_url).strip().rstrip("/")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="域名格式不正确，请填写以 http:// 或 https:// 开头的完整地址。")
    drain_rate_limit_events(normalized_site_id)
    try:
        if url != adapter.base_url:
            adapter.base_url = url
        ok, message, status_code = await adapter.test_connection()
        events = [event.message for event in drain_rate_limit_events(normalized_site_id)]
    except Exception as exc:
        events = [event.message for event in drain_rate_limit_events(normalized_site_id)]
        return SiteDomainTestResponse(
            ok=False,
            url=url,
            status_code=None,
            message=f"当前域名无法访问：{describe_site_error(exc)}",
            rate_limit_events=events,
        )
    if ok:
        return SiteDomainTestResponse(
            ok=True,
            url=url,
            status_code=status_code,
            message=message,
            rate_limit_events=events,
        )
    return SiteDomainTestResponse(
        ok=False,
        url=url,
        status_code=status_code,
        message=message,
        rate_limit_events=events,
    )


@router.put("/sites/{site_id}", response_model=SiteInfo)
@router.put("/settings/sites/{site_id}", response_model=SiteInfo)
async def update_site_settings(
    site_id: str,
    request: SiteSettingsUpdate,
    store: Store = Depends(get_store),
) -> SiteInfo:
    normalized_site_id = normalize_site_id(site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="资源站点不存在")
    adapter = _site_adapter(normalized_site_id, stored_site_settings(store))
    if request.brush_only and not getattr(adapter, "supports_brush", False):
        raise HTTPException(status_code=400, detail="该站点尚未实现刷流协议，不能设为仅站点刷流")
    current = settings[normalized_site_id].model_dump(mode="json")
    current.update(merge_site_secret_fields(current, request))
    settings[normalized_site_id] = SiteSettingsUpdate(**current)
    save_managed_site_settings(store, normalized_site_id, settings[normalized_site_id])
    return _site_adapter(normalized_site_id, stored_site_settings(store)).info()


@router.post("/sites/{site_id}/mirrors", response_model=SiteInfo)
@router.post("/settings/sites/{site_id}/mirrors", response_model=SiteInfo)
async def add_site_mirror(
    site_id: str,
    request: SiteMirrorRequest,
    store: Store = Depends(get_store),
) -> SiteInfo:
    normalized_site_id = normalize_site_id(site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="资源站点不存在")
    url = request.url.strip().rstrip("/")
    if not url:
        raise HTTPException(status_code=400, detail="镜像地址不能为空")
    current = settings[normalized_site_id]
    mirrors = sorted({*current.mirrors, url})
    settings[normalized_site_id] = SiteSettingsUpdate(**{**current.model_dump(mode="json"), "mirrors": mirrors})
    save_managed_site_settings(store, normalized_site_id, settings[normalized_site_id])
    return _site_adapter(normalized_site_id, stored_site_settings(store)).info()


@router.delete("/sites/{site_id}/mirrors/{mirror_index}", response_model=SiteInfo)
@router.delete("/settings/sites/{site_id}/mirrors/{mirror_index}", response_model=SiteInfo)
async def delete_site_mirror(
    site_id: str,
    mirror_index: int,
    store: Store = Depends(get_store),
) -> SiteInfo:
    normalized_site_id = normalize_site_id(site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="资源站点不存在")
    current = settings[normalized_site_id]
    if mirror_index < 0 or mirror_index >= len(current.mirrors):
        raise HTTPException(status_code=404, detail="镜像地址不存在")
    mirrors = list(current.mirrors)
    removed = mirrors.pop(mirror_index)
    active = current.active_base_url
    if active == removed:
        active = current.primary_url
    settings[normalized_site_id] = SiteSettingsUpdate(**{**current.model_dump(mode="json"), "mirrors": mirrors, "active_base_url": active})
    save_managed_site_settings(store, normalized_site_id, settings[normalized_site_id])
    return _site_adapter(normalized_site_id, stored_site_settings(store)).info()


@router.post("/sites/{site_id}/select-mirror", response_model=SiteInfo)
@router.post("/settings/sites/{site_id}/select-mirror", response_model=SiteInfo)
async def select_site_mirror(
    site_id: str,
    request: SiteMirrorRequest,
    store: Store = Depends(get_store),
) -> SiteInfo:
    normalized_site_id = normalize_site_id(site_id)
    settings = merge_site_settings(stored_site_settings(store))
    if normalized_site_id not in settings:
        raise HTTPException(status_code=404, detail="资源站点不存在")
    current = settings[normalized_site_id]
    url = request.url.strip().rstrip("/")
    allowed = {current.primary_url, *current.mirrors}
    if url not in allowed:
        raise HTTPException(status_code=400, detail="请先把这个地址添加为镜像，再设为启用域名。")
    settings[normalized_site_id] = SiteSettingsUpdate(**{**current.model_dump(mode="json"), "active_base_url": url})
    save_managed_site_settings(store, normalized_site_id, settings[normalized_site_id])
    return _site_adapter(normalized_site_id, stored_site_settings(store)).info()


@router.get("/settings", response_model=AppSettingsResponse)
async def get_settings(store: Store = Depends(get_store)) -> AppSettingsResponse:
    sync_runtime_settings(store)
    metadata = stored_metadata_settings(store)
    return AppSettingsResponse(
        metadata=metadata_settings_response(metadata),
        organize_policy=stored_organize_policy(store),
    )


@router.put("/settings/metadata", response_model=MetadataSettingsResponse)
async def save_metadata_settings(settings: MetadataSettings, store: Store = Depends(get_store)) -> MetadataSettingsResponse:
    existing = stored_metadata_settings(store).tmdb_api_key
    if settings.clear_tmdb_api_key:
        key = None
    else:
        key = settings.tmdb_api_key.strip() if settings.tmdb_api_key and settings.tmdb_api_key.strip() else existing
    store.set_runtime_config("metadata", {"tmdb_api_key": key})
    set_runtime_tmdb_api_key(key)
    return metadata_settings_response(MetadataSettings(tmdb_api_key=key))


@router.delete("/settings/tmdb", response_model=MetadataSettingsResponse)
async def clear_tmdb_settings(store: Store = Depends(get_store)) -> MetadataSettingsResponse:
    store.set_runtime_config("metadata", {"tmdb_api_key": None})
    set_runtime_tmdb_api_key(None)
    return metadata_settings_response(MetadataSettings())


@router.post("/settings/tmdb/test", response_model=QbittorrentTestResponse)
async def test_tmdb_settings(request: TMDBTestRequest | None = None, store: Store = Depends(get_store)) -> QbittorrentTestResponse:
    existing = stored_metadata_settings(store).tmdb_api_key
    candidate = request.tmdb_api_key if request and request.tmdb_api_key else existing
    if not candidate:
        return QbittorrentTestResponse(ok=False, message="TMDB API Key 未配置，可在 设置 → 元数据 中配置。")
    previous = tmdb_api_key()
    set_runtime_tmdb_api_key(candidate)
    try:
        results = await TMDBAdapter().search("Frieren")
    except Exception as exc:
        set_runtime_tmdb_api_key(previous)
        from app.metadata.base import describe_metadata_error

        return QbittorrentTestResponse(ok=False, message=f"TMDB 连接失败：{describe_metadata_error(exc)}")
    set_runtime_tmdb_api_key(previous or existing)
    return QbittorrentTestResponse(ok=True, version=None, message=f"TMDB 连接正常，返回 {len(results)} 个候选")


@router.get("/settings/notification", response_model=NotificationSettingsResponse)
@router.get("/settings/notifications", response_model=NotificationSettingsResponse)
async def get_notification_settings(store: Store = Depends(get_store)) -> NotificationSettingsResponse:
    return notification_settings_response(stored_notification_settings(store))


@router.post("/settings/notification", response_model=NotificationSettingsResponse)
@router.put("/settings/notification", response_model=NotificationSettingsResponse)
@router.post("/settings/notifications", response_model=NotificationSettingsResponse)
@router.put("/settings/notifications", response_model=NotificationSettingsResponse)
async def save_notification_settings(payload: dict, store: Store = Depends(get_store)) -> NotificationSettingsResponse:
    logger.info(
        "update notification settings include_key=%s clear_key=%s",
        bool((payload.get("bark") or {}).get("device_key") or payload.get("bark_device_key")),
        bool((payload.get("bark") or {}).get("clear_device_key") or payload.get("clear_bark_device_key")),
    )
    merged = notification_settings_from_payload(payload, stored_notification_settings(store))
    store.set_runtime_config("notifications", merged.model_dump(mode="json"))
    return notification_settings_response(merged)


@router.post("/settings/notification/test", response_model=NotificationTestResponse)
@router.post("/settings/notifications/test", response_model=NotificationTestResponse)
async def test_notification_settings(
    request: NotificationTestRequest | None = None,
    store: Store = Depends(get_store),
) -> NotificationTestResponse:
    payload = request or NotificationTestRequest()
    event = NotificationEvent(
        event_key=f"test:{datetime.now(timezone.utc).isoformat()}",
        event_type="subscription_new_resource",
        title=payload.title or "Kisetsu 测试通知",
        body=payload.body or "Bark 通知已连接。订阅、下载和整理事件会在这里提醒你。",
        anime_title="Kisetsu",
    )
    return await _notification_service(store).test(event)


@router.get("/settings/ai", response_model=AISettingsResponse)
async def get_ai_settings(store: Store = Depends(get_store)) -> AISettingsResponse:
    return ai_settings_response(stored_ai_settings(store))


@router.put("/settings/ai", response_model=AISettingsResponse)
async def save_ai_settings(settings: AISettings, store: Store = Depends(get_store)) -> AISettingsResponse:
    existing = stored_ai_settings(store)
    normalized = normalize_ai_settings(settings, existing_settings=existing)
    store.set_runtime_config("ai_settings", normalized.model_dump(mode="json"))
    return ai_settings_response(normalized)


@router.post("/settings/ai/test", response_model=QbittorrentTestResponse)
async def test_ai_settings(request: AISettingsTestRequest, store: Store = Depends(get_store)) -> QbittorrentTestResponse:
    settings = normalize_ai_settings(request, existing_settings=stored_ai_settings(store))
    if settings.provider == "none" or not settings.enabled:
        return QbittorrentTestResponse(ok=False, version=None, message="未配置 AI，可在 设置 → AI 辅助分析 中配置")
    if not settings.api_key:
        return QbittorrentTestResponse(ok=False, version=None, message="认证失败")
    if not settings.model:
        return QbittorrentTestResponse(ok=False, version=None, message="模型不可用")
    if not settings.base_url:
        return QbittorrentTestResponse(ok=False, version=None, message="网络错误")
    analysis = await _call_ai_title_analysis(
        settings,
        AITitleAnalyzeRequest(title="测试标题 EP01", local_parse=parse_title("测试标题 EP01")),
        suggest_rule=False,
    )
    if analysis.ok:
        return QbittorrentTestResponse(
            ok=True,
            version=settings.model,
            message=f"{provider_label(settings.provider)} · {settings.model} 连接成功",
        )
    detail = analysis.warnings[0] if analysis.warnings else analysis.message
    return QbittorrentTestResponse(ok=False, version=None, message=f"{analysis.message}：{detail}")


@router.post("/settings/ai/models", response_model=AIModelListResponse)
async def list_ai_models(request: AIModelListRequest, store: Store = Depends(get_store)) -> AIModelListResponse:
    if not request.api_key or not request.api_key.strip():
        existing = stored_ai_settings(store)
        profile = existing.provider_profiles.get(request.provider)
        stored_key = profile.api_key if profile else (existing.api_key if existing.provider == request.provider else None)
        request = request.model_copy(update={"api_key": stored_key})
    return await _fetch_ai_models(request)


@router.post("/title/analyze-ai", response_model=AITitleAnalysisResponse)
async def analyze_title_ai(request: AITitleAnalyzeRequest, store: Store = Depends(get_store)) -> AITitleAnalysisResponse:
    return await _call_ai_title_analysis(stored_ai_settings(store), request, suggest_rule=False)


@router.post("/episode-rules/suggest-ai", response_model=AITitleAnalysisResponse)
async def suggest_episode_rule_ai(request: AITitleAnalyzeRequest, store: Store = Depends(get_store)) -> AITitleAnalysisResponse:
    return await _call_ai_title_analysis(stored_ai_settings(store), request, suggest_rule=True)


@router.post("/episode-rules/explain", response_model=EpisodeRulePreviewResponse)
async def explain_episode_rule_from_marks(request: EpisodeRulePreviewRequest) -> EpisodeRulePreviewResponse:
    return await preview_episode_rule_from_marks(request)


@router.post("/episode-rules/preview-from-marks", response_model=EpisodeRulePreviewResponse)
async def preview_episode_rule_from_marks_public(request: EpisodeRulePreviewRequest) -> EpisodeRulePreviewResponse:
    return await preview_episode_rule_from_marks(request)


@router.post("/episode-rules/test", response_model=EpisodeRuleTestResponse)
async def test_episode_rules_public(request: EpisodeRuleTestRequest, store: Store = Depends(get_store)) -> EpisodeRuleTestResponse:
    return await test_global_episode_rules(request, store)


@router.get("/settings/episode-rules", response_model=EpisodeRuleSettingsResponse)
async def get_episode_rule_settings(store: Store = Depends(get_store)) -> EpisodeRuleSettingsResponse:
    return EpisodeRuleSettingsResponse(
        builtin_rules=builtin_episode_rules(),
        user_rules=stored_global_episode_rules(store),
    )


@router.put("/settings/episode-rules", response_model=EpisodeRuleSettingsResponse)
async def save_episode_rule_settings(
    request: EpisodeRuleSettingsUpdate,
    store: Store = Depends(get_store),
) -> EpisodeRuleSettingsResponse:
    try:
        normalized = [
            normalize_episode_rule(rule, index)
            for index, rule in enumerate(sorted(request.user_rules, key=lambda item: item.priority))
        ]
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    store.set_config("episode_parse_rules", {"user_rules": [rule.model_dump(mode="json") for rule in normalized]})
    return EpisodeRuleSettingsResponse(
        builtin_rules=builtin_episode_rules(),
        user_rules=normalized,
    )


@router.post("/settings/episode-rules/test", response_model=EpisodeRuleTestResponse)
async def test_global_episode_rules(
    request: EpisodeRuleTestRequest,
    store: Store = Depends(get_store),
) -> EpisodeRuleTestResponse:
    rules = request.episode_parse_rules or stored_global_episode_rules(store)
    tests = request.tests or [EpisodeRuleTestCase(title=request.title, expected_match=True)]
    results = [_episode_rule_test_item(item, rules) for item in tests]
    parsed = results[0].parsed_title
    ok, message, _ = episode_rule_preview_message(parsed, [])
    if parsed.parse_rule_name and parsed.parse_rule_name.startswith(("方括号", "星号", "第")):
        message = f"{message}。内置规则已经可以识别这个标题，通常不需要新增规则。"
    if not ok and parsed.parse_failure_reason:
        message = parsed.parse_failure_reason
    return EpisodeRuleTestResponse(ok=all(item.passed for item in results), parsed_title=parsed, message=message, results=results)


@router.post("/settings/episode-rules/tokenize-title", response_model=EpisodeRuleTokenizeResponse)
async def tokenize_episode_rule_title(request: EpisodeRuleTokenizeRequest) -> EpisodeRuleTokenizeResponse:
    return EpisodeRuleTokenizeResponse(title=request.title, tokens=tokenize_episode_title(request.title))


@router.post("/settings/episode-rules/preview-from-marks", response_model=EpisodeRulePreviewResponse)
async def preview_episode_rule_from_marks(request: EpisodeRulePreviewRequest) -> EpisodeRulePreviewResponse:
    tokens = tokenize_episode_title(request.title)
    rule, suggestions, confidence, explanation, warnings = visual_rule_from_marks(request.title, request.marks, name=request.name)
    if rule is None:
        return EpisodeRulePreviewResponse(ok=False, message=suggestions[0], tokens=tokens, suggestions=suggestions, warnings=warnings, marked_tokens=request.marks)
    parsed = _parsed_title_from_visual_marks(request.title, rule, rule.visual_marks, confidence)
    ok, message, final_suggestions = episode_rule_preview_message(parsed, suggestions)
    positive_tests, negative_tests = _suggest_rule_tests(request.title, rule.generated_pattern or rule.pattern)
    return EpisodeRulePreviewResponse(
        ok=ok,
        message=message,
        rule=rule,
        parsed_title=parsed,
        tokens=tokens,
        suggestions=final_suggestions,
        generated_pattern=rule.generated_pattern or rule.pattern,
        confidence=confidence,
        explanation=explanation,
        warnings=warnings,
        marked_tokens=rule.visual_marks,
        positive_tests=positive_tests,
        negative_tests=negative_tests,
    )


@router.put("/settings/organize-policy", response_model=OrganizePolicySettings)
async def save_organize_policy(policy_data: dict, store: Store = Depends(get_store)) -> OrganizePolicySettings:
    try:
        policy = OrganizePolicySettings(**policy_data)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    store.set_config("organize_policy", policy.model_dump(mode="json"))
    return policy


@router.get("/config/qbittorrent", response_model=QbittorrentConfig)
async def get_qbittorrent_config(store: Store = Depends(get_store)) -> QbittorrentConfig:
    config = stored_qbittorrent_config(store) or QbittorrentConfig()
    return QbittorrentConfig(**public_downloader_config(config))


@router.put("/config/qbittorrent", response_model=QbittorrentConfig)
async def save_qbittorrent_config(config: QbittorrentConfig, store: Store = Depends(get_store)) -> QbittorrentConfig:
    merged = merge_downloader_secret(config, stored_qbittorrent_config(store))
    store.set_runtime_config("qbittorrent", merged.model_dump(mode="json", exclude={"password_configured", "clear_password"}))
    _mark_downloader_awaiting_test(store, "qbittorrent")
    return QbittorrentConfig(**public_downloader_config(merged))


@router.get("/config/transmission", response_model=TransmissionConfig)
async def get_transmission_config(store: Store = Depends(get_store)) -> TransmissionConfig:
    config = stored_transmission_config(store) or TransmissionConfig()
    return TransmissionConfig(**public_downloader_config(config))


@router.put("/config/transmission", response_model=TransmissionConfig)
async def save_transmission_config(config: TransmissionConfig, store: Store = Depends(get_store)) -> TransmissionConfig:
    merged = merge_downloader_secret(config, stored_transmission_config(store))
    store.set_runtime_config("transmission", merged.model_dump(mode="json", exclude={"password_configured", "clear_password"}))
    _mark_downloader_awaiting_test(store, "transmission")
    return TransmissionConfig(**public_downloader_config(merged))


def _mark_downloader_awaiting_test(store: Store, downloader_type: str) -> None:
    state = store.get_config("downloader_connection_status") or {}
    state[downloader_type] = {
        "verified": False,
        "version": None,
        "checked_at": None,
        "message": "已配置，尚未测试",
    }
    store.set_config("downloader_connection_status", state)


def _downloader_test_error(exc: BaseException, *, downloader: str) -> tuple[str, str]:
    if isinstance(exc, (httpx.InvalidURL, ValueError)):
        return "resolve", "invalid_address"
    if isinstance(exc, httpx.TimeoutException):
        return "connect", "timeout"
    if isinstance(exc, httpx.ConnectError):
        summary = " ".join(str(item).casefold() for item in (exc, exc.__cause__, exc.__context__) if item)
        if any(token in summary for token in ("name or service", "nodename", "getaddrinfo")):
            return "resolve", "dns_failure"
        if "refused" in summary:
            return "connect", "connection_refused"
        if any(token in summary for token in ("no route", "network is unreachable")):
            return "connect", "no_route"
        return "connect", "connect_error"
    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status in {401, 403}:
            return "authenticate", "authentication_failed"
        if status == 404:
            return "api", "api_not_found"
        return "api", f"http_{status}"
    if isinstance(exc, QbittorrentError):
        if "认证" in str(exc):
            return "authenticate", "authentication_failed"
        return "api", "qbittorrent_error"
    if isinstance(exc, TransmissionError):
        message = str(exc)
        if "地址" in message:
            return "resolve", "invalid_address"
        if "认证" in message:
            return "authenticate", "authentication_failed"
        if "会话" in message:
            return "session", "session_negotiation_failed"
        return "api", "transmission_rpc_error"
    if isinstance(exc, httpx.RequestError):
        return "connect", "request_error"
    return "api", f"{downloader}_error"


def _downloader_statuses(store: Store) -> list[DownloaderStatus]:
    state = store.get_config("downloader_connection_status") or {}
    statuses: list[DownloaderStatus] = []
    for downloader_type in ("qbittorrent", "transmission"):
        saved = state.get(downloader_type) if isinstance(state, dict) else None
        payload = dict(saved) if isinstance(saved, dict) else {}
        payload.update({"downloader": downloader_type, "configured": downloader_configured(store, downloader_type)})
        if not payload["configured"]:
            payload.update({"verified": False, "version": None, "message": "未配置"})
        elif not saved:
            payload.update({"verified": False, "version": None, "message": "已配置，尚未测试"})
        statuses.append(DownloaderStatus(**payload))
    return statuses


@router.get("/config/downloaders", response_model=DownloaderRoutingResponse)
async def get_downloader_routing(store: Store = Depends(get_store)) -> DownloaderRoutingResponse:
    routing = stored_downloader_routing(store)
    return DownloaderRoutingResponse(**routing.model_dump(mode="json"), statuses=_downloader_statuses(store))


@router.put("/config/downloaders", response_model=DownloaderRoutingResponse)
async def save_downloader_routing(
    settings: DownloaderRoutingSettings,
    store: Store = Depends(get_store),
) -> DownloaderRoutingResponse:
    store.set_config("downloader_routing", settings.model_dump(mode="json"))
    return DownloaderRoutingResponse(**settings.model_dump(mode="json"), statuses=_downloader_statuses(store))


@router.get("/qbittorrent/global-limits", response_model=QbittorrentGlobalLimits)
async def get_qbittorrent_global_limits(store: Store = Depends(get_store)) -> QbittorrentGlobalLimits:
    config = stored_qbittorrent_config(store)
    if config is None or not config.username or not config.password:
        raise HTTPException(status_code=400, detail="请先配置 qBittorrent。")
    try:
        return QbittorrentGlobalLimits(**(await QbittorrentClient(config).global_limits()))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=describe_qbittorrent_error(exc)) from exc


@router.put("/qbittorrent/global-limits", response_model=QbittorrentGlobalLimits)
async def update_qbittorrent_global_limits(
    payload: QbittorrentGlobalLimitsUpdate,
    store: Store = Depends(get_store),
) -> QbittorrentGlobalLimits:
    config = stored_qbittorrent_config(store)
    if config is None or not config.username or not config.password:
        raise HTTPException(status_code=400, detail="请先配置 qBittorrent。")
    try:
        current = await QbittorrentClient(config).global_limits()
        client = QbittorrentClient(config)
        try:
            updated = await client.set_global_limits(
                download_limit=payload.download_limit,
                upload_limit=payload.upload_limit,
            )
        except Exception:
            with suppress(Exception):
                await client.set_global_limits(
                    download_limit=current["download_limit"],
                    upload_limit=current["upload_limit"],
                )
            raise
        return QbittorrentGlobalLimits(**updated)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=describe_qbittorrent_error(exc)) from exc


@router.get("/transmission/global-limits", response_model=TransmissionGlobalLimits)
async def get_transmission_global_limits(store: Store = Depends(get_store)) -> TransmissionGlobalLimits:
    config = stored_transmission_config(store)
    if config is None:
        raise HTTPException(status_code=400, detail="请先配置 Transmission。")
    try:
        return TransmissionGlobalLimits(**(await TransmissionClient(config).global_limits()))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=describe_transmission_error(exc)) from exc


@router.put("/transmission/global-limits", response_model=TransmissionGlobalLimits)
async def update_transmission_global_limits(
    payload: TransmissionGlobalLimitsUpdate,
    store: Store = Depends(get_store),
) -> TransmissionGlobalLimits:
    config = stored_transmission_config(store)
    if config is None:
        raise HTTPException(status_code=400, detail="请先配置 Transmission。")
    try:
        client = TransmissionClient(config)
        current = await client.global_limits()
        try:
            updated = await client.set_global_limits(
                download_limit=payload.download_limit,
                upload_limit=payload.upload_limit,
            )
        except Exception:
            with suppress(Exception):
                await client.set_global_limits(**current)
            raise
        return TransmissionGlobalLimits(**updated)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=describe_transmission_error(exc)) from exc


def _organize_target_or_404(target_id: int, store: Store) -> OrganizeTarget:
    data = store.get_organize_target(target_id)
    if not data:
        raise HTTPException(status_code=404, detail="整理目标不存在")
    return OrganizeTarget(**data)


def _enabled_organize_target_or_400(target_id: int | None, store: Store) -> OrganizeTarget | None:
    if target_id is None:
        return None
    target = _organize_target_or_404(target_id, store)
    if not target.enabled:
        raise HTTPException(status_code=400, detail=f"整理目标“{target.name}”已停用，请选择其他目标。")
    return target


def _organize_policy_or_400(data: dict, fallback: OrganizePolicySettings) -> OrganizePolicySettings:
    legacy_payload = {
        key: data.get(key)
        for key in ("delete_task_after_organize", "delete_files_after_organize", "keep_seeding")
        if data.get(key) is not None
    }
    payload = fallback.model_dump(mode="json")
    for key in ("delete_task_after_organize", "delete_files_after_organize", "keep_seeding"):
        payload.pop(key, None)
    if data.get("post_organize_action") is not None:
        payload["post_organize_action"] = data["post_organize_action"]
    elif legacy_payload:
        payload.pop("post_organize_action", None)
        payload.update(legacy_payload)
    else:
        payload["post_organize_action"] = fallback.post_organize_action
    try:
        return OrganizePolicySettings(**payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


def _with_default_organize_target(request: SubscriptionCreate, store: Store) -> SubscriptionCreate:
    data = request.model_dump(mode="json")
    if not data.get("sites"):
        raise HTTPException(status_code=400, detail="请至少选择一个订阅来源站点。")
    if data.get("regex_enabled") and data.get("regex"):
        try:
            re.compile(str(data["regex"]))
        except re.error as exc:
            raise HTTPException(status_code=400, detail=f"正则表达式语法错误：{exc}") from exc
    try:
        parse_episode_filter(data.get("episode_filter"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    policy = stored_organize_policy(store)
    if data.get("organize_target_id") is None:
        default_target = store.default_organize_target()
        if default_target:
            data["organize_target_id"] = int(default_target["id"])
            data["auto_organize"] = policy.auto_organize_by_default
    inherits_organize_policy = data.get("post_organize_action") is None and all(
        data.get(key) is None
        for key in ("delete_task_after_organize", "delete_files_after_organize", "keep_seeding")
    )
    normalized_policy = _organize_policy_or_400(data, policy)
    if inherits_organize_policy:
        data["post_organize_action"] = None
        data["delete_task_after_organize"] = None
        data["delete_files_after_organize"] = None
        data["keep_seeding"] = None
    else:
        data["post_organize_action"] = normalized_policy.post_organize_action
        data["delete_task_after_organize"] = normalized_policy.delete_task_after_organize
        data["delete_files_after_organize"] = normalized_policy.delete_files_after_organize
        data["keep_seeding"] = normalized_policy.keep_seeding
    _enabled_organize_target_or_400(data.get("organize_target_id"), store)
    return SubscriptionCreate(**data)


def _default_organize_target_id(store: Store) -> int | None:
    default_target = store.default_organize_target()
    return int(default_target["id"]) if default_target else None


def _download_organize_target_id(request: DownloadRequest, store: Store) -> int | None:
    target_id = request.organize_target_id
    if target_id is None:
        target_id = _default_organize_target_id(store)
    _enabled_organize_target_or_400(target_id, store)
    return target_id


def _organize_target_validation(target: OrganizeTarget) -> OrganizeTargetValidateResponse:
    path = Path(target.path).expanduser()
    is_absolute = path.is_absolute()
    path_exists = path.exists()
    is_directory = path.is_dir()
    if is_absolute and path_exists and is_directory:
        message = f"整理目标“{target.name}”路径可用"
        ok = True
    elif not is_absolute:
        message = "整理目标路径必须是绝对路径。"
        ok = False
    elif not path_exists:
        message = "整理目标路径不存在，请检查后再使用。"
        ok = False
    else:
        message = "整理目标路径不是文件夹，请选择媒体库目录。"
        ok = False
    return OrganizeTargetValidateResponse(
        ok=ok,
        target_id=target.id,
        message=message,
        path_exists=path_exists,
        is_directory=is_directory,
        is_absolute=is_absolute,
    )


@router.get("/organize/targets", response_model=list[OrganizeTarget])
async def list_organize_targets(store: Store = Depends(get_store)) -> list[OrganizeTarget]:
    return [OrganizeTarget(**item) for item in store.list_organize_targets()]


@router.post("/organize/targets", response_model=OrganizeTarget)
async def create_organize_target(
    request: OrganizeTargetCreate,
    store: Store = Depends(get_store),
) -> OrganizeTarget:
    created = store.create_organize_target(request.model_dump(mode="json"))
    return OrganizeTarget(**created)


@router.put("/organize/targets/{target_id}", response_model=OrganizeTarget)
async def update_organize_target(
    target_id: int,
    request: OrganizeTargetUpdate,
    store: Store = Depends(get_store),
) -> OrganizeTarget:
    updated = store.update_organize_target(target_id, request.model_dump(mode="json"))
    if not updated:
        raise HTTPException(status_code=404, detail="整理目标不存在")
    return OrganizeTarget(**updated)


@router.delete("/organize/targets/{target_id}")
async def delete_organize_target(target_id: int, store: Store = Depends(get_store)) -> dict[str, bool | str]:
    target = _organize_target_or_404(target_id, store)
    if not store.delete_organize_target(target_id):
        raise HTTPException(status_code=404, detail="整理目标不存在")
    return {"ok": True, "message": f"已删除整理目标“{target.name}”"}


@router.post("/organize/targets/{target_id}/set-default", response_model=OrganizeTarget)
async def set_default_organize_target(target_id: int, store: Store = Depends(get_store)) -> OrganizeTarget:
    updated = store.set_default_organize_target(target_id)
    if not updated:
        raise HTTPException(status_code=404, detail="整理目标不存在")
    return OrganizeTarget(**updated)


@router.post("/organize/targets/{target_id}/validate", response_model=OrganizeTargetValidateResponse)
async def validate_organize_target(
    target_id: int,
    store: Store = Depends(get_store),
) -> OrganizeTargetValidateResponse:
    return _organize_target_validation(_organize_target_or_404(target_id, store))


@router.post("/qbittorrent/test", response_model=QbittorrentTestResponse)
async def test_qbittorrent(config: QbittorrentConfig | None = None, store: Store = Depends(get_store)) -> QbittorrentTestResponse:
    effective = merge_downloader_secret(config, stored_qbittorrent_config(store)) if config else stored_qbittorrent_config(store)
    if effective is None or not effective.username or not effective.password:
        return QbittorrentTestResponse(
            ok=False,
            downloader="qbittorrent",
            stage="authenticate",
            error_code="credentials_missing",
            message="qBittorrent 用户名或密码未配置",
        )
    try:
        version = await QbittorrentClient(effective).test_connection()
        state = store.get_config("downloader_connection_status") or {}
        state["qbittorrent"] = {"verified": True, "stage": "version", "error_code": None, "version": version, "checked_at": datetime.now(timezone.utc).isoformat(), "message": "连接成功"}
        store.set_config("downloader_connection_status", state)
        return QbittorrentTestResponse(
            ok=True,
            downloader="qbittorrent",
            stage="version",
            version=version,
            message="qBittorrent 连接成功",
        )
    except Exception as exc:
        message = f"qBittorrent 连接失败：{describe_qbittorrent_error(exc)}"
        stage, error_code = _downloader_test_error(exc, downloader="qbittorrent")
        state = store.get_config("downloader_connection_status") or {}
        state["qbittorrent"] = {"verified": False, "stage": stage, "error_code": error_code, "checked_at": datetime.now(timezone.utc).isoformat(), "message": message}
        store.set_config("downloader_connection_status", state)
        return QbittorrentTestResponse(
            ok=False,
            downloader="qbittorrent",
            stage=stage,
            error_code=error_code,
            message=message,
        )


@router.post("/transmission/test", response_model=TransmissionTestResponse)
async def test_transmission(config: TransmissionConfig | None = None, store: Store = Depends(get_store)) -> TransmissionTestResponse:
    effective = merge_downloader_secret(config, stored_transmission_config(store)) if config else stored_transmission_config(store)
    if effective is None or not effective.base_url:
        return TransmissionTestResponse(
            ok=False,
            downloader="transmission",
            stage="resolve",
            error_code="address_missing",
            message="Transmission RPC 地址未配置",
        )
    try:
        client = TransmissionClient(effective)
        info = await client.session_info()
        version = str(info.get("version") or "未知")
        rpc_version = int(info.get("rpc-version")) if info.get("rpc-version") is not None else None
        state = store.get_config("downloader_connection_status") or {}
        state["transmission"] = {"verified": True, "stage": "version", "error_code": None, "version": version, "checked_at": datetime.now(timezone.utc).isoformat(), "message": "连接成功"}
        store.set_config("downloader_connection_status", state)
        return TransmissionTestResponse(
            ok=True,
            downloader="transmission",
            stage="version",
            version=version,
            rpc_version=rpc_version,
            message="Transmission 连接成功",
        )
    except Exception as exc:
        message = f"Transmission 连接失败：{describe_transmission_error(exc)}"
        stage, error_code = _downloader_test_error(exc, downloader="transmission")
        state = store.get_config("downloader_connection_status") or {}
        state["transmission"] = {"verified": False, "stage": stage, "error_code": error_code, "checked_at": datetime.now(timezone.utc).isoformat(), "message": message}
        store.set_config("downloader_connection_status", state)
        return TransmissionTestResponse(
            ok=False,
            downloader="transmission",
            stage=stage,
            error_code=error_code,
            message=message,
        )


@router.post("/search", response_model=SearchResponse)
async def search(request: SearchRequest, store: Store = Depends(get_store)) -> SearchResponse:
    settings = stored_search_settings(store)
    results, warnings, diagnostics = await search_multi_site(
        request.keyword,
        request.sites,
        start_page=request.page or 1,
        max_pages=request.max_pages,
        page_size=request.page_size,
        site_settings=stored_site_settings(store),
        deduplicate=request.deduplicate,
        stop_when_no_new_results=request.stop_when_no_new_results,
        timeout_seconds=request.timeout_seconds or settings.site_timeout_seconds,
    )
    raw_count = diagnostics.total_fetched
    display_results = [enrich_search_result(result) for result in results[: request.limit]]
    if len(results) > request.limit:
        warnings.append(f"结果过多，本次仅显示前 {request.limit} 条，请缩小关键词后再试。")
    return SearchResponse(
        results=display_results,
        warnings=warnings,
        raw_count=raw_count,
        display_count=len(display_results),
        deduplicated_count=max(0, raw_count - len(results)) if request.deduplicate else 0,
        pages_fetched=diagnostics.pages_fetched,
        total_fetched=diagnostics.total_fetched,
        total_unique=diagnostics.total_unique,
        reached_max_pages=diagnostics.reached_max_pages,
        completed_all_accessible_pages=diagnostics.completed_all_accessible_pages,
        reached_internal_safety_limit=diagnostics.reached_internal_safety_limit,
        has_more=diagnostics.has_more,
        diagnostics=diagnostics if request.include_diagnostics else None,
    )


@router.get("/mikan-project/settings", response_model=MikanProjectSettings)
async def get_mikan_project_settings(store: Store = Depends(get_store)) -> MikanProjectSettings:
    return stored_mikan_project_settings(store)


@router.put("/mikan-project/settings", response_model=MikanProjectSettings)
async def update_mikan_project_settings(settings: MikanProjectSettings, store: Store = Depends(get_store)) -> MikanProjectSettings:
    return save_mikan_project_settings(store, settings)


@router.get("/mikan-project/season", response_model=MikanProjectSeasonResponse)
async def get_mikan_project_season(store: Store = Depends(get_store)) -> MikanProjectSeasonResponse:
    cached = load_cached_mikan_project_season(store)
    settings = stored_mikan_project_settings(store)
    if cached and not mikan_project_cache_is_stale(cached, settings):
        return cached
    try:
        return await refresh_mikan_project_season(store)
    except Exception as exc:
        if cached:
            warnings = [*cached.warnings, f"刷新失败，已保留旧数据：{describe_site_error(exc)}"]
            return cached.model_copy(update={"warnings": warnings, "settings": settings})
        raise HTTPException(status_code=502, detail=f"获取番组日历失败：{describe_site_error(exc)}")


@router.post("/mikan-project/season/refresh", response_model=MikanProjectSeasonResponse)
async def force_refresh_mikan_project_season(store: Store = Depends(get_store)) -> MikanProjectSeasonResponse:
    cached = load_cached_mikan_project_season(store)
    settings = stored_mikan_project_settings(store)
    try:
        return await refresh_mikan_project_season(store)
    except Exception as exc:
        if cached:
            warnings = [*cached.warnings, f"强制刷新失败，已保留旧数据：{describe_site_error(exc)}"]
            return cached.model_copy(update={"warnings": warnings, "settings": settings})
        raise HTTPException(status_code=502, detail=f"获取番组日历失败：{describe_site_error(exc)}")


@router.get("/mikan-project/anime/{bangumi_id}/resources", response_model=MikanProjectResourcesResponse)
async def get_mikan_project_anime_resources(bangumi_id: str, store: Store = Depends(get_store)) -> MikanProjectResourcesResponse:
    return await fetch_mikan_project_resources(store, bangumi_id)


@router.get("/mikan-project/posters/{bangumi_id}")
async def get_mikan_project_poster(bangumi_id: str, store: Store = Depends(get_store)) -> FileResponse:
    path = mikan_project_poster_path(bangumi_id)
    if path is None:
        try:
            path = await cache_mikan_project_poster(store, bangumi_id)
        except Exception as exc:
            logger.warning("mikan project poster cache failed bangumi_id=%s: %s", bangumi_id, exc)
            path = None
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Mikan Project 海报不存在或暂时无法加载。")
    return FileResponse(path)


@router.get("/settings/search", response_model=SearchSettings)
async def get_search_settings(store: Store = Depends(get_store)) -> SearchSettings:
    return stored_search_settings(store)


@router.put("/settings/search", response_model=SearchSettings)
async def save_search_settings(settings: SearchSettings, store: Store = Depends(get_store)) -> SearchSettings:
    store.set_config("search_settings", settings.model_dump(mode="json"))
    return settings


@router.post("/downloads", response_model=DownloadResponse)
async def add_download(request: DownloadRequest, store: Store = Depends(get_store)) -> DownloadResponse:
    url = request.result.magnet_url or request.result.download_url
    if not url:
        raise HTTPException(status_code=400, detail="搜索结果没有可下载链接")
    source = normalize_site_id(request.result.source)
    if source in default_site_settings():
        adapter = get_site_adapter(source, stored_site_settings(store))
        restriction = site_usage_restriction(adapter, "manual_download", respect_site_enabled=False)
        if restriction and restriction[0] == "site_brush_only":
            raise HTTPException(status_code=400, detail=restriction[1])
    organize_target_id = _download_organize_target_id(request, store)
    existing = store.get_history_by_fingerprint(fingerprint_result(request.result))
    if existing and existing["status"] == "queued":
        if request.dry_run:
            return DownloadResponse(
                ok=True,
                message="资源已提交过，试运行未改变下载状态",
                history_id=existing["id"],
                organize_target_id=organize_target_id,
            )
        return DownloadResponse(
            ok=True,
            message="资源已提交过，已跳过重复下载",
            history_id=existing["id"],
                organize_target_id=organize_target_id,
            )
    if request.dry_run:
        selected_type = request.downloader_type or ("qbittorrent" if request.qbittorrent else stored_downloader_routing(store).manual_downloader)
        dry_config = stored_transmission_config(store) if selected_type == "transmission" else (request.qbittorrent or stored_qbittorrent_config(store))
        dry_save_path = _download_save_path(request.save_path or (dry_config.default_save_path if dry_config else None), parse_title(request.result.title).title or request.result.title)
        history_id = _record_download_history(store, request.result, subscription_id=None, status="dry_run", save_path=dry_save_path, downloader_type=selected_type)
        return DownloadResponse(
            ok=True,
            message="已记录试运行，不会提交真实下载",
            history_id=history_id,
            organize_target_id=organize_target_id,
        )
    downloader_type = request.downloader_type or ("qbittorrent" if request.qbittorrent else stored_downloader_routing(store).manual_downloader)
    if request.qbittorrent is not None:
        config = merge_downloader_secret(request.qbittorrent, stored_qbittorrent_config(store))
        client = QbittorrentClient(config)
    else:
        try:
            client = _configured_downloader_client(store, downloader_type)
        except Exception as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        config = stored_transmission_config(store) if downloader_type == "transmission" else stored_qbittorrent_config(store)
    if config is None:
        raise HTTPException(status_code=400, detail=f"{downloader_display_name(downloader_type)} 尚未配置")
    base_save_path = request.save_path or config.default_save_path
    effective_save_path = _download_save_path(base_save_path, parse_title(request.result.title).title or request.result.title)
    try:
        category = request.category or (config.default_category if isinstance(config, QbittorrentConfig) else None)
        default_tags = config.default_tags if isinstance(config, QbittorrentConfig) else config.default_labels
        add_result = await submit_result_to_downloader(
            client,
            request.result,
            save_path=effective_save_path,
            category=category,
            tags=request.tags or default_tags,
            site_settings=stored_site_settings(store),
        )
    except Exception as exc:
        error_message = describe_downloader_error(downloader_type, exc)
        await _notification_service(store).send_best_effort(download_failed_event(store, None, request.result, error_message))
        raise HTTPException(status_code=502, detail=f"{downloader_display_name(downloader_type)} 添加任务失败：{error_message}") from exc
    history_id = _record_download_history(
        store,
        request.result,
        subscription_id=None,
        status="queued",
        save_path=effective_save_path,
        downloader_type=downloader_type,
        remote_task_id=add_result.remote_task_id,
        torrent_hash=add_result.torrent_hash,
        torrent_name=add_result.torrent_name,
    )
    await _remember_submitted_torrent(
        client,
        store,
        history_id,
        add_result=add_result,
        downloader_type=downloader_type,
    )
    if not add_result.duplicate:
        notification_size = resource_total_size_bytes(request.result) or add_result.content_size or await confirmed_task_size_bytes(client, add_result)
        event = download_started_event(
            store,
            None,
            request.result,
            history_id,
            effective_save_path,
            size_bytes=notification_size,
            downloader_type=downloader_type,
        )
        await send_or_defer_size_notification(
            store,
            event,
            [history_size_target(history_id, notification_size)],
        )
    return DownloadResponse(
        ok=True,
        message=(
            f"{downloader_display_name(downloader_type)} 任务已存在，已完成映射"
            if add_result.duplicate
            else f"已提交到 {downloader_display_name(downloader_type)}"
        ),
        history_id=history_id,
        organize_target_id=organize_target_id,
    )


def _metadata_title_label_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"[\s/／|｜·・,，.。:：;；_\\-]+", "", normalized)


def _split_metadata_title_label(value: str) -> list[str]:
    return [part.strip() for part in re.split(r"\s*(?:/|／|\||｜)\s*", value) if part.strip()]


def _metadata_title_labels(rows: list[dict]) -> list[str]:
    labels: list[str] = []
    seen: set[str] = set()
    for item in rows:
        candidates: list[str] = []
        for raw_value in (
            item.get("selected_title"),
            item.get("chinese_title"),
            item.get("original_title"),
            *(item.get("aliases") or []),
        ):
            if raw_value:
                candidates.extend(_split_metadata_title_label(str(raw_value)))
        if not candidates and item.get("bangumi_id"):
            candidates = [f"Bangumi {item['bangumi_id']}"]
        elif not candidates and item.get("tmdb_id"):
            candidates = [f"TMDB {item['tmdb_id']}"]
        for candidate in candidates:
            key = _metadata_title_label_key(candidate)
            if not key or key in seen:
                continue
            seen.add(key)
            labels.append(candidate)
    return labels


def _subscription_progress_counts(
    subscription: Subscription,
    matches: list[SubscriptionMatch],
    history: list[DownloadHistory],
    store: Store,
) -> tuple[int, int, int]:
    coverage = _subscription_coverage_summary(subscription, matches, history, store)
    return (coverage.total_episodes, coverage.downloaded_count, coverage.organized_count)


def _episode_ranges(values: set[int]) -> list[str]:
    if not values:
        return []
    ranges: list[str] = []
    ordered = sorted(values)
    start = previous = ordered[0]
    for value in ordered[1:]:
        if value == previous + 1:
            previous = value
            continue
        ranges.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = value
    ranges.append(str(start) if start == previous else f"{start}-{previous}")
    return ranges


def _subscription_coverage_summary(
    subscription: Subscription,
    matches: list[SubscriptionMatch],
    history: list[DownloadHistory],
    store: Store,
    media_index: _EpisodeMediaIndex | None = None,
    catalog_total_episodes: int | None = None,
) -> SubscriptionCoverageSummary:
    history_by_fingerprint = {item.fingerprint: item for item in history}
    preview_keys = _organize_preview_keys(store)
    done_keys = _organize_done_keys(store)
    catalog_total = catalog_total_episodes
    if catalog_total is None:
        catalog_total = subscription.total_episodes or subscription.metadata_episode_count
    target_total, skipped_before_start = shared_subscription_target_episode_counts(subscription, catalog_total)
    downloaded_episodes: set[int] = set()
    organized_episodes: set[int] = set()
    has_batch_download = False
    has_batch_organized = False
    batch_ranges: set[int] = set()

    for match in matches:
        covered = {
            episode
            for episode in _subscription_logical_episode_numbers(subscription, match.parsed_title)
            if shared_subscription_episode_in_target_scope(subscription, episode)
            and (catalog_total is None or episode <= catalog_total)
        }
        if not covered:
            continue
        is_batch = match.parsed_title.resource_type == "batch" or match.parsed_title.is_batch or len(covered) > 1
        if is_batch:
            batch_ranges.update(covered)
        history_item = history_by_fingerprint.get(match.fingerprint)
        organize_status = _organize_preview_status(match, preview_keys, done_keys)
        if history_item and history_item.organize_status == "已整理":
            organize_status = "已整理"
        derived_status, _ = _resource_derived_status(history_item, organize_status)
        if _history_covers_download(history_item, derived_status):
            downloaded_episodes.update(covered)
            has_batch_download = has_batch_download or is_batch
        if _history_covers_organize(history_item, organize_status, derived_status):
            organized_episodes.update(covered)
            has_batch_organized = has_batch_organized or is_batch

    if media_index is not None:
        filesystem_episodes = {
            episode
            for (_season, episode), state in media_index.states.items()
            if state.status == "已整理"
            and shared_subscription_episode_in_target_scope(subscription, episode)
            and (catalog_total is None or episode <= catalog_total)
        }
        if (
            not media_index.target_available
            and media_index.unavailable_reason == "整理目标存储暂时不可访问"
        ):
            target_season = subscription.season if subscription.season is not None else 1
            filesystem_episodes.update(
                episode
                for (season, episode) in media_index.prior_organized_keys
                if season == target_season
                and shared_subscription_episode_in_target_scope(subscription, episode)
                and (catalog_total is None or episode <= catalog_total)
            )
        downloaded_episodes.update(filesystem_episodes)
        organized_episodes.update(filesystem_episodes)

    batch_status_label = None
    if has_batch_organized and batch_ranges:
        batch_status_label = f"合集已整理 · 覆盖 {', '.join(_episode_ranges(batch_ranges))}"
    elif has_batch_download and batch_ranges:
        batch_status_label = f"合集已下载 · 覆盖 {', '.join(_episode_ranges(batch_ranges))}"
    return SubscriptionCoverageSummary(
        total_episodes=target_total or 0,
        catalog_total_episodes=catalog_total,
        target_total_episodes=target_total,
        skipped_before_start=skipped_before_start,
        downloaded_count=len(downloaded_episodes),
        organized_count=len(organized_episodes),
        downloaded_ranges=_episode_ranges(downloaded_episodes),
        organized_ranges=_episode_ranges(organized_episodes),
        has_batch_download=has_batch_download,
        has_batch_organized=has_batch_organized,
        batch_status_label=batch_status_label,
    )


def _format_episode_range_label(values: set[int], *, season_number: int | None = None) -> str:
    if not values:
        return "-"
    start = min(values)
    end = max(values)
    if season_number is not None:
        if start == end:
            return f"S{season_number:02d}E{start:02d}"
        return f"S{season_number:02d}E{start:02d}-E{end:02d}"
    return str(start) if start == end else f"{start}-{end}"


def _covered_episode_numbers(
    episode: int | None,
    episode_start: int | None,
    episode_end: int | None,
    *,
    max_span: int = 200,
) -> set[int]:
    return shared_covered_episode_numbers(
        episode,
        episode_start,
        episode_end,
        max_span=max_span,
    )


def _subscription_logical_episode_numbers(
    subscription: Subscription,
    parsed: ParsedAnimeTitle,
) -> set[int]:
    return shared_subscription_logical_episode_numbers(subscription, parsed)


def _episode_mapping_payload(subscription: Subscription, parsed: ParsedAnimeTitle) -> dict[str, Any]:
    raw = _covered_episode_numbers(parsed.episode, parsed.episode_start, parsed.episode_end)
    logical = _subscription_logical_episode_numbers(subscription, parsed)
    offset = subscription.episode_offset if raw and logical and raw != logical else 0
    season_number = parsed.season or subscription.season or 1
    label = None
    if offset != 0:
        label = (
            f"{_format_episode_range_label(raw, season_number=season_number)} → "
            f"{_format_episode_range_label(logical, season_number=season_number)} · {offset:+d}"
        )
    return {
        "logical_episode_start": min(logical) if logical else None,
        "logical_episode_end": max(logical) if logical else None,
        "episode_offset_applied": offset,
        "episode_mapping_label": label,
    }


def _subscription_match_with_episode_mapping(subscription: Subscription, match: SubscriptionMatch) -> SubscriptionMatch:
    return match.model_copy(update=_episode_mapping_payload(subscription, match.parsed_title))


def _history_covers_download(history: DownloadHistory | None, derived_status: str) -> bool:
    downloaded_statuses = {
        "下载完成，待整理",
        "已整理",
        "已整理并移除任务",
        "已停止做种",
    }
    if derived_status in downloaded_statuses:
        return True
    if history is None:
        return False
    if history.status in {"completed", "organized", "organized_task_removed", "seeding_stopped"}:
        return True
    return bool(history.qbittorrent and history.qbittorrent.progress is not None and history.qbittorrent.progress >= 0.999)


def _history_covers_organize(
    history: DownloadHistory | None,
    organize_status: str,
    derived_status: str,
) -> bool:
    if organize_status == "已整理" or derived_status in {"已整理", "已整理并移除任务", "已停止做种"}:
        return True
    return bool(history and history.status in {"organized", "organized_task_removed", "seeding_stopped"})


INFO_REFRESH_PREFIXES = (
    "抓取 ",
    "使用 mikan bangumi id=",
    "mikan Bangumi：",
    "mikan 总集数：",
)

ERROR_REFRESH_MARKERS = (
    "失败",
    "错误",
    "无法",
    "未配置",
    "缺少",
    "冲突",
    "不存在",
    "提交失败",
    "读取失败",
    "网络",
    "认证",
)


def _classify_refresh_messages(messages: list[str]) -> tuple[str | None, list[str], list[str], list[str]]:
    summary: str | None = None
    logs: list[str] = []
    warnings: list[str] = []
    errors: list[str] = []
    for message in messages:
        text = str(message).strip()
        if not text:
            continue
        if summary is None and text.startswith("抓取 "):
            summary = text
            logs.append(text)
            continue
        if text.startswith(INFO_REFRESH_PREFIXES) or "已按单页结果处理" in text or "只返回当前结果页" in text:
            logs.append(text)
            continue
        if text.startswith("订阅已停用"):
            logs.append(text)
            continue
        if any(marker in text for marker in ERROR_REFRESH_MARKERS):
            errors.append(text)
        else:
            warnings.append(text)
    if summary is None and logs:
        summary = logs[0]
    return summary, logs, warnings, errors


def _refresh_history_model(row: dict) -> SubscriptionRefreshHistory:
    summary, logs, warnings, errors = _classify_refresh_messages(list(row.get("warnings") or []))
    payload = dict(row)
    payload["summary"] = summary
    payload["logs"] = logs
    payload["warnings"] = warnings
    payload["errors"] = errors
    return SubscriptionRefreshHistory(**payload)


def _subscription_latest_status(
    refresh_history: list[SubscriptionRefreshHistory],
    matches: list[SubscriptionMatch],
) -> tuple[datetime | None, str | None, str | None]:
    latest_refresh_at = refresh_history[0].created_at if refresh_history else max((item.last_seen_at for item in matches), default=None)
    latest_summary = refresh_history[0].summary if refresh_history else None
    latest_error = None
    if refresh_history and refresh_history[0].errors:
        latest_error = "；".join(refresh_history[0].errors[:3])
    elif any(item.status == "error" for item in matches):
        latest_error = "存在提交失败的匹配条目"
    return latest_refresh_at, latest_summary, latest_error


def _subscription_list_item(data: dict, store: Store, organized_times: dict[int, str] | None = None) -> SubscriptionListItem:
    subscription = Subscription(**data)
    all_matches = _subscription_match_models(store.list_subscription_matches(subscription.id))
    history = _download_history_models(store.list_history(subscription_id=subscription.id))
    current_matches = _subscription_matches_with_current_size_bounds(subscription, all_matches)
    current_match_ids = {match.id for match in current_matches}
    historical_fingerprints = {item.fingerprint for item in history}
    matches = [
        match
        for match in all_matches
        if match.id in current_match_ids or match.fingerprint in historical_fingerprints
    ]
    refresh_history = _subscription_refresh_history_models(store.list_subscription_refresh_history(subscription.id, limit=1))
    metadata_rows = store.list_metadata_bindings_for_target("subscription", str(subscription.id), limit=10)
    current_metadata_rows = metadata_rows[:1]
    poster_url, poster_local_url = _poster_fields_from_metadata_rows(current_metadata_rows, subscription.id)
    poster_palette = _poster_palette_from_metadata_rows(current_metadata_rows, subscription.id)
    metadata_bindings = _metadata_binding_records(current_metadata_rows)
    plex_mappings = _subscription_detail_plex_mappings(metadata_bindings, store)
    mapping = _mapping_for_subscription(subscription, metadata_bindings, plex_mappings)
    media_index = _build_episode_media_index(
        subscription,
        _media_target_for_subscription(subscription, store),
        mapping,
        store,
    )
    catalog_total, _catalog_source = _subscription_total_episodes(subscription, metadata_bindings)
    coverage = _subscription_coverage_summary(
        subscription,
        matches,
        history,
        store,
        media_index,
        catalog_total_episodes=catalog_total,
    )
    latest_refresh_at, latest_refresh_summary, latest_error = _subscription_latest_status(refresh_history, matches)
    latest_organized_at = _subscription_latest_organized_at(subscription.id, store, organized_times)
    payload = subscription.model_dump(mode="json")
    payload.update(
        {
            "matched_count": len(current_matches),
            "queued_count": sum(1 for item in current_matches if item.status == "queued"),
            "skipped_count": sum(1 for item in current_matches if item.status == "skipped"),
            "error_count": sum(1 for item in current_matches if item.status == "error"),
            "episode_count": coverage.total_episodes,
            "downloaded_count": coverage.downloaded_count,
            "organized_count": coverage.organized_count,
            "latest_refresh_at": latest_refresh_at,
            "latest_refresh_summary": latest_refresh_summary,
            "latest_organized_at": latest_organized_at,
            "latest_error": latest_error,
            "metadata_binding_count": len(metadata_rows),
            "metadata_titles": _metadata_title_labels(current_metadata_rows)[:3],
            "poster_url": poster_url,
            "poster_local_url": poster_local_url,
            "poster_palette": poster_palette.model_dump(mode="json") if poster_palette else None,
            "coverage": coverage.model_dump(mode="json"),
        }
    )
    return SubscriptionListItem(**payload)


def _poster_fields_from_metadata_rows(rows: list[dict], subscription_id: int) -> tuple[str | None, str | None]:
    poster_url = None
    poster_local_url = None
    for row in rows:
        poster_url = poster_url or row.get("poster_url")
        local_path = row.get("local_poster_path")
        if local_path and Path(local_path).exists():
            poster_local_url = row.get("poster_local_url")
        if poster_url and poster_local_url:
            break
    if poster_url and not poster_local_url and _cached_subscription_poster_path(subscription_id) is not None:
        poster_local_url = _poster_local_url(subscription_id)
    return poster_url, poster_local_url


@router.get("/subscriptions", response_model=list[SubscriptionListItem])
async def list_subscriptions(store: Store = Depends(get_store)) -> list[SubscriptionListItem]:
    organized_times = store.latest_successful_organize_times()
    return [_subscription_list_item(item, store, organized_times) for item in store.list_subscriptions()]


@router.get("/subscription-groups", response_model=list[SubscriptionGroup])
async def list_subscription_groups(store: Store = Depends(get_store)) -> list[SubscriptionGroup]:
    return [SubscriptionGroup(**group) for group in store.list_subscription_groups()]


@router.post("/subscription-groups", response_model=SubscriptionGroup)
async def create_subscription_group(
    request: SubscriptionGroupName, store: Store = Depends(get_store)
) -> SubscriptionGroup:
    try:
        return SubscriptionGroup(**store.create_subscription_group(request.name))
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.put("/subscription-groups/{group_id}", response_model=SubscriptionGroup)
async def rename_subscription_group(
    group_id: int, request: SubscriptionGroupName, store: Store = Depends(get_store)
) -> SubscriptionGroup:
    try:
        group = store.rename_subscription_group(group_id, request.name)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if group is None:
        raise HTTPException(status_code=404, detail="分组不存在")
    return SubscriptionGroup(**group)


@router.put("/subscription-groups/{group_id}/default", response_model=SubscriptionGroup)
async def set_default_subscription_group(group_id: int, store: Store = Depends(get_store)) -> SubscriptionGroup:
    group = store.set_default_subscription_group(group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="分组不存在")
    return SubscriptionGroup(**group)


@router.post("/subscription-groups/{group_id}/delete")
async def delete_subscription_group(
    group_id: int, request: SubscriptionGroupDeleteRequest, store: Store = Depends(get_store)
) -> dict[str, int | bool]:
    try:
        moved = store.delete_subscription_group(
            group_id,
            confirm_migration=request.confirm_migration,
            expected_member_count=request.expected_member_count,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if moved is None:
        raise HTTPException(status_code=404, detail="分组不存在")
    return {"ok": True, "migrated_count": moved}


def _overview_item(
    *,
    item_id: str,
    title: str,
    subtitle: str | None,
    detail: str | None,
    status: str | None,
    severity: str,
    system_image: str,
    created_at: datetime | None,
    target_type: str,
    target_id: int | str | None = None,
    subscription_id: int | None = None,
    action: str = "open",
) -> OverviewItem:
    return OverviewItem(
        id=item_id,
        title=title,
        subtitle=subtitle,
        detail=detail,
        status=status,
        severity=severity,
        system_image=system_image,
        created_at=created_at,
        target=OverviewActionTarget(
            target_type=target_type,
            target_id=target_id,
            subscription_id=subscription_id,
            action=action,
        ),
    )


def _history_episode_label(item: DownloadHistory) -> str | None:
    parsed = parse_title(item.torrent_name or item.title)
    if parsed.display_episode_label:
        return parsed.display_episode_label
    if parsed.episode_start is not None and parsed.episode_end is not None and parsed.episode_end != parsed.episode_start:
        return f"E{parsed.episode_start:02d}-E{parsed.episode_end:02d}"
    if parsed.episode_start is not None:
        return f"E{parsed.episode_start:02d}"
    if parsed.episode is not None:
        return f"E{parsed.episode:02d}"
    return None


def _history_pending_organize(item: DownloadHistory) -> bool:
    from app.pending_organize import ORGANIZED_STATES
    if item.status in ORGANIZED_STATES or item.status == "deleted":
        return False
    return item.derived_status in {"下载完成，待整理", "合集待整理", "等待重新整理"} or item.organize_status in {
        "已生成预览",
        "整理失败",
        "待重新整理",
    }


def _format_speed(value: int | None) -> str | None:
    if value is None or value <= 0:
        return None
    units = ["B/s", "KB/s", "MB/s", "GB/s"]
    amount = float(value)
    unit = units[0]
    for candidate in units:
        unit = candidate
        if amount < 1024 or candidate == units[-1]:
            break
        amount /= 1024
    return f"{amount:.1f} {unit}" if amount < 100 else f"{amount:.0f} {unit}"


def _history_issue(item: DownloadHistory) -> str | None:
    if item.status == "error":
        return item.derived_status_detail or item.task_status or "下载提交失败"
    if item.organize_status == "整理失败":
        return item.derived_status_detail or "整理失败"
    if item.derived_status_detail and "任务已不在 qBittorrent" in item.derived_status_detail and item.organize_status != "已整理":
        return item.derived_status_detail
    return None


@router.get("/overview", response_model=OverviewResponse)
async def overview(request: Request, store: Store = Depends(get_store)) -> OverviewResponse:
    subscriptions = []
    for data in store.list_subscriptions():
        refreshes = _subscription_refresh_history_models(store.list_subscription_refresh_history(data["id"], limit=1))
        matches = _subscription_match_models(store.list_subscription_matches(data["id"]))
        refreshed, summary, error = _subscription_latest_status(refreshes, matches)
        metadata = store.list_metadata_bindings_for_target("subscription", str(data["id"]), limit=1)
        poster_url, poster_local_url = _poster_fields_from_metadata_rows(metadata, data["id"])
        poster_palette = _poster_palette_from_metadata_rows(metadata, data["id"])
        metadata_summary = next(
            (row.get("summary") for row in metadata if row.get("summary")),
            None,
        )
        subscription_model = Subscription(**data)
        subscription_history = _download_history_models(store.list_history(subscription_id=data["id"]))
        coverage = _subscription_coverage_summary(subscription_model, matches, subscription_history, store)
        subscriptions.append(SubscriptionListItem(
            **data, latest_refresh_at=refreshed, latest_refresh_summary=summary, latest_error=error,
            poster_url=poster_url,
            poster_local_url=poster_local_url,
            poster_palette=poster_palette,
            episode_count=coverage.total_episodes,
            downloaded_count=coverage.downloaded_count,
            organized_count=coverage.organized_count,
            summary=metadata_summary,
            coverage=coverage,
        ))
    from app.overview import cached_history
    history = cached_history(store)
    organize_previews = [OrganizePreviewRecord(**item) for item in store.list_organize_previews(limit=-1)]
    organize_history = [OrganizeHistoryRecord(**item) for item in store.list_organize_history(limit=-1)]
    latest_by_destination = {}
    for record in organize_history:
        latest_by_destination.setdefault(record.destination_path, record)

    downloading_items: list[OverviewItem] = []
    pending_organize_items: list[OverviewItem] = []
    issues: list[OverviewItem] = []
    recent_completed: list[OverviewItem] = []

    for item in history:
        episode = item.qbittorrent.episode_number if item.qbittorrent else None
        label = f"E{episode:02d}" if episode is not None else None
        subtitle = " · ".join(part for part in [label, item.source] if part)
        if item.status in {"queued", "downloading", "paused"} and (item.qbittorrent is None or (item.qbittorrent.progress or 0) < 0.999):
            progress = item.qbittorrent.progress_percent if item.qbittorrent else None
            speed = _format_speed(item.qbittorrent.download_speed) if item.qbittorrent else None
            detail = " · ".join(part for part in [f"{progress:.1f}%" if progress is not None else None, speed] if part)
            downloading_items.append(
                _overview_item(
                    item_id=f"download:{item.id}",
                    title=item.torrent_name or item.title,
                    subtitle=subtitle or "下载任务",
                    detail=detail or item.task_status,
                    status=item.task_status,
                    severity="info",
                    system_image="arrow.down.circle",
                    created_at=item.created_at,
                    target_type="download_history",
                    target_id=item.id,
                    subscription_id=item.subscription_id,
                    action="open",
                )
            )
        if _history_pending_organize(item):
            pending_organize_items.append(
                _overview_item(
                    item_id=f"organize:{item.id}",
                    title=item.torrent_name or item.title,
                    subtitle=subtitle or "待整理项目",
                    detail=item.derived_status_detail or item.save_path,
                    status=item.derived_status,
                    severity="warning" if item.organize_status == "整理失败" else "info",
                    system_image="folder.badge.gearshape",
                    created_at=item.created_at,
                    target_type="organize_preview",
                    target_id=item.id,
                    subscription_id=item.subscription_id,
                    action="organize",
                )
            )
        if issue_detail := _history_issue(item):
            issues.append(
                _overview_item(
                    item_id=f"history-issue:{item.id}",
                    title=item.torrent_name or item.title,
                    subtitle=subtitle or "下载历史",
                    detail=issue_detail,
                    status="需要处理",
                    severity="error",
                    system_image="exclamationmark.triangle",
                    created_at=item.created_at,
                    target_type="download_history",
                    target_id=item.id,
                    subscription_id=item.subscription_id,
                    action="review",
                )
            )
        if item.derived_status in {"已完成", "已整理", "已整理并移除任务", "已停止做种"} or item.status in {"organized", "organized_task_removed", "seeding_stopped"}:
            recent_completed.append(
                _overview_item(
                    item_id=f"completed-download:{item.id}",
                    title=item.torrent_name or item.title,
                    subtitle=subtitle or "最近完成",
                    detail=item.derived_status,
                    status="已完成",
                    severity="success",
                    system_image="checkmark.circle",
                    created_at=item.created_at,
                    target_type="download_history",
                    target_id=item.id,
                    subscription_id=item.subscription_id,
                    action="open",
                )
            )

    from app.pending_organize import completed_preview_tasks, pending_queue_previews
    reconciled_previews = pending_queue_previews(organize_previews, history, organize_history)
    preview_tasks = {item.record.preview.download_record_id for item in reconciled_previews}
    resolved_tasks = completed_preview_tasks(organize_previews, history, organize_history)
    # A file-level candidate carries more precise remaining work than its history row.
    pending_organize_items = [
        item for item in pending_organize_items
        if int(item.target.target_id) not in preview_tasks | resolved_tasks
    ]
    for candidate in reconciled_previews:
        record = candidate.record
        preview = record.preview
        label_parts: list[str] = []
        if preview.episode_start is not None and preview.episode_end is not None and preview.episode_end != preview.episode_start:
            label_parts.append(f"E{preview.episode_start:02d}-E{preview.episode_end:02d}")
        elif preview.episode_start is not None:
            label_parts.append(f"E{preview.episode_start:02d}")
        if preview.is_batch:
            label_parts.append("合集")
        pending_organize_items.append(
            _overview_item(
                item_id=f"organize-preview:{record.id}",
                title=preview.filename,
                subtitle=" · ".join(label_parts) or preview.show_directory,
                detail=(f"剩余 {len(candidate.remaining_sources)} 个文件待处理，已整理 {candidate.completed_count} 个。"
                        if candidate.completed_count else preview.block_reason or "等待确认，源文件状态将在整理时检查"),
                status="等待确认",
                severity="warning" if any(item.status == "needs_confirmation" for item in preview.file_mappings) else "info",
                system_image="folder.badge.gearshape",
                created_at=record.created_at,
                target_type="organize_preview_record",
                target_id=record.id,
                subscription_id=None,
                action="organize",
            )
        )

    for record in latest_by_destination.values():
        if record.status == "error":
            issues.append(
                _overview_item(
                    item_id=f"organize-issue:{record.id}",
                    title=record.preview.filename,
                    subtitle=record.preview.show_directory,
                    detail=record.message,
                    status="整理失败",
                    severity="error",
                    system_image="exclamationmark.triangle",
                    created_at=record.created_at,
                    target_type="organize_history",
                    target_id=record.id,
                    subscription_id=None,
                    action="review",
                )
            )
        elif record.status in {"moved", "skipped"}:
            recent_completed.append(
                _overview_item(
                    item_id=f"completed-organize:{record.id}",
                    title=record.preview.filename,
                    subtitle=record.preview.show_directory,
                    detail=record.message,
                    status="已整理" if record.status == "moved" else "已跳过",
                    severity="success",
                    system_image="folder",
                    created_at=record.created_at,
                    target_type="organize_history",
                    target_id=record.id,
                    action="open",
                )
            )

    for subscription in subscriptions:
        if subscription.latest_error:
            issues.append(
                _overview_item(
                    item_id=f"subscription-issue:{subscription.id}",
                    title=subscription.name,
                    subtitle="订阅刷新失败",
                    detail=subscription.latest_error,
                    status="需要处理",
                    severity="error",
                    system_image="dot.radiowaves.left.and.right",
                    created_at=subscription.latest_refresh_at,
                    target_type="subscription",
                    target_id=subscription.id,
                    subscription_id=subscription.id,
                    action="review",
                )
            )
        elif subscription.latest_refresh_summary:
            recent_completed.append(
                _overview_item(
                    item_id=f"subscription-refresh:{subscription.id}",
                    title=subscription.name,
                    subtitle="最近刷新摘要",
                    detail=subscription.latest_refresh_summary,
                    status="刷新完成",
                    severity="success",
                    system_image="arrow.clockwise.circle",
                    created_at=subscription.latest_refresh_at,
                    target_type="subscription",
                    target_id=subscription.id,
                    subscription_id=subscription.id,
                    action="open",
                )
            )

    recent_completed.sort(key=lambda item: item.created_at or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    issues.sort(key=lambda item: item.created_at or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    pending_organize_items.sort(key=lambda item: item.created_at or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    downloading_items.sort(key=lambda item: item.created_at or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    failed_subscriptions = [item for item in subscriptions if item.latest_error]
    latest_summary = next((item.latest_refresh_summary for item in subscriptions if item.latest_refresh_summary), None)
    latest_error = next((item.latest_error for item in failed_subscriptions if item.latest_error), None)
    from app.overview import recently_organized_media, runtime_items

    runtime = runtime_items(store)
    automation = getattr(request.app.state, "automation", None)
    if automation is not None:
        snapshot = await automation.status()
        runtime[0].state = "running" if snapshot.scheduler_running else "stopped"
        runtime[0].detail = "自动检查已开启" if snapshot.scheduler_running else "自动检查已停止"
        if snapshot.last_error_message:
            runtime[0].detail += " · 最近检查失败"
        runtime[0].next_at = snapshot.next_run_at

    downloading_count = len(downloading_items)
    pending_organize_count = len(pending_organize_items)
    issues_count = len(issues)
    recent_completed_count = len(recent_completed)
    return OverviewResponse(
        downloading_items=downloading_items[:8],
        pending_organize_items=pending_organize_items,
        issues=issues[:10],
        recent_completed=recent_completed[:8],
        subscription_summary=OverviewSubscriptionSummary(
            total=len(subscriptions),
            enabled=sum(1 for item in subscriptions if item.enabled),
            refreshing=0,
            failed=len(failed_subscriptions),
            latest_refresh_summary=latest_summary,
            latest_error=latest_error,
        ),
        downloading_count=downloading_count,
        pending_organize_count=pending_organize_count,
        issues_count=issues_count,
        recent_completed_count=recent_completed_count,
        generated_at=datetime.now(timezone.utc),
        recently_organized=recently_organized_media(subscriptions, history, organize_history),
        runtime_items=runtime,
        subscription_items=[item.model_dump(mode="json") for item in subscriptions],
    )


def _subscription_or_404(subscription_id: int, store: Store) -> Subscription:
    data = store.get_subscription(subscription_id)
    if not data:
        raise HTTPException(status_code=404, detail="订阅不存在")
    return Subscription(**data)


def _download_history_models(rows: list[dict]) -> list[DownloadHistory]:
    models = [DownloadHistory(**item) for item in rows]
    for item in models:
        if item.status == "organized_task_removed":
            item.organize_status = "已整理"
            item.task_status = "已整理并移除任务"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
        elif item.status == "seeding_stopped":
            item.organize_status = "已整理"
            item.task_status = "已停止做种"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
        elif item.status == "organized":
            item.organize_status = "已整理"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
        elif item.status == "deleted":
            item.organize_status = "未整理"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
        elif item.status == "dry_run":
            item.organize_status = "未整理"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
    return models


def _apply_history_organize_availability(histories: list[DownloadHistory]) -> None:
    terminal_statuses = {
        "dry_run",
        "deleted",
        "organized",
        "organized_task_removed",
        "seeding_stopped",
    }
    for history in histories:
        history.organize_available = False
        if history.organize_status == "已整理" or history.status in terminal_statuses:
            history.organize_block_reason = "该记录已整理或已经结束，不能再次整理。"
            continue
        progress = history.qbittorrent
        if progress is None or not progress.matched:
            history.organize_block_reason = "尚未可靠映射到下载器任务，无法确认整理源文件。"
            continue
        if progress.progress is None or progress.progress < 0.999:
            history.organize_block_reason = "下载尚未完成，完成后才能整理。"
            continue
        if not _exact_history_source_exists(history):
            history.organize_block_reason = "后端未找到可访问的任务文件，请检查下载目录或挂载状态。"
            continue
        history.organize_available = True
        history.organize_block_reason = None


BTIH_RE = re.compile(r"btih[:=]([a-z2-7]{32}|[a-f0-9]{40})", re.IGNORECASE)
TORRENT_PATH_HASH_RE = re.compile(r"/([a-f0-9]{40})(?:\.torrent)?(?:$|[/?#])", re.IGNORECASE)
TASK_TEXT_RE = re.compile(r"[^0-9a-z\u4e00-\u9fff]+", re.IGNORECASE)
TASK_TOKEN_RE = re.compile(r"[a-z0-9]+|[\u4e00-\u9fff]+", re.IGNORECASE)
WEAK_TASK_TOKENS = {"web", "dl", "aac", "avc", "mp4", "mkv", "chs", "cht", "big5", "gb"}
TRUSTED_TASK_MATCH_CONFIDENCE = 0.68


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


def _btih_from_url(value: str | None) -> str | None:
    if not value:
        return None
    parsed = urlparse(value)
    for xt in parse_qs(parsed.query).get("xt", []):
        if xt.lower().startswith("urn:btih:"):
            normalized = _normalize_info_hash(xt.split(":")[-1])
            if normalized:
                return normalized
    match = BTIH_RE.search(value)
    if match:
        return _normalize_info_hash(match.group(1))
    path_match = TORRENT_PATH_HASH_RE.search(parsed.path)
    return _normalize_info_hash(path_match.group(1)) if path_match else None


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


def _same_save_path(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left_path = str(PurePosixPath(left)).rstrip("/")
    right_path = str(PurePosixPath(right)).rstrip("/")
    return bool(left_path and right_path and left_path == right_path)


@dataclass(frozen=True)
class DownloadTaskMatch:
    torrent: dict | None
    confidence: float
    reason: str


def _find_torrent_by_hash(torrents: list[dict], expected_hash: str) -> dict | None:
    for torrent in torrents:
        if _torrent_hash(torrent) == expected_hash:
            return torrent
    return None


def _match_torrent_for_history(history: DownloadHistory, torrents: list[dict]) -> DownloadTaskMatch:
    stored_hash = _normalize_info_hash(history.qbittorrent_hash)
    if history.remote_task_id:
        remote_match = None
        for torrent in torrents:
            if str(torrent.get("remote_id") or "") == history.remote_task_id:
                remote_match = torrent
                break
        if remote_match is not None:
            if not stored_hash or _torrent_hash(remote_match) == stored_hash:
                return DownloadTaskMatch(torrent=remote_match, confidence=1.0, reason="stored_remote_task_id")
            hash_match = _find_torrent_by_hash(torrents, stored_hash)
            if hash_match is not None:
                return DownloadTaskMatch(torrent=hash_match, confidence=1.0, reason="stored_hash_corrected_reused_remote_id")
            return DownloadTaskMatch(torrent=None, confidence=1.0, reason="stored_remote_task_id_hash_mismatch")
        if stored_hash:
            hash_match = _find_torrent_by_hash(torrents, stored_hash)
            if hash_match is not None:
                return DownloadTaskMatch(torrent=hash_match, confidence=1.0, reason="stored_hash_corrected_stale_remote_id")
        return DownloadTaskMatch(torrent=None, confidence=1.0, reason="stored_remote_task_id_not_found")
    link_hash = _btih_from_url(history.download_url)
    if link_hash:
        torrent = _find_torrent_by_hash(torrents, link_hash)
        if torrent is not None:
            reason = "magnet_info_hash"
            if stored_hash and stored_hash != link_hash:
                reason = "magnet_info_hash_corrected_stale_history_hash"
            return DownloadTaskMatch(torrent=torrent, confidence=1.0, reason=reason)
        return DownloadTaskMatch(torrent=None, confidence=1.0, reason="magnet_info_hash_not_found")

    if stored_hash:
        torrent = _find_torrent_by_hash(torrents, stored_hash)
        if torrent is not None:
            return DownloadTaskMatch(torrent=torrent, confidence=1.0, reason="stored_qbittorrent_hash")
        return DownloadTaskMatch(torrent=None, confidence=1.0, reason="stored_qbittorrent_hash_not_found")

    torrent_name = (history.torrent_name or "").casefold()
    if torrent_name:
        exact_name_matches: list[dict] = []
        normalized_name_matches: list[dict] = []
        for torrent in torrents:
            name = _torrent_name(torrent).casefold()
            if not _same_episode_identity(history.torrent_name, name):
                continue
            if name and name == torrent_name:
                exact_name_matches.append(torrent)
            elif _same_task_text(history.torrent_name, name):
                normalized_name_matches.append(torrent)
        if len(exact_name_matches) == 1:
            return DownloadTaskMatch(torrent=exact_name_matches[0], confidence=0.85, reason="exact_torrent_name")
        if len(exact_name_matches) > 1:
            return DownloadTaskMatch(torrent=None, confidence=0.0, reason="ambiguous_exact_torrent_name")
        if len(normalized_name_matches) == 1:
            return DownloadTaskMatch(torrent=normalized_name_matches[0], confidence=0.72, reason="normalized_torrent_name")
        if len(normalized_name_matches) > 1:
            return DownloadTaskMatch(torrent=None, confidence=0.0, reason="ambiguous_normalized_torrent_name")

    title = history.title
    normalized_title_matches: list[dict] = []
    for torrent in torrents:
        name = _torrent_name(torrent)
        if not _same_episode_identity(title, name):
            continue
        if name and _same_task_text(title, name):
            normalized_title_matches.append(torrent)
    if len(normalized_title_matches) == 1:
        return DownloadTaskMatch(torrent=normalized_title_matches[0], confidence=0.68, reason="normalized_title")
    if len(normalized_title_matches) > 1:
        return DownloadTaskMatch(torrent=None, confidence=0.0, reason="ambiguous_normalized_title")

    if history.downloader_type == "transmission" and history.source in PRIVATE_TORRENT_SITES and history.save_path:
        same_path_torrents = [
            torrent for torrent in torrents if _same_save_path(history.save_path, _torrent_save_path(torrent))
        ]
        if len(same_path_torrents) == 1:
            candidate = same_path_torrents[0]
            name = _torrent_name(candidate)
            if _same_episode_identity(title, name) and _same_task_tokens(title, name):
                return DownloadTaskMatch(
                    torrent=candidate,
                    confidence=0.90,
                    reason="unique_save_path_and_title_tokens",
                )

    token_matches: list[dict] = []
    for torrent in torrents:
        name = _torrent_name(torrent)
        if not _same_episode_identity(title, name):
            continue
        if name and _same_task_tokens(title, name):
            token_matches.append(torrent)
    if len(token_matches) == 1:
        return DownloadTaskMatch(torrent=token_matches[0], confidence=0.45, reason="token_title_low_confidence")
    if len(token_matches) > 1:
        return DownloadTaskMatch(torrent=None, confidence=0.0, reason="ambiguous_token_title")

    if history.save_path:
        same_path_torrents = [torrent for torrent in torrents if _same_save_path(history.save_path, _torrent_save_path(torrent))]
        if len(same_path_torrents) == 1:
            return DownloadTaskMatch(torrent=same_path_torrents[0], confidence=0.35, reason="unique_save_path_low_confidence")
    return DownloadTaskMatch(torrent=None, confidence=0.0, reason="no_match")


def _find_torrent_for_history(history: DownloadHistory, torrents: list[dict]) -> dict | None:
    match = _match_torrent_for_history(history, torrents)
    if match.confidence < TRUSTED_TASK_MATCH_CONFIDENCE:
        return None
    return match.torrent


def _float_or_none(value: object) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _int_or_none(value: object) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _format_bytes_per_second(value: int) -> str:
    units = ["B/s", "KB/s", "MB/s", "GB/s"]
    amount = float(max(value, 0))
    unit = units[0]
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            break
        amount /= 1024
    if unit == "B/s":
        return f"{int(amount)} {unit}"
    return f"{amount:.1f} {unit}"


def _format_bytes(value: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    amount = float(max(value, 0))
    unit = units[0]
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            break
        amount /= 1024
    if unit == "B":
        return f"{int(amount)} {unit}"
    return f"{amount:.1f} {unit}"


def _format_duration(seconds: int) -> str:
    if seconds < 0:
        return "未知"
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours} 小时 {minutes} 分钟"
    if minutes:
        return f"{minutes} 分钟 {secs} 秒"
    return f"{secs} 秒"


def _qbittorrent_state_label(state: str | None, progress: float | None = None) -> str | None:
    if not state:
        return "已完成" if progress is not None and progress >= 0.999 else None
    labels = {
        "allocating": "分配空间",
        "checkingDL": "校验中",
        "checkingUP": "校验中",
        "checkingResumeData": "校验恢复数据",
        "downloading": "下载中",
        "forcedDL": "强制下载",
        "forcedUP": "强制做种",
        "metaDL": "获取元数据",
        "missingFiles": "文件缺失",
        "moving": "移动文件",
        "pausedDL": "已暂停",
        "pausedUP": "已暂停做种",
        "stoppedDL": "已暂停",
        "stoppedUP": "已暂停做种",
        "queuedDL": "排队下载",
        "queuedUP": "排队做种",
        "stalledDL": "等待连接",
        "stalledUP": "做种中",
        "uploading": "做种中",
        "error": "任务异常",
        "unknown": "未知",
    }
    return labels.get(state, state)


def _progress_message(
    progress_percent: float | None,
    state_label: str | None,
    download_speed: int | None,
    eta: int | None,
    *,
    downloaded: int | None = None,
    total_size: int | None = None,
    upload_speed: int | None = None,
    ratio: float | None = None,
) -> str:
    bits: list[str] = []
    if progress_percent is not None:
        bits.append(f"进度 {progress_percent:.1f}%")
    if downloaded is not None and total_size:
        bits.append(f"大小 {_format_bytes(downloaded)} / {_format_bytes(total_size)}")
    if state_label:
        bits.append(f"状态 {state_label}")
    if download_speed is not None:
        bits.append(f"下载速度 {_format_bytes_per_second(download_speed)}")
    if upload_speed is not None and upload_speed > 0:
        bits.append(f"上传速度 {_format_bytes_per_second(upload_speed)}")
    if eta is not None and eta >= 0:
        bits.append(f"剩余 {_format_duration(eta)}")
    if ratio is not None:
        bits.append(f"分享率 {ratio:.2f}")
    return "，".join(bits) if bits else "进度未知（下载器未返回任务详情）"


def _task_progress_from_torrent(torrent: dict) -> QbittorrentTaskProgress:
    progress = _float_or_none(torrent.get("progress"))
    progress_percent = round(progress * 100, 1) if progress is not None else None
    state = str(torrent.get("state") or "") or None
    state_label = _qbittorrent_state_label(state, progress)
    download_speed = _int_or_none(torrent.get("dlspeed"))
    upload_speed = _int_or_none(torrent.get("upspeed"))
    eta = _int_or_none(torrent.get("eta"))
    # qBittorrent uses 8,640,000 seconds (100 days) as an unknown ETA sentinel.
    # Presenting it as a real duration produces the misleading “剩余 2400 小时”.
    if eta is not None and (eta < 0 or eta >= 8_640_000):
        eta = None
    if progress is not None and progress >= 0.999:
        eta = None
    total_size = _int_or_none(torrent.get("total_size"))
    if total_size is None:
        total_size = _int_or_none(torrent.get("size"))
    downloaded = _int_or_none(torrent.get("downloaded"))
    if downloaded is None and progress is not None and total_size is not None:
        downloaded = int(total_size * progress)
    ratio = _float_or_none(torrent.get("ratio"))
    return QbittorrentTaskProgress(
        matched=True,
        hash=str(torrent.get("hash") or "") or None,
        name=_torrent_name(torrent) or None,
        state=state,
        state_label=state_label,
        progress=progress,
        progress_percent=progress_percent,
        downloaded=downloaded,
        total_size=total_size,
        download_speed=download_speed,
        upload_speed=upload_speed,
        eta=eta,
        ratio=ratio,
        seeding_time=_int_or_none(torrent.get("seeding_time")),
        num_seeds=_int_or_none(torrent.get("num_seeds")),
        num_complete=_int_or_none(torrent.get("num_complete")),
        num_incomplete=_int_or_none(torrent.get("num_incomplete")),
        num_leechs=_int_or_none(torrent.get("num_leechs")),
        last_seen_at=datetime.now(timezone.utc),
        message=_progress_message(
            progress_percent,
            state_label,
            download_speed,
            eta,
            downloaded=downloaded,
            total_size=total_size,
            upload_speed=upload_speed,
            ratio=ratio,
        ),
    )


def _bind_progress_to_history(progress: QbittorrentTaskProgress, history: DownloadHistory) -> QbittorrentTaskProgress:
    episode = parse_title(history.title).episode
    progress.download_record_id = history.id
    progress.subscription_id = history.subscription_id
    progress.episode_number = episode
    return progress


def _seeding_stop_condition_text(policy: OrganizePolicySettings) -> str | None:
    parts: list[str] = []
    if policy.seeding_stop_ratio is not None:
        parts.append(f"分享率 ≥ {policy.seeding_stop_ratio:g}")
    if policy.seeding_stop_minutes is not None:
        parts.append(f"做种时间 ≥ {_format_duration(policy.seeding_stop_minutes * 60)}")
    if not parts:
        return None
    joiner = " 且 " if policy.seeding_stop_mode == "all" else " 或 "
    return joiner.join(parts)


def _post_seeding_action_text(action: str) -> str:
    if action == "pause":
        return "暂停任务"
    if action == "remove_task_keep_files":
        return "移除任务，保留文件"
    if action == "remove_task_delete_files":
        return "移除任务并删除原文件"
    return "手动处理"


def _cleanup_result(
    *,
    attempted: bool,
    status: str | None = None,
    path: str | None = None,
    message: str | None = None,
) -> dict[str, Any]:
    return {
        "cleanup_attempted": attempted,
        "cleanup_status": status,
        "cleanup_path": path,
        "cleanup_message": message,
    }


async def _cleanup_empty_download_dir(
    history: DownloadHistory,
    source_path: str,
    store: Store,
    policy: OrganizePolicySettings,
) -> dict[str, Any]:
    if not policy.clean_empty_download_dirs:
        return _cleanup_result(attempted=False)
    source_dir = Path(source_path).expanduser().absolute().parent
    result_path = str(source_dir)
    if history.subscription_id is not None and store.get_subscription(history.subscription_id) is not None:
        return _cleanup_result(
            attempted=True,
            status="skipped",
            path=result_path,
            message="订阅仍存在，其下载目录将保留至删除订阅时清理。",
        )
    allowed_roots: list[Path] = []
    if history.save_path:
        history_path = Path(history.save_path).expanduser().absolute()
        if history_path != source_dir and history_path in source_dir.parents:
            allowed_roots.append(history_path)
    config = stored_transmission_config(store) if history.downloader_type == "transmission" else stored_qbittorrent_config(store)
    if config and getattr(config, "default_save_path", None):
        allowed_roots.append(Path(config.default_save_path).expanduser().absolute())
    managed_roots = [root for root in allowed_roots if root != source_dir and root in source_dir.parents]
    if not managed_roots:
        return _cleanup_result(
            attempted=True,
            status="skipped",
            path=result_path,
            message="目录不在 Kisetsu 管理的下载路径下，未清理。",
        )
    if config is not None:
        try:
            torrents = await _configured_downloader_client(store, history.downloader_type).list_torrents()
        except Exception as exc:
            return _cleanup_result(
                attempted=True,
                status="skipped",
                path=result_path,
                message=f"无法确认原下载器活跃任务，未清理：{describe_downloader_error(history.downloader_type, exc)}",
            )
        for torrent in torrents:
            torrent_save_path = str(torrent.get("save_path") or torrent.get("savePath") or "").strip()
            torrent_content_path = str(torrent.get("content_path") or torrent.get("contentPath") or "").strip()
            uses_source_dir = bool(
                torrent_content_path and paths_overlap(source_dir, torrent_content_path)
            ) or bool(
                torrent_save_path
                and Path(torrent_save_path).expanduser().absolute() == source_dir
            )
            if uses_source_dir:
                return _cleanup_result(
                    attempted=True,
                    status="skipped",
                    path=result_path,
                    message="仍有下载器任务使用该目录，未清理。",
                )
    managed_root = max(managed_roots, key=lambda item: len(item.parts))
    cleanup = prune_empty_managed_directory(source_dir, managed_root=managed_root)
    return _cleanup_result(
        attempted=cleanup.attempted,
        status=cleanup.status,
        path=cleanup.path,
        message=cleanup.message,
    )


def _seeding_stop_reached(progress: QbittorrentTaskProgress, policy: OrganizePolicySettings) -> bool:
    if not policy.keep_seeding or progress.progress is None or progress.progress < 0.999:
        return False
    checks: list[bool] = []
    if policy.seeding_stop_ratio is not None:
        checks.append(progress.ratio is not None and progress.ratio >= policy.seeding_stop_ratio)
    if policy.seeding_stop_minutes is not None:
        checks.append(progress.seeding_time is not None and progress.seeding_time >= policy.seeding_stop_minutes * 60)
    if not checks:
        return False
    return all(checks) if policy.seeding_stop_mode == "all" else any(checks)


def _seeding_policy_for_history(history: DownloadHistory, store: Store) -> OrganizePolicySettings:
    if history.subscription_id is None:
        return stored_organize_policy(store)
    data = store.get_subscription(history.subscription_id)
    if data is None:
        return stored_organize_policy(store)
    return _organize_policy_for_subscription(Subscription(**data), store)


def _annotate_seeding_progress(
    progress: QbittorrentTaskProgress,
    policy: OrganizePolicySettings,
) -> QbittorrentTaskProgress:
    progress.seeding_stop_condition = _seeding_stop_condition_text(policy)
    progress.post_seeding_action = _post_seeding_action_text(policy.post_seeding_action)
    progress.seeding_target_ratio = policy.seeding_stop_ratio
    progress.seeding_stop_mode = policy.seeding_stop_mode
    if policy.seeding_stop_minutes is not None:
        progress.seeding_target_seconds = policy.seeding_stop_minutes * 60
        if progress.seeding_time is not None:
            progress.seeding_remaining_seconds = max(progress.seeding_target_seconds - progress.seeding_time, 0)
    progress.seeding_target_reached = _seeding_stop_reached(progress, policy)
    return progress


async def _apply_seeding_stop_if_needed(
    client,
    store: Store,
    history: DownloadHistory,
    progress: QbittorrentTaskProgress,
) -> QbittorrentTaskProgress:
    downloader_name = downloader_display_name(getattr(client, "downloader_type", history.downloader_type))
    policy = _seeding_policy_for_history(history, store)
    _annotate_seeding_progress(progress, policy)
    condition = progress.seeding_stop_condition
    if not condition or not _seeding_stop_reached(progress, policy):
        return progress
    if not progress.hash:
        progress.message = f"{progress.message}，做种停止条件已达标，但 {downloader_name} 未返回任务标识。"
        return progress
    if policy.post_seeding_action == "manual":
        progress.message = f"{progress.message}，做种停止条件已达标，等待手动处理。"
        return progress
    if policy.post_seeding_action == "pause":
        await client.pause_torrents([progress.hash])
        store.update_history_status(history.id, "seeding_stopped")
        progress.state_label = "已停止做种"
        progress.message = f"已达到做种停止条件（{condition}），已暂停 {downloader_name} 任务。"
        return progress
    delete_files = policy.post_seeding_action == "remove_task_delete_files"
    await client.delete_torrents([progress.hash], delete_files=delete_files)
    store.update_history_status(history.id, "organized_task_removed")
    progress.state_label = "已移除任务"
    progress.message = f"已达到做种停止条件（{condition}），已从 {downloader_name} 移除任务。"
    return progress


def _remember_history_torrent(store: Store, history_id: int, torrent: dict | None) -> None:
    if torrent is None:
        return
    store.update_history_qbittorrent_task(
        history_id,
        qbittorrent_hash=_torrent_hash(torrent) or None,
        downloader_type=str(torrent.get("downloader_type") or "qbittorrent"),
        remote_task_id=str(torrent.get("remote_id")) if torrent.get("remote_id") is not None else None,
        torrent_name=_torrent_name(torrent) or None,
        save_path=str(torrent.get("save_path") or torrent.get("savePath") or "") or None,
    )


def _record_download_history(
    store: Store,
    result: SearchResult,
    *,
    subscription_id: int | None,
    status: str,
    save_path: str | None = None,
    downloader_type: str = "qbittorrent",
    remote_task_id: str | None = None,
    torrent_hash: str | None = None,
    torrent_name: str | None = None,
) -> int:
    url = result.magnet_url or result.download_url
    return record_processed(
        store,
        result,
        subscription_id=subscription_id,
        status=status,
        qbittorrent_hash=torrent_hash or _btih_from_url(url),
        downloader_type=downloader_type,
        remote_task_id=remote_task_id,
        torrent_name=torrent_name or result.title,
        save_path=save_path,
    )


async def _remember_submitted_torrent(
    client,
    store: Store,
    history_id: int,
    *,
    add_result: DownloaderAddResult | None = None,
    downloader_type: str = "qbittorrent",
) -> None:
    with suppress(Exception):
        history_item = store.get_history(history_id)
        if not history_item:
            return
        torrent = None
        if add_result is not None:
            task_by_identity = getattr(client, "task_by_identity", None)
            if callable(task_by_identity):
                torrent = await task_by_identity(add_result)
        if torrent is None:
            torrent = _find_torrent_for_history(DownloadHistory(**history_item), await client.list_torrents())
        if torrent is not None:
            torrent.setdefault("downloader_type", downloader_type)
        _remember_history_torrent(store, history_id, torrent)


async def _download_history_models_with_progress(
    rows: list[dict],
    store: Store,
    *,
    task_snapshots: dict[str, list[dict[str, Any]]] | None = None,
    downloader_clients: dict[str, Any] | None = None,
    snapshot_errors: dict[str, Exception] | None = None,
) -> list[DownloadHistory]:
    histories = _download_history_models(rows)
    if not histories:
        return histories

    for item in histories:
        if item.status == "dry_run":
            item.organize_status = "未整理"
            item.task_status = "试运行"
            downloader_name = downloader_display_name(item.downloader_type)
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message=f"试运行记录，没有 {downloader_name} 任务"), item)
        elif item.status == "deleted":
            item.organize_status = "未整理"
            item.task_status = "已从下载器移除"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="任务已从下载器删除"), item)
        elif item.status == "pending_confirmation":
            item.organize_status = "未整理"
            item.task_status = "等待下载器确认"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="请求已发送，正在确认下载器任务"), item)
        elif item.status == "organized_task_removed":
            item.organize_status = "已整理"
            item.task_status = "已整理并移除任务"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="已整理并移除下载器任务"), item)
        elif item.status == "seeding_stopped":
            item.organize_status = "已整理"
            item.task_status = "已停止做种"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="已达到做种停止条件，下载器任务已暂停。"), item)
        elif item.status == "organized":
            item.organize_status = "已整理"
            item.task_status = "已整理，任务状态待刷新"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="已整理，任务仍在下载器中或待刷新"), item)
        else:
            item.organize_status = "未整理"
            item.task_status = "待刷新"
            item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(), item)
        item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)

    candidates = [item for item in histories if item.status not in {"dry_run", "deleted"}]
    candidates = [item for item in candidates if item.status not in {"organized_task_removed"}]
    if not candidates:
        _apply_history_organize_availability(histories)
        return histories

    grouped: dict[str, list[DownloadHistory]] = {}
    for item in candidates:
        grouped.setdefault(item.downloader_type or "qbittorrent", []).append(item)

    for downloader_type, group in grouped.items():
        downloader_name = downloader_display_name(downloader_type)
        try:
            if snapshot_errors and downloader_type in snapshot_errors:
                raise snapshot_errors[downloader_type]
            client = (downloader_clients or {}).get(downloader_type) or _configured_downloader_client(store, downloader_type)
            if task_snapshots is not None and downloader_type in task_snapshots:
                torrents = task_snapshots[downloader_type]
            else:
                torrents = await client.list_torrents()
        except Exception as exc:
            message = f"进度未知（{describe_downloader_error(downloader_type, exc)}）"
            for item in group:
                item.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message=message), item)
            continue

        for item in group:
            match = _match_torrent_for_history(item, torrents)
            torrent = match.torrent if match.confidence >= TRUSTED_TASK_MATCH_CONFIDENCE else None
            logger.debug(
                "download history match downloader=%s history_id=%s reason=%s confidence=%.2f task_count=%s",
                downloader_type,
                item.id,
                match.reason,
                match.confidence,
                len(torrents),
            )
            if torrent is None:
                if item.status == "pending_confirmation":
                    item.task_status = "等待下载器确认"
                    message = "请求已发送，正在确认下载器任务。"
                elif item.status == "organized":
                    item.task_status = f"已整理，任务已不在 {downloader_name} 中"
                    message = f"已整理，任务已不在 {downloader_name} 中；本地记录保留。"
                else:
                    item.task_status = "任务不存在"
                    message = f"任务已不在 {downloader_name} 中，可删除本地记录或重新添加。"
                item.qbittorrent = _bind_progress_to_history(
                    QbittorrentTaskProgress(match_confidence=match.confidence, match_reason=match.reason, message=message),
                    item,
                )
                continue

            torrent.setdefault("downloader_type", downloader_type)
            _remember_history_torrent(store, item.id, torrent)
            item.qbittorrent_hash = _torrent_hash(torrent) or item.qbittorrent_hash
            item.remote_task_id = str(torrent.get("remote_id")) if torrent.get("remote_id") is not None else item.remote_task_id
            item.torrent_name = _torrent_name(torrent) or item.torrent_name
            item.save_path = _torrent_save_path(torrent) or item.save_path
            item.task_status = f"任务仍在 {downloader_name} 中"
            item.qbittorrent = _bind_progress_to_history(_task_progress_from_torrent(torrent), item)
            item.qbittorrent.match_confidence = match.confidence
            item.qbittorrent.match_reason = match.reason
            if item.qbittorrent.progress is not None and item.qbittorrent.progress >= 0.999:
                if item.status == "queued":
                    store.update_history_status(item.id, "completed")
                    item.status = "completed"
                await _notification_service(store).send_best_effort(download_completed_event(store, item.model_dump(mode="json")))
            if item.status in {"organized", "seeding_stopped"}:
                item.qbittorrent = await _apply_seeding_stop_if_needed(client, store, item, item.qbittorrent)
                if item.qbittorrent.state_label == "已停止做种":
                    item.status = "seeding_stopped"
                    item.task_status = "已停止做种"
                elif item.qbittorrent.state_label == "已移除任务":
                    item.status = "organized_task_removed"
                    item.task_status = "已整理并移除任务"
            item.derived_status, item.derived_status_detail = _resource_derived_status(item, item.organize_status)
    _apply_recorded_organize_states(histories, store)
    _apply_history_organize_availability(histories)
    return histories


def _apply_recorded_organize_states(histories: list[DownloadHistory], store: Store) -> None:
    state_by_history_id: dict[int, tuple[str, str | None]] = {}
    histories_by_id = {history.id: history for history in histories}
    histories_by_subscription: dict[int, list[DownloadHistory]] = {}
    for history in histories:
        if history.subscription_id is not None:
            histories_by_subscription.setdefault(history.subscription_id, []).append(history)
    for record in store.list_organize_history(limit=500):
        if record.get("status") not in {"moved", "skipped", "error"}:
            continue
        if bool((record.get("preview") or {}).get("partial_batch")):
            continue
        download_record_id = record.get("preview", {}).get("download_record_id")
        history_id = download_record_id if isinstance(download_record_id, int) and download_record_id in histories_by_id else None
        if history_id is None:
            history_id = _legacy_organize_record_history_id(record, histories_by_subscription)
        if history_id is None or history_id in state_by_history_id:
            continue
        state_by_history_id[history_id] = _recorded_organize_state(record)
    for history in histories:
        recorded = state_by_history_id.get(history.id)
        if recorded is None:
            continue
        recorded_state, recorded_detail = recorded
        history.organize_status = recorded_state
        if recorded_detail:
            history.derived_status_detail = recorded_detail
        history.derived_status, history.derived_status_detail = _resource_derived_status(history, recorded_state)


def _exact_path_key(value: str | None) -> str | None:
    if not value or not value.strip():
        return None
    return str(PurePosixPath(value.strip().replace("\\", "/"))).rstrip("/").casefold()


def _history_source_path_keys(history: DownloadHistory) -> set[str]:
    keys = {_exact_path_key(history.save_path)}
    if history.save_path and history.torrent_name:
        keys.add(
            _exact_path_key(
                str(PurePosixPath(history.save_path.replace("\\", "/")) / history.torrent_name)
            )
        )
    return {key for key in keys if key}


def _season_episode_identities(*values: str | None) -> set[tuple[int, int]]:
    identities: set[tuple[int, int]] = set()
    for value in values:
        if not value:
            continue
        for match in re.finditer(r"(?i)S0*(\d{1,2})E0*(\d{1,3})", value):
            identities.add((int(match.group(1)), int(match.group(2))))
    return identities


def _legacy_organize_record_history_id(
    record: dict[str, Any],
    histories_by_subscription: dict[int, list[DownloadHistory]],
) -> int | None:
    subscription_id = record.get("subscription_id")
    if subscription_id is None:
        return None
    preview = record.get("preview") or {}
    record_keys = {
        _exact_path_key(record.get("source_path")),
        _exact_path_key(preview.get("source_path")),
    }
    record_keys.discard(None)
    subscription_histories = histories_by_subscription.get(int(subscription_id), [])
    candidates = [
        history
        for history in subscription_histories
        if record_keys.intersection(_history_source_path_keys(history))
    ]
    if not candidates:
        record_identities = _season_episode_identities(
            record.get("source_path"),
            record.get("destination_path"),
            preview.get("source_path"),
            preview.get("filename"),
            preview.get("destination_preview"),
        )
        if len(record_identities) != 1:
            return None
        candidates = [
            history
            for history in subscription_histories
            if record_identities.intersection(
                _season_episode_identities(history.title, history.torrent_name)
            )
        ]
    created_at = record.get("created_at")
    if created_at:
        with suppress(ValueError, TypeError):
            record_created_at = datetime.fromisoformat(str(created_at).replace("Z", "+00:00"))
            candidates = [history for history in candidates if history.created_at <= record_created_at]
    if not candidates:
        return None
    active_candidates = [
        history
        for history in candidates
        if history.status not in {"deleted", "organized_task_removed", "seeding_stopped"}
    ]
    if active_candidates:
        candidates = active_candidates
    candidates.sort(key=lambda history: (history.created_at, history.id), reverse=True)
    return candidates[0].id


def _recorded_organize_state(record: dict[str, Any]) -> tuple[str, str | None]:
    source_value = str(record.get("source_path") or "").strip()
    destination_value = str(record.get("destination_path") or "").strip()
    source_exists = bool(source_value) and Path(source_value).expanduser().is_file()
    destination_exists = bool(destination_value) and Path(destination_value).expanduser().exists()
    status = str(record.get("status") or "")
    message = str(record.get("message") or "").strip() or None
    if status in {"moved", "skipped"}:
        if destination_exists:
            return "已整理", None
        if source_exists:
            return "待重新整理", "上次整理目标已不存在，将由后台自动重新整理"
        return "需要检查", "存在成功整理记录，但目标文件和原下载文件均已不存在"
    if status == "error":
        blocker_cleared = (
            source_exists
            and not destination_exists
            and message is not None
            and (
                message.startswith("目标文件已存在")
                or message.startswith("目标字幕已存在")
                or message.startswith("源文件不存在")
                or message.startswith("源路径不是文件")
            )
        )
        if blocker_cleared:
            return "待重新整理", "上次整理阻断条件已解除，将由后台自动重新整理"
        return "整理失败", message or "上次整理失败"
    return "未整理", None


def _cache_download_history_models(store: Store, histories: list[DownloadHistory]) -> None:
    store.set_config(
        DOWNLOAD_HISTORY_CACHE_KEY,
        {
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "items": [item.model_dump(mode="json", exclude={"download_url"}) for item in histories],
        },
    )


def _cached_download_history_models(
    store: Store,
    *,
    subscription_id: int | None = None,
    limit: int = 100000,
) -> list[DownloadHistory]:
    rows = store.list_history(subscription_id=subscription_id, limit=limit)
    cached_payload = store.get_config(DOWNLOAD_HISTORY_CACHE_KEY) or {}
    cached_by_id = {
        int(item.get("id")): item
        for item in cached_payload.get("items", [])
        if isinstance(item, dict) and item.get("id") is not None
    }
    models: list[DownloadHistory] = []
    for row in rows:
        cached = cached_by_id.get(int(row["id"]))
        if cached is None or str(cached.get("fingerprint") or "") != str(row.get("fingerprint") or ""):
            models.extend(_download_history_models([row]))
            continue
        model = DownloadHistory(**cached)
        model.download_url = row.get("download_url")
        for field in ("status", "qbittorrent_hash", "downloader_type", "remote_task_id", "torrent_name", "save_path"):
            setattr(model, field, row.get(field))
        if model.status == "deleted":
            model.organize_status = "未整理"
            model.task_status = "已从下载器移除"
            model.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="任务已从下载器删除"), model)
        elif model.status == "organized_task_removed":
            model.organize_status = "已整理"
            model.task_status = "已整理并移除任务"
            model.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="已达到做种停止条件，已整理并移除下载器任务。"), model)
        elif model.status == "seeding_stopped":
            model.organize_status = "已整理"
            model.task_status = "已停止做种"
            model.qbittorrent = _bind_progress_to_history(QbittorrentTaskProgress(message="已达到做种停止条件，下载器任务已暂停。"), model)
        model.derived_status, model.derived_status_detail = _resource_derived_status(model, model.organize_status)
        models.append(model)
    _apply_recorded_organize_states(models, store)
    _apply_history_organize_availability(models)
    return models


def _stable_match_result_id(item: dict[str, Any], result: dict[str, Any]) -> str:
    for key in ("id", "guid", "download_url", "magnet_url", "detail_url", "source_url", "link", "torrent_url"):
        value = result.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    fingerprint = str(item.get("fingerprint") or "").strip()
    if fingerprint:
        return f"rss:{fingerprint}"
    raw = json.dumps(result, ensure_ascii=False, sort_keys=True)
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]
    return f"rss:{digest}"


def _normalize_subscription_match_record(item: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(item)
    result = dict(normalized.get("result") or {})
    raw_title = str(result.get("title") or "").strip()
    title = raw_title or "未命名 RSS 条目"
    result["title"] = title
    result["id"] = _stable_match_result_id(normalized, result)
    source = str(result.get("source") or "").strip()
    result["source"] = source or "rss"
    normalized["result"] = result

    parsed_title = dict(normalized.get("parsed_title") or {})
    parsed_title["original_title"] = str(parsed_title.get("original_title") or "").strip() or title
    normalized["parsed_title"] = parsed_title
    return normalized


def _subscription_match_models(rows: list[dict]) -> list[SubscriptionMatch]:
    return [SubscriptionMatch(**_normalize_subscription_match_record(item)) for item in rows]


def _reparsed_subscription_match_models(
    subscription: Subscription,
    rows: list[dict],
    store: Store,
) -> list[SubscriptionMatch]:
    matches: list[SubscriptionMatch] = []
    for match in _subscription_match_models(rows):
        reparsed = parse_title(
            match.result.title,
            subscription.episode_parse_rules,
        )
        if reparsed.model_dump(mode="json") != match.parsed_title.model_dump(mode="json"):
            updated = store.upsert_subscription_match(
                subscription_id=subscription.id,
                fingerprint=match.fingerprint,
                result=match.result.model_dump(mode="json"),
                parsed_title=reparsed.model_dump(mode="json"),
                status=match.status,
            )
            match = SubscriptionMatch(**_normalize_subscription_match_record(updated))
        matches.append(match)
    return matches


def _subscription_matches_with_current_size_bounds(
    subscription: Subscription,
    matches: list[SubscriptionMatch],
) -> list[SubscriptionMatch]:
    if not matches:
        return []
    matched_results = filter_results_by_subscription_size(
        subscription,
        [match.result for match in matches],
    )
    eligible_result_ids = {id(result) for result in matched_results}
    return [match for match in matches if id(match.result) in eligible_result_ids]


def _subscription_refresh_history_models(rows: list[dict]) -> list[SubscriptionRefreshHistory]:
    return [_refresh_history_model(item) for item in rows]


def _normalized_preview_keys(value: str | None) -> set[str]:
    if value is None:
        return set()
    raw = value.strip()
    if not raw:
        return set()
    normalized = raw.replace("\\", "/")
    name = PurePosixPath(normalized).name
    stem = PurePosixPath(name).stem if name else ""
    keys = {raw.casefold(), normalized.casefold()}
    if name:
        keys.add(name.casefold())
    if stem:
        keys.add(stem.casefold())
    return keys


def _organize_preview_keys(store: Store) -> set[str]:
    keys: set[str] = set()
    for record in store.list_organize_previews(limit=200):
        request = record["request"]
        preview = record["preview"]
        for value in (
            request.get("source_path"),
            request.get("original_filename"),
            preview.get("source_path"),
            preview.get("filename"),
            preview.get("destination_preview"),
        ):
            keys.update(_normalized_preview_keys(value))
    return keys


def _organize_done_keys(store: Store) -> set[str]:
    keys: set[str] = set()
    for record in store.list_organize_history(limit=500):
        if record["status"] not in {"moved", "skipped"}:
            continue
        preview = record["preview"]
        for value in (
            record.get("source_path"),
            record.get("destination_path"),
            preview.get("source_path"),
            preview.get("filename"),
            preview.get("destination_preview"),
        ):
            keys.update(_normalized_preview_keys(value))
    return keys


def _subscription_latest_organized_at(
    subscription_id: int,
    store: Store,
    organized_times: dict[int, str] | None = None,
) -> datetime | None:
    times = organized_times if organized_times is not None else store.latest_successful_organize_times()
    value = times.get(subscription_id)
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def _organize_preview_status(match: SubscriptionMatch, preview_keys: set[str], done_keys: set[str]) -> str:
    candidate_keys: set[str] = set()
    candidate_keys.update(_normalized_preview_keys(match.result.title))
    candidate_keys.update(_normalized_preview_keys(match.parsed_title.original_title))
    if candidate_keys.intersection(done_keys):
        return "已整理"
    if not preview_keys:
        return "未知"
    return "已生成预览" if candidate_keys.intersection(preview_keys) else "未知"


def _subscription_detail_metadata_bindings(
    subscription_id: int,
    matches: list[SubscriptionMatch],
    store: Store,
) -> list[MetadataBindingRecord]:
    return shared_subscription_detail_metadata_bindings(subscription_id, matches, store)


def _subscription_detail_plex_mappings(
    metadata_bindings: list[MetadataBindingRecord],
    store: Store,
) -> list[PlexMappingRecord]:
    return shared_subscription_detail_plex_mappings(metadata_bindings, store)


def _media_target_for_subscription(subscription: Subscription, store: Store) -> OrganizeTarget | None:
    return shared_media_target_for_subscription(subscription, store)


def _build_episode_media_index(
    subscription: Subscription,
    organize_target: OrganizeTarget | None,
    mapping: PlexSeasonMapping,
    store: Store,
) -> _EpisodeMediaIndex:
    return build_shared_episode_media_index(subscription, organize_target, mapping, store)


def _exact_history_source_exists(history: DownloadHistory) -> bool:
    candidates: list[Path] = []
    if history.save_path:
        save_path = Path(history.save_path).expanduser()
        if save_path.is_file():
            candidates.append(save_path)
        if history.torrent_name:
            torrent_path = Path(history.torrent_name).expanduser()
            candidates.append(torrent_path if torrent_path.is_absolute() else save_path / torrent_path)
    elif history.torrent_name:
        torrent_path = Path(history.torrent_name).expanduser()
        if torrent_path.is_absolute():
            candidates.append(torrent_path)
    for candidate in candidates:
        try:
            if candidate.is_file() and candidate.stat().st_size > 0:
                return True
            if candidate.is_dir():
                return True
        except OSError:
            continue
    return False


def _resolve_episode_organize_state(
    key: tuple[int, int],
    resources: list[SubscriptionEpisodeResource],
    history_by_id: dict[int, DownloadHistory],
    media_index: _EpisodeMediaIndex | None,
) -> _EpisodeOrganizeState | None:
    if media_index is None:
        return None
    if not media_index.target_available:
        if (
            media_index.unavailable_reason == "整理目标存储暂时不可访问"
            and key in media_index.prior_organized_keys
        ):
            return _EpisodeOrganizeState(
                status="已整理",
                detail="整理目标存储暂时不可访问，已保留已整理状态",
            )
        return None
    file_state = media_index.states.get(key)
    if file_state is not None:
        if file_state.status != "已整理":
            return file_state
        if any(item.organize_status == "整理失败" for item in resources):
            return _EpisodeOrganizeState(
                status="已整理",
                detail="媒体文件已存在，新下载版本待处理",
                candidate_count=file_state.candidate_count,
            )
        if any(item.download_status == "已移除任务" for item in resources):
            return _EpisodeOrganizeState(
                status="已整理",
                detail="整理目标文件存在；下载任务已移除",
                candidate_count=file_state.candidate_count,
            )
        return file_state

    related_history = [
        history_by_id[item.download_record_id]
        for item in resources
        if item.download_record_id is not None and item.download_record_id in history_by_id
    ]
    previously_organized = any(
        item.organize_status in {"已整理", "整理失败", "待重新整理", "需要检查"}
        or item.derived_status in {"已整理", "已整理并移除任务", "已停止做种", "等待重新整理"}
        for item in resources
    ) or any(
        item.status in {"organized", "organized_task_removed", "seeding_stopped"}
        for item in related_history
    )
    if not previously_organized:
        return None
    if any(_exact_history_source_exists(item) for item in related_history):
        return _EpisodeOrganizeState(
            status="等待重新整理",
            detail="整理目标已不存在，原下载文件仍可用于重新整理",
        )
    return _EpisodeOrganizeState(
        status="需要检查",
        detail="整理目标和原下载文件均不存在",
    )


def _episode_statuses(
    matches: list[SubscriptionMatch],
    history: list[DownloadHistory],
    preview_keys: set[str] | None = None,
    done_keys: set[str] | None = None,
) -> list[SubscriptionEpisodeStatus]:
    history_by_fingerprint = {item.fingerprint: item for item in history}
    preview_keys = preview_keys or set()
    done_keys = done_keys or set()
    statuses: list[SubscriptionEpisodeStatus] = []
    for item in matches:
        download_history = history_by_fingerprint.get(item.fingerprint)
        if download_history is None:
            download_status = "未提交"
        elif download_history.status == "queued":
            download_status = "已提交下载"
        elif download_history.status == "pending_confirmation":
            download_status = "等待下载器确认"
        elif download_history.status == "dry_run":
            download_status = "试运行记录"
        elif download_history.status == "error":
            download_status = "提交失败"
        elif download_history.status in {"organized", "organized_task_removed", "seeding_stopped"}:
            download_status = "已完成"
        elif download_history.status == "deleted":
            download_status = "已移除任务"
        else:
            download_status = download_history.status
        completion_status = "未知（暂未检测）"
        if download_history and download_history.qbittorrent:
            completion_status = download_history.qbittorrent.message
        organize_status = _organize_preview_status(item, preview_keys, done_keys)
        if download_history and download_history.organize_status == "已整理":
            organize_status = "已整理"
        derived_status, derived_detail = _resource_derived_status(download_history, organize_status)
        statuses.append(
            SubscriptionEpisodeStatus(
                match_id=item.id,
                download_history_id=download_history.id if download_history else None,
                title=item.result.title,
                source=item.result.source,
                episode=item.parsed_title.episode,
                season=item.parsed_title.season,
                resolution=item.parsed_title.resolution,
                match_status=item.status,
                download_status=download_status,
                completion_status=completion_status,
                qbittorrent=download_history.qbittorrent if download_history else None,
                organize_preview_status=organize_status,
                derived_status=derived_status,
                derived_status_detail=derived_detail,
                last_seen_at=item.last_seen_at,
            )
        )
    return statuses


def _episode_display_title(number: int, title: str | None = None) -> str:
    prefix = f"第 {number:02d} 集"
    if title:
        return f"{prefix} · {title}"
    return prefix


def _episode_title_key(value: Any) -> int | None:
    if isinstance(value, int):
        return value if value > 0 else None
    match = re.search(r"\d+", str(value))
    if not match:
        return None
    number = int(match.group(0))
    return number if number > 0 else None


def _episode_titles_from_bindings(metadata_bindings: list[MetadataBindingRecord]) -> tuple[dict[int, str], str | None]:
    current_binding = next(
        (binding for binding in metadata_bindings if binding.target_type == "subscription"),
        None,
    )
    candidates = [current_binding] if current_binding is not None else metadata_bindings
    for binding in candidates:
        titles: dict[int, str] = {}
        for raw_key, raw_title in binding.episode_titles.items():
            number = _episode_title_key(raw_key)
            title = str(raw_title).strip() if raw_title is not None else ""
            if number is not None and title:
                titles[number] = title
        if titles:
            source = "bangumi" if binding.bangumi_id else "tmdb" if binding.tmdb_id else "metadata"
            return titles, source
    return {}, None


def _resource_download_status(history: DownloadHistory | None) -> str:
    if history is None:
        return "未提交"
    if history.status == "queued":
        if history.qbittorrent and history.qbittorrent.progress is not None and history.qbittorrent.progress >= 0.999:
            return "已完成"
        if history.qbittorrent and history.qbittorrent.matched:
            return "下载中"
        return "已提交下载"
    if history.status == "pending_confirmation":
        return "等待下载器确认"
    if history.status == "dry_run":
        return "试运行记录"
    if history.status == "error":
        return "提交失败"
    if history.status in {"completed", "organized", "organized_task_removed", "seeding_stopped"}:
        return "已完成"
    if history.status == "deleted":
        return "已移除任务"
    return history.status


def _qb_progress_detail(qb: QbittorrentTaskProgress | None) -> str | None:
    if not qb:
        return None
    bits: list[str] = []
    if qb.state_label:
        bits.append(qb.state_label)
    if qb.progress_percent is not None:
        bits.append(f"{qb.progress_percent:g}%")
    if qb.download_speed is not None and qb.download_speed > 0:
        bits.append(_format_bytes_per_second(qb.download_speed))
    if qb.ratio is not None and qb.progress is not None and qb.progress >= 0.999:
        bits.append(f"分享率 {qb.ratio:.2f}")
    return " · ".join(bits) if bits else None


def _resource_derived_status(
    history: DownloadHistory | None,
    organize_status: str,
) -> tuple[str, str | None]:
    qb = history.qbittorrent if history else None
    qb_detail = _qb_progress_detail(qb)
    if history and history.status == "error":
        return "错误", "提交下载失败"
    if history and history.status == "pending_confirmation":
        return "等待下载器确认", "请求已发送，正在确认下载器任务"
    if history and history.status == "organized_task_removed":
        return "已整理并移除任务", None
    if history and history.status == "seeding_stopped":
        return "已停止做种", qb_detail
    if organize_status == "整理失败":
        detail = history.derived_status_detail if history and history.organize_status == "整理失败" else None
        return "整理失败", detail or "上次整理失败"
    if organize_status == "待重新整理":
        detail = history.derived_status_detail if history and history.organize_status == "待重新整理" else None
        return "等待重新整理", detail or "整理目标已不存在，将由后台自动重新整理"
    if organize_status == "需要检查":
        detail = history.derived_status_detail if history and history.organize_status == "需要检查" else None
        return "需要检查", detail or "存在成功整理记录，但目标文件已不存在"
    if organize_status == "已整理":
        detail = qb_detail
        if qb_detail and "做种" in qb_detail:
            detail = f"已整理 · {qb_detail}"
        return "已整理", detail
    if history is None:
        return "已匹配，未下载", None
    if history.status == "dry_run":
        return "试运行记录", None
    if history.status == "deleted":
        return "已移除任务", None
    if history.status == "completed":
        return "下载完成，待整理", qb_detail
    if history.status == "queued":
        if qb and qb.progress is not None and qb.progress >= 0.999:
            return "下载完成，待整理", qb_detail
        if qb and qb.matched:
            return "下载中", qb_detail
        return "已提交下载", None
    return str(history.status), qb_detail


def _episode_download_status(resources: list[SubscriptionEpisodeResource], subscription: Subscription) -> str:
    if not resources:
        return "等待订阅刷新" if subscription.auto_download else "未匹配资源"
    statuses = [item.download_status for item in resources]
    if "已完成" in statuses:
        return "已完成"
    if "下载中" in statuses:
        return "下载中"
    if "已提交下载" in statuses:
        return "已提交下载"
    if "试运行记录" in statuses:
        return "试运行记录"
    return "未提交"


def _episode_derived_status(resources: list[SubscriptionEpisodeResource], subscription: Subscription) -> tuple[str, str | None]:
    if not resources:
        return ("等待订阅刷新" if subscription.auto_download else "未匹配资源"), None
    statuses = [item.derived_status for item in resources]
    detail = next((item.derived_status_detail for item in resources if item.derived_status_detail), None)
    order = [
        "错误",
        "整理失败",
        "需要检查",
        "等待重新整理",
        "已整理并移除任务",
        "已停止做种",
        "已整理",
        "下载完成，待整理",
        "下载中",
        "已提交下载",
        "试运行记录",
        "已匹配，未下载",
        "合集待整理",
        "合集资源可用",
        "多集资源可用",
        "已移除任务",
    ]
    for status in order:
        if status in statuses:
            return status, detail
    return statuses[0] if statuses else "未匹配资源", detail


def _derived_status_rank(status: str) -> int:
    order = [
        "错误",
        "整理失败",
        "需要检查",
        "等待重新整理",
        "已整理并移除任务",
        "已停止做种",
        "已整理",
        "合集待整理",
        "下载完成，待整理",
        "下载中",
        "已提交下载",
        "试运行记录",
        "合集资源可用",
        "多集资源可用",
        "已匹配，未下载",
        "已移除任务",
        "未匹配资源",
    ]
    try:
        return order.index(status)
    except ValueError:
        return len(order)


def _episode_organize_status(resources: list[SubscriptionEpisodeResource]) -> str:
    if not resources:
        return "未知"
    if any(item.organize_status == "整理失败" for item in resources):
        return "整理失败"
    if any(item.organize_status == "待重新整理" for item in resources):
        return "待重新整理"
    if any(item.organize_status == "已整理" for item in resources):
        return "已整理"
    if any(item.organize_status == "需要检查" for item in resources):
        return "需要检查"
    if any(item.organize_status == "已生成预览" for item in resources):
        return "已生成预览"
    return "未整理"


def _resource_is_download_complete(item: SubscriptionEpisodeResource) -> bool:
    if item.download_status == "已完成":
        return True
    return bool(item.qbittorrent and item.qbittorrent.progress is not None and item.qbittorrent.progress >= 0.999)


def _auto_organize_status(subscription: Subscription, resources: list[SubscriptionEpisodeResource]) -> str:
    if not subscription.auto_organize:
        return "未开启"
    if not resources:
        return "等待匹配资源"
    if any(item.organize_status == "整理失败" for item in resources):
        return "整理失败"
    if any(item.organize_status == "待重新整理" for item in resources):
        return "等待重新整理"
    if any(item.organize_status == "已整理" for item in resources):
        return "已整理"
    if any(item.organize_status == "需要检查" for item in resources):
        return "需要检查"
    if any(_resource_is_download_complete(item) for item in resources):
        return "等待整理"
    if any(item.download_status in {"已提交下载", "下载中"} for item in resources):
        return "等待下载完成"
    return "等待下载"


def _organize_available(resources: list[SubscriptionEpisodeResource]) -> bool:
    return any(
        item.organize_status not in {"已整理", "需要检查", "整理失败"}
        and item.download_record_id is not None
        and _resource_is_download_complete(item)
        for item in resources
    )


def _logical_episode_projection(
    subscription: Subscription,
    resources: list[SubscriptionEpisodeResource],
    resolved_state: _EpisodeOrganizeState | None,
) -> tuple[str, str, str | None, str, bool]:
    if resolved_state is None:
        derived_status, derived_detail = _episode_derived_status(resources, subscription)
        return (
            _episode_organize_status(resources),
            derived_status,
            derived_detail,
            _auto_organize_status(subscription, resources),
            _organize_available(resources),
        )
    if resolved_state.status == "已整理":
        return (
            "已整理",
            "已整理",
            resolved_state.detail,
            "已整理" if subscription.auto_organize else "未开启",
            False,
        )
    if resolved_state.status == "等待重新整理":
        return (
            "待重新整理",
            "等待重新整理",
            resolved_state.detail,
            "等待重新整理" if subscription.auto_organize else "未开启",
            True,
        )
    return (
        "需要检查",
        "需要检查",
        resolved_state.detail,
        "需要检查" if subscription.auto_organize else "未开启",
        False,
    )


def _episode_resource(
    subscription: Subscription,
    match: SubscriptionMatch,
    history: DownloadHistory | None,
    preview_keys: set[str],
    done_keys: set[str],
) -> SubscriptionEpisodeResource:
    organize_status = _organize_preview_status(match, preview_keys, done_keys)
    if history and history.organize_status in {"已整理", "需要检查", "整理失败", "待重新整理"}:
        organize_status = history.organize_status
    derived_status, derived_detail = _resource_derived_status(history, organize_status)
    status = match.status
    if history is None and match.parsed_title.resource_type in {"batch", "episode_range"}:
        derived_status = "合集资源可用" if match.parsed_title.resource_type == "batch" else "多集资源可用"
        derived_detail = "默认不自动下载，避免重复下载整季" if match.parsed_title.is_batch else "覆盖多个集数，手动确认后可下载"
    elif (
        match.parsed_title.is_batch
        and history is not None
        and history.qbittorrent is not None
        and history.qbittorrent.progress is not None
        and history.qbittorrent.progress >= 0.999
        and organize_status != "已整理"
    ):
        derived_status = "合集待整理"
        derived_detail = "这是合集资源，整理前请确认单文件或多文件结构"
    conflict_message = _season_conflict_message(subscription, match.parsed_title)
    if conflict_message:
        status = "needs_review"
        derived_status = "发现可能属于其它季度的资源"
        derived_detail = conflict_message
    url = match.result.download_url or match.result.magnet_url
    episode_mapping = _episode_mapping_payload(subscription, match.parsed_title)
    return SubscriptionEpisodeResource(
        match_id=match.id,
        raw_title=match.result.title,
        site=match.result.source,
        fansub_group=match.parsed_title.fansub,
        resolution=match.parsed_title.resolution,
        size=match.result.size,
        publish_time=match.result.published_at,
        download_link=url,
        magnet=match.result.magnet_url,
        torrent_hash=history.qbittorrent_hash if history else _btih_from_url(url),
        download_record_id=history.id if history else None,
        match_score=match.parsed_title.confidence,
        status=status,
        download_status=_resource_download_status(history),
        organize_status=organize_status,
        qbittorrent=history.qbittorrent if history else None,
        derived_status=derived_status,
        derived_status_detail=derived_detail,
        resource_type=match.parsed_title.resource_type,
        display_episode_label=match.parsed_title.display_episode_label,
        episode_start=match.parsed_title.episode_start,
        episode_end=match.parsed_title.episode_end,
        absolute_episode_start=match.parsed_title.absolute_episode_start,
        absolute_episode_end=match.parsed_title.absolute_episode_end,
        season_episode_start=match.parsed_title.season_episode_start,
        season_episode_end=match.parsed_title.season_episode_end,
        logical_episode_start=episode_mapping["logical_episode_start"],
        logical_episode_end=episode_mapping["logical_episode_end"],
        episode_offset_applied=episode_mapping["episode_offset_applied"],
        episode_mapping_label=episode_mapping["episode_mapping_label"],
        is_batch=match.parsed_title.is_batch,
        is_multi_episode=match.parsed_title.is_multi_episode,
    )


def _subscription_total_episodes(subscription: Subscription, metadata_bindings: list[MetadataBindingRecord]) -> tuple[int | None, str | None]:
    if subscription.total_episodes is not None:
        return subscription.total_episodes, subscription.total_episodes_source or "manual"
    current_binding = shared_current_subscription_metadata_binding(subscription.id, metadata_bindings)
    candidates = [current_binding] if current_binding is not None else metadata_bindings
    for binding in candidates:
        if binding.total_episodes:
            source = "bangumi" if binding.bangumi_id else "tmdb" if binding.tmdb_id else "unknown"
            return binding.total_episodes, source
    return subscription.metadata_episode_count, "metadata" if subscription.metadata_episode_count else None


def _logical_episode_statuses(
    subscription: Subscription,
    matches: list[SubscriptionMatch],
    history: list[DownloadHistory],
    metadata_bindings: list[MetadataBindingRecord],
    preview_keys: set[str],
    done_keys: set[str],
    media_index: _EpisodeMediaIndex | None = None,
) -> tuple[list[SubscriptionLogicalEpisodeStatus], list[SubscriptionEpisodeResource]]:
    history_by_fingerprint = {item.fingerprint: item for item in history}
    history_by_id = {item.id: item for item in history}
    resources_by_key: dict[tuple[int, int], list[SubscriptionEpisodeResource]] = {}
    unmatched_resources: list[SubscriptionEpisodeResource] = []
    for match in matches:
        season_number = match.parsed_title.season or subscription.season or 1
        history_item = history_by_fingerprint.get(match.fingerprint)
        resource = _episode_resource(subscription, match, history_item, preview_keys, done_keys)
        if resource.status == "needs_review":
            unmatched_resources.append(resource)
            continue
        covered_episodes = _subscription_logical_episode_numbers(subscription, match.parsed_title)
        if match.parsed_title.resource_type == "special" or not covered_episodes:
            unmatched_resources.append(resource)
            continue
        for episode_number in covered_episodes:
            resources_by_key.setdefault((season_number, episode_number), []).append(resource)

    total_episodes, source = _subscription_total_episodes(subscription, metadata_bindings)
    episode_titles, title_source = _episode_titles_from_bindings(metadata_bindings)

    season_number = subscription.season or 1
    if resources_by_key and subscription.season is None:
        season_number = min(season for (season, _) in resources_by_key)

    records: list[SubscriptionLogicalEpisodeStatus] = []
    for episode_number in range(1, (total_episodes or 0) + 1):
        episode_title = episode_titles.get(episode_number)
        resources = sorted(
            resources_by_key.get((season_number, episode_number), []),
            key=lambda item: (item.publish_time or "", item.raw_title),
            reverse=True,
        )
        resources = sorted(
            resources,
            key=lambda item: item.resource_type in {"batch", "episode_range"} or item.is_batch or item.is_multi_episode,
        )
        last_matched = None
        matching_records = [
            match.last_seen_at
            for match in matches
            if (match.parsed_title.season or subscription.season or 1) == season_number
            and episode_number
            in _subscription_logical_episode_numbers(subscription, match.parsed_title)
        ]
        if matching_records:
            last_matched = max(matching_records)
        excluded_by_episode_start = not shared_subscription_episode_in_target_scope(subscription, episode_number)
        if excluded_by_episode_start:
            download_status = "已跳过"
            organize_status = "已跳过"
            derived_status = "已跳过"
            derived_detail = "起始集数前"
            auto_organize_status = "已跳过"
            organize_available = False
        else:
            resolved_state = _resolve_episode_organize_state(
                (season_number, episode_number),
                resources,
                history_by_id,
                media_index,
            )
            organize_status, derived_status, derived_detail, auto_organize_status, organize_available = (
                _logical_episode_projection(subscription, resources, resolved_state)
            )
            download_status = _episode_download_status(resources, subscription)
        records.append(
            SubscriptionLogicalEpisodeStatus(
                season_number=season_number,
                episode_number=episode_number,
                episode_title=episode_title,
                display_title=_episode_display_title(episode_number, episode_title),
                metadata_source=title_source or source or "local",
                matched_resources=resources,
                download_status=download_status,
                organize_status=organize_status,
                auto_organize_status=auto_organize_status,
                derived_status=derived_status,
                derived_status_detail=derived_detail,
                organize_available=organize_available,
                excluded_by_episode_start=excluded_by_episode_start,
                last_matched_at=last_matched,
            )
        )

    if not records:
        for (season, episode_number), resources in sorted(resources_by_key.items()):
            episode_title = episode_titles.get(episode_number)
            excluded_by_episode_start = not shared_subscription_episode_in_target_scope(subscription, episode_number)
            if excluded_by_episode_start:
                download_status = "已跳过"
                organize_status = "已跳过"
                derived_status = "已跳过"
                derived_detail = "起始集数前"
                auto_organize_status = "已跳过"
                organize_available = False
            else:
                resolved_state = _resolve_episode_organize_state(
                    (season, episode_number),
                    resources,
                    history_by_id,
                    media_index,
                )
                organize_status, derived_status, derived_detail, auto_organize_status, organize_available = (
                    _logical_episode_projection(subscription, resources, resolved_state)
                )
                download_status = _episode_download_status(resources, subscription)
            records.append(
                SubscriptionLogicalEpisodeStatus(
                    season_number=season,
                    episode_number=episode_number,
                    episode_title=episode_title,
                    display_title=_episode_display_title(episode_number, episode_title),
                    metadata_source=title_source or "local",
                    matched_resources=resources,
                    download_status=download_status,
                    organize_status=organize_status,
                    auto_organize_status=auto_organize_status,
                    derived_status=derived_status,
                    derived_status_detail=derived_detail,
                    organize_available=organize_available,
                    excluded_by_episode_start=excluded_by_episode_start,
                    last_matched_at=max(
                        (
                            match.last_seen_at
                            for match in matches
                            if (match.parsed_title.season or subscription.season or 1) == season
                            and episode_number
                            in _subscription_logical_episode_numbers(subscription, match.parsed_title)
                        ),
                        default=None,
                    ),
                )
            )

    return records, unmatched_resources


def _season_number(subscription: Subscription, episode: SubscriptionEpisodeStatus) -> int:
    return episode.season or subscription.season or 1


def _season_title(season_number: int) -> str:
    return f"Season {season_number:02d}"


def _hierarchy_episodes(
    subscription: Subscription,
    episodes: list[SubscriptionEpisodeStatus],
) -> list[SubscriptionHierarchySeason]:
    seasons: dict[int, list[SubscriptionHierarchyEpisode]] = {}
    for episode in episodes:
        season_number = _season_number(subscription, episode)
        seasons.setdefault(season_number, []).append(
            SubscriptionHierarchyEpisode(
                match_id=episode.match_id,
                download_history_id=episode.download_history_id,
                title=episode.title,
                source=episode.source,
                episode_number=episode.episode,
                resolution=episode.resolution,
                download_status=episode.download_status,
                qbittorrent=episode.qbittorrent,
                organize_status=episode.organize_preview_status,
                derived_status=episode.derived_status,
                derived_status_detail=episode.derived_status_detail,
                downloaded=bool(episode.qbittorrent and episode.qbittorrent.progress is not None and episode.qbittorrent.progress >= 0.999),
                organized=episode.organize_preview_status == "已整理",
            )
        )

    season_nodes: list[SubscriptionHierarchySeason] = []
    for season_number, season_episodes in sorted(seasons.items()):
        season_nodes.append(
            SubscriptionHierarchySeason(
                season_number=season_number,
                title=_season_title(season_number),
                episodes=sorted(
                    season_episodes,
                    key=lambda item: (item.episode_number is None, item.episode_number or 0, item.title),
                ),
            )
        )
    return season_nodes


def _metadata_hierarchy(
    subscription: Subscription,
    metadata_bindings: list[MetadataBindingRecord],
    episodes: list[SubscriptionEpisodeStatus],
) -> list[SubscriptionMetadataHierarchy]:
    seasons = _hierarchy_episodes(subscription, episodes)
    cached_poster_path = _cached_subscription_poster_path(subscription.id)
    cached_subscription_poster_url = _poster_local_url(subscription.id) if cached_poster_path is not None else None
    cached_palette = _poster_palette_for_path(subscription.id, cached_poster_path)
    records: list[SubscriptionMetadataHierarchy] = []
    seen: set[tuple[str, str | None]] = set()

    current_binding = shared_current_subscription_metadata_binding(subscription.id, metadata_bindings)
    bindings = [current_binding] if current_binding is not None else metadata_bindings
    for binding in bindings:
        title = binding.selected_title or subscription.name
        if binding.bangumi_id and ("bangumi", binding.bangumi_id) not in seen:
            seen.add(("bangumi", binding.bangumi_id))
            records.append(
                SubscriptionMetadataHierarchy(
                    source="bangumi",
                    source_label="Bangumi",
                    external_id=binding.bangumi_id,
                    title=title,
                    original_title=binding.original_title,
                    chinese_title=binding.chinese_title,
                    aliases=binding.aliases,
                    subtitle="当前番剧数据源",
                    summary=binding.summary,
                    poster_url=binding.poster_url,
                    backdrop_url=binding.backdrop_url,
                    poster_local_url=(
                        binding.poster_local_url
                        if binding.local_poster_path and Path(binding.local_poster_path).exists()
                        else cached_subscription_poster_url
                    ),
                    poster_palette=_poster_palette_for_path(subscription.id, Path(binding.local_poster_path))
                    if binding.local_poster_path and Path(binding.local_poster_path).exists()
                    else cached_palette,
                    air_date=binding.air_date,
                    total_episodes=binding.total_episodes,
                    episode_titles=binding.episode_titles,
                    rating=binding.rating,
                    tags=binding.tags,
                    season_number=binding.season_number,
                    episode_count=binding.episode_count,
                    external_ids=binding.external_ids,
                    seasons=seasons,
                )
            )
        if binding.tmdb_id and ("tmdb", binding.tmdb_id) not in seen:
            seen.add(("tmdb", binding.tmdb_id))
            records.append(
                SubscriptionMetadataHierarchy(
                    source="tmdb",
                    source_label="TMDB",
                    external_id=binding.tmdb_id,
                    title=title,
                    original_title=binding.original_title,
                    chinese_title=binding.chinese_title,
                    aliases=binding.aliases,
                    subtitle="当前番剧数据源",
                    summary=binding.summary,
                    poster_url=binding.poster_url,
                    backdrop_url=binding.backdrop_url,
                    poster_local_url=(
                        binding.poster_local_url
                        if binding.local_poster_path and Path(binding.local_poster_path).exists()
                        else cached_subscription_poster_url
                    ),
                    poster_palette=_poster_palette_for_path(subscription.id, Path(binding.local_poster_path))
                    if binding.local_poster_path and Path(binding.local_poster_path).exists()
                    else cached_palette,
                    air_date=binding.air_date,
                    total_episodes=binding.total_episodes,
                    episode_titles=binding.episode_titles,
                    rating=binding.rating,
                    tags=binding.tags,
                    season_number=binding.season_number,
                    episode_count=binding.episode_count,
                    external_ids=binding.external_ids,
                    seasons=seasons,
                )
            )

    if not records:
        records.append(
            SubscriptionMetadataHierarchy(
                source="local",
                source_label="本地解析",
                title=subscription.name,
                subtitle="基于当前订阅匹配结果生成",
                poster_palette=cached_palette,
                seasons=seasons,
            )
        )
    return records


DEFAULT_SUBSCRIPTION_EXCLUDES = ["先行", "PV", "CM"]


def _download_save_path(base_path: str | None, title: str | None) -> str | None:
    path = subscription_download_directory(base_path, title)
    return str(path) if path is not None else None


def _enabled_managed_site_ids(store: Store) -> list[str]:
    return [
        site.id
        for site in list_sites(stored_site_settings(store), managed_site_ids(store))
        if site.enabled and not site.brush_only
    ]


def _brush_only_site_ids(store: Store, site_ids: list[str]) -> list[str]:
    settings = merge_site_settings(stored_site_settings(store))
    return sorted({site_id for site_id in site_ids if site_id in settings and settings[site_id].brush_only})


def _reject_new_brush_only_subscription_sites(
    request: SubscriptionCreate,
    store: Store,
    *,
    existing_site_ids: set[str] | None = None,
) -> None:
    existing_site_ids = existing_site_ids or set()
    restricted = _brush_only_site_ids(store, [site for site in request.sites if site not in existing_site_ids])
    if restricted:
        labels = "、".join(restricted)
        raise HTTPException(status_code=400, detail=f"以下站点已设为仅站点刷流，不能加入订阅：{labels}")


def _subscription_suggestion_sites(request: SubscriptionSuggestionRequest, store: Store) -> list[str]:
    managed_ids = managed_site_ids(store)
    enabled_sites = set(_enabled_managed_site_ids(store))
    if not managed_ids:
        enabled_sites = set(default_site_settings())
    sites = [normalize_site_id(site) for site in request.sites if site.strip()]
    sites = [site for site in sites if site in enabled_sites]
    if not sites and request.result.source:
        source_site = normalize_site_id(request.result.source)
        if source_site in enabled_sites:
            sites = [source_site]
    return sorted(set(sites)) or sorted(enabled_sites)


def _clean_suggested_keyword(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = re.sub(r"\.(mkv|mp4|avi|ass|srt)$", "", value.strip(), flags=re.I)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -_")
    return cleaned or None


def _mikan_subscription_source_for_result(result: SearchResult) -> str | None:
    if normalize_site_id(result.source) != "mikan":
        return None
    bangumi_id = str(result.mikan_bangumi_id or result.bangumi_id or "").strip()
    if not bangumi_id.isdigit():
        return None
    source = f"https://mikanani.me/Home/Bangumi/{bangumi_id}"
    group_id = str(result.mikan_group_id or "").strip()
    return f"{source}#{group_id}" if group_id.isdigit() else source


def _normalized_identity_text(value: str | None) -> str:
    return normalized_identity_text(value)


def _mikan_bangumi_id_from_url(value: str | None) -> str | None:
    return mikan_bangumi_id_from_value(value)


def _subscription_values(value: SubscriptionCreate | dict[str, Any]) -> dict[str, Any]:
    if isinstance(value, SubscriptionCreate):
        return value.model_dump(mode="json")
    return value


def _subscription_stable_identity(value: SubscriptionCreate | dict[str, Any]) -> str | None:
    data = _subscription_values(value)
    mikan_ids = subscription_mikan_bangumi_ids(data)
    if len(mikan_ids) == 1:
        return f"mikan:bangumi:{next(iter(mikan_ids))}"
    if len(mikan_ids) > 1:
        digest = hashlib.sha256("\n".join(sorted(mikan_ids)).encode("utf-8")).hexdigest()
        return f"mikan:conflict:{digest}"
    identity_key = str(data.get("identity_key") or "").strip().casefold()
    if identity_key:
        return identity_key
    if data.get("source_type") == "rss":
        urls = sorted(
            _normalized_identity_text(str(item).rstrip("/"))
            for item in data.get("rss_urls") or []
            if str(item).strip()
        )
        if urls:
            digest = hashlib.sha256("\n".join(urls).encode("utf-8")).hexdigest()
            return f"rss:v1:{digest}"
    return None


def _smart_subscription_identity_key(result: SearchResult, suggestion: SubscriptionCreate) -> str:
    mikan_id = str(result.mikan_bangumi_id or "").strip()
    if normalize_site_id(result.source) == "mikan" and mikan_id.isdigit():
        return f"mikan:bangumi:{mikan_id}"
    bangumi_id = str(result.bangumi_id or "").strip()
    if bangumi_id.isdigit():
        return f"bangumi:subject:{bangumi_id}"
    source_type = suggestion.source_type
    title = _normalized_identity_text(suggestion.keyword or suggestion.name)
    season = "none" if suggestion.season is None else str(suggestion.season)
    sites = ",".join(sorted(suggestion.sites))
    digest = hashlib.sha256(f"{source_type}|{title}|{season}|{sites}".encode("utf-8")).hexdigest()
    return f"keyword:v1:{digest}"


@dataclass(frozen=True)
class _SubscriptionIdentityResolution:
    status: Literal["none", "matched", "ambiguous"]
    reason: str | None
    candidates: tuple[dict[str, Any], ...] = ()


def _strict_title_identity_match(
    suggestion: SubscriptionCreate,
    candidate: dict[str, Any],
) -> bool:
    candidate_identity = _subscription_stable_identity(candidate)
    if candidate_identity and not candidate_identity.startswith("keyword:v1:"):
        return False
    candidate_source_type = str(candidate.get("source_type") or "keyword")
    candidate_sites = set(candidate.get("sites") or [])
    same_source_type = candidate_source_type == suggestion.source_type
    legacy_mikan_source = (
        suggestion.source_type == "mikan_bangumi"
        and candidate_source_type == "keyword"
        and "mikan" in candidate_sites
    )
    if not same_source_type and not legacy_mikan_source:
        return False
    suggestion_titles = title_identity_keys([suggestion.keyword, suggestion.name, *suggestion.aliases])
    candidate_titles = title_identity_keys(
        [
            str(candidate.get("keyword") or ""),
            str(candidate.get("name") or ""),
            *(str(item) for item in candidate.get("aliases") or []),
        ]
    )
    if not suggestion_titles.intersection(candidate_titles):
        return False
    if candidate.get("season") != suggestion.season:
        return False
    suggested_sites = set(suggestion.sites)
    return not suggested_sites or not candidate_sites or not suggested_sites.isdisjoint(candidate_sites)


def _resolve_subscription_identity(
    suggestion: SubscriptionCreate,
    store: Store,
    *,
    exclude_subscription_id: int | None = None,
) -> _SubscriptionIdentityResolution:
    subscriptions = [
        item
        for item in store.list_subscriptions()
        if exclude_subscription_id is None or int(item["id"]) != exclude_subscription_id
    ]
    identity_key = _subscription_stable_identity(suggestion)
    exact_candidates = tuple(
        item
        for item in subscriptions
        if identity_key is not None and _subscription_stable_identity(item) == identity_key
    )
    if len(exact_candidates) == 1:
        return _SubscriptionIdentityResolution("matched", "稳定订阅标识一致", exact_candidates)
    if len(exact_candidates) > 1:
        return _SubscriptionIdentityResolution("ambiguous", "同一稳定订阅标识对应多个订阅", exact_candidates)
    fallback_candidates = tuple(
        item for item in subscriptions if _strict_title_identity_match(suggestion, item)
    )
    if len(fallback_candidates) == 1:
        return _SubscriptionIdentityResolution("matched", "标题、来源和季度完全一致", fallback_candidates)
    if len(fallback_candidates) > 1:
        return _SubscriptionIdentityResolution("ambiguous", "标题回退匹配到多个订阅", fallback_candidates)
    if identity_key and not identity_key.startswith("keyword:v1:"):
        return _SubscriptionIdentityResolution("none", "未找到相同稳定订阅标识或唯一旧订阅")
    return _SubscriptionIdentityResolution("none", "订阅列表中没有对应番剧")


def _similar_subscription(
    suggestion: SubscriptionCreate,
    store: Store,
    exclude_subscription_id: int | None = None,
) -> tuple[int | None, str | None]:
    suggested_sites = set(suggestion.sites)
    for item in store.list_subscriptions():
        if exclude_subscription_id is not None and int(item["id"]) == exclude_subscription_id:
            continue
        if item["keyword"].casefold() != suggestion.keyword.casefold():
            continue
        if suggested_sites and suggested_sites.isdisjoint(set(item.get("sites") or [])):
            continue
        if (item.get("fansub") or "").casefold() != (suggestion.fansub or "").casefold():
            continue
        if (item.get("resolution") or "").casefold() != (suggestion.resolution or "").casefold():
            continue
        if (item.get("regex") or "").casefold() != (suggestion.regex or "").casefold():
            continue
        if item.get("season") != suggestion.season:
            continue
        if item.get("episode") != suggestion.episode:
            continue
        if (item.get("episode_start") or 1) != suggestion.episode_start:
            continue
        return int(item["id"]), str(item["name"])
    return None, None


def _reject_duplicate_subscription(
    request: SubscriptionCreate,
    store: Store,
    *,
    exclude_subscription_id: int | None = None,
) -> None:
    identity = _resolve_subscription_identity(
        request,
        store,
        exclude_subscription_id=exclude_subscription_id,
    )
    if request.identity_key and identity.status != "none":
        candidate_ids = "、".join(f"#{item['id']}" for item in identity.candidates)
        raise HTTPException(
            status_code=409,
            detail=f"智能订阅对应的现有订阅为 {candidate_ids}，请更新原订阅。",
        )
    duplicate_id, duplicate_name = _similar_subscription(
        request,
        store,
        exclude_subscription_id=exclude_subscription_id,
    )
    if duplicate_id is not None:
        raise HTTPException(
            status_code=409,
            detail=f"已存在相同规则订阅：{duplicate_name}（#{duplicate_id}），请编辑原订阅或调整过滤条件。",
        )


def _build_subscription_suggestion(
    request: SubscriptionSuggestionRequest,
    store: Store,
) -> SubscriptionSuggestionResponse:
    parsed = parse_title(request.result.title)
    keyword = _clean_suggested_keyword(parsed.title)
    warnings: list[str] = []
    if not keyword:
        return SubscriptionSuggestionResponse(
            ok=False,
            message="无法从资源标题中识别番剧名称，请手动填写订阅关键词。",
            parsed_title=parsed,
            confidence=parsed.confidence,
            warnings=["未识别到可用番名"],
        )

    if parsed.needs_confirmation:
        warnings.append("标题解析置信度偏低，请确认番名和过滤条件。")

    exclude_keywords = [item for item in DEFAULT_SUBSCRIPTION_EXCLUDES if item.casefold() not in keyword.casefold()]
    suggested_season = parsed.explicit_season_number
    mikan_source = _mikan_subscription_source_for_result(request.result)
    if parsed.inferred_season_number is not None and parsed.explicit_season_number is None:
        warnings.append("标题只识别到合集范围，Season 需要按你的订阅意图确认。")
    parsed_resolution_preset = normalize_resolution_preset(parsed.resolution)
    suggestion = SubscriptionCreate(
        name=keyword,
        keyword=keyword,
        source_type="mikan_bangumi" if mikan_source else "keyword",
        sites=_subscription_suggestion_sites(request, store),
        source_url=mikan_source,
        mikan_bangumi_url=mikan_source,
        rss_urls=[],
        regex=None,
        include_keywords=[],
        exclude_keywords=exclude_keywords,
        filter_order="include_first",
        fansub=parsed.fansub,
        resolution=parsed_resolution_preset or parsed.resolution,
        resolution_mode="preset" if parsed_resolution_preset else ("custom" if parsed.resolution else "any"),
        resolution_preset=parsed_resolution_preset,
        resolution_custom=parsed.resolution if parsed.resolution and not parsed_resolution_preset else None,
        season=suggested_season,
        episode=None,
        episode_start=1,
        episode_offset=0,
        enabled=True,
        auto_download=True,
        organize_target_id=request.organize_target_id,
        auto_organize=request.organize_target_id is not None,
        save_path=request.save_path,
        category=request.category or "anime",
        tags=request.tags or ["kisetsu"],
    )
    suggestion = suggestion.model_copy(
        update={"identity_key": _smart_subscription_identity_key(request.result, suggestion)}
    )
    suggestion = _with_default_organize_target(suggestion, store)
    duplicate_id, duplicate_name = _similar_subscription(suggestion, store)
    if duplicate_id is not None:
        warnings.append(f"可能已存在相同规则订阅：{duplicate_name}（#{duplicate_id}）")

    bits = [f"番名：{keyword}"]
    if parsed.fansub:
        bits.append(f"字幕组：{parsed.fansub}")
    if parsed.resolution:
        bits.append(f"分辨率：{parsed.resolution}")
    if suggested_season is not None:
        bits.append(f"Season {suggested_season}")
    bits.append("从第 1 集开始")

    return SubscriptionSuggestionResponse(
        ok=True,
        message="已生成订阅建议：" + "，".join(bits),
        parsed_title=parsed,
        suggestion=suggestion,
        confidence=parsed.confidence,
        warnings=warnings,
        duplicate_subscription_id=duplicate_id,
        duplicate_subscription_name=duplicate_name,
    )


def _prefill_include_keywords(ai_result: AITitleAnalysisResponse) -> list[str]:
    subtitle_language = str(ai_result.subtitle_language or "").strip()
    if not subtitle_language:
        return []

    candidates = [subtitle_language]
    for tag in ai_result.source_tags:
        if tag.upper() in {"BAHA", "WEB-DL", "WEBRIP", "BDRIP"}:
            candidates.append(tag)
    return list(dict.fromkeys(candidates[:4]))


def _apply_ai_to_subscription_suggestion(
    suggestion: SubscriptionCreate,
    ai_result: AITitleAnalysisResponse,
) -> SubscriptionCreate:
    data = suggestion.model_dump(mode="json")
    if ai_result.anime_title:
        data["name"] = ai_result.anime_title
        data["keyword"] = ai_result.anime_title
    if ai_result.anime_title_aliases:
        data["aliases"] = list(dict.fromkeys([*data.get("aliases", []), *ai_result.anime_title_aliases]))
    if ai_result.fansub:
        data["fansub"] = ai_result.fansub
    if ai_result.resolution:
        resolution_preset = normalize_resolution_preset(ai_result.resolution)
        data["resolution"] = resolution_preset or ai_result.resolution
        data["resolution_mode"] = "preset" if resolution_preset else "custom"
        data["resolution_preset"] = resolution_preset
        data["resolution_custom"] = None if resolution_preset else ai_result.resolution
    include_keywords = list(data.get("include_keywords") or [])
    include_keywords.extend(_prefill_include_keywords(ai_result))
    data["include_keywords"] = list(dict.fromkeys([item for item in include_keywords if item]))
    data["episode_start"] = 1
    return SubscriptionCreate(**data)


async def _build_smart_subscription_prefill(
    request: SmartSubscriptionPrefillRequest,
    store: Store,
) -> SmartSubscriptionPrefillResponse:
    local_response = _build_subscription_suggestion(request, store)
    if not local_response.ok or local_response.suggestion is None:
        return SmartSubscriptionPrefillResponse(
            ok=local_response.ok,
            message=local_response.message,
            form_defaults=local_response.suggestion,
            local_result=local_response.parsed_title,
            source="local",
            warnings=local_response.warnings,
            duplicate_subscription_id=local_response.duplicate_subscription_id,
            duplicate_subscription_name=local_response.duplicate_subscription_name,
        )

    settings = stored_ai_settings(store)
    use_ai = settings.use_ai_for_smart_subscription if request.use_ai is None else bool(request.use_ai)
    warnings = list(local_response.warnings)
    if not use_ai:
        return SmartSubscriptionPrefillResponse(
            ok=True,
            message="已使用本地解析填入订阅表单。",
            form_defaults=local_response.suggestion,
            local_result=local_response.parsed_title,
            source="local",
            warnings=warnings,
            duplicate_subscription_id=local_response.duplicate_subscription_id,
            duplicate_subscription_name=local_response.duplicate_subscription_name,
        )

    ai_result = await _call_ai_title_analysis(
        settings,
        AITitleAnalyzeRequest(title=request.result.title, site=request.result.source, local_parse=local_response.parsed_title),
        suggest_rule=False,
    )
    if not ai_result.ok:
        warnings.append("AI 分析失败，已使用本地解析。")
        warnings.extend(ai_result.warnings)
        return SmartSubscriptionPrefillResponse(
            ok=True,
            message="AI 分析失败，已使用本地解析。",
            form_defaults=local_response.suggestion,
            ai_result=ai_result,
            local_result=local_response.parsed_title,
            source="local",
            warnings=warnings,
            duplicate_subscription_id=local_response.duplicate_subscription_id,
            duplicate_subscription_name=local_response.duplicate_subscription_name,
        )

    suggestion = _apply_ai_to_subscription_suggestion(local_response.suggestion, ai_result)
    duplicate_id, duplicate_name = _similar_subscription(suggestion, store)
    if duplicate_id is not None:
        warnings.append(f"可能已存在相同规则订阅：{duplicate_name}（#{duplicate_id}）")
    return SmartSubscriptionPrefillResponse(
        ok=True,
        message="AI 已根据标题填充部分字段，你可以修改后保存。",
        form_defaults=suggestion,
        ai_result=ai_result,
        local_result=local_response.parsed_title,
        source="ai",
        warnings=warnings,
        duplicate_subscription_id=duplicate_id,
        duplicate_subscription_name=duplicate_name,
    )


def _with_smart_subscription_identity_match(
    response: SmartSubscriptionPrefillResponse,
    store: Store,
) -> SmartSubscriptionPrefillResponse:
    suggestion = response.form_defaults
    if suggestion is None:
        return response
    resolution = _resolve_subscription_identity(suggestion, store)
    candidate_ids = [int(item["id"]) for item in resolution.candidates]
    updates: dict[str, Any] = {
        "identity_key": suggestion.identity_key,
        "match_status": resolution.status,
        "match_reason": resolution.reason,
        "match_candidate_ids": candidate_ids,
        "duplicate_subscription_id": None,
        "duplicate_subscription_name": None,
        "matched_subscription": None,
    }
    if resolution.status == "matched":
        matched = Subscription(**resolution.candidates[0])
        updates.update(
            {
                "duplicate_subscription_id": matched.id,
                "duplicate_subscription_name": matched.name,
                "matched_subscription": matched,
            }
        )
    elif resolution.status == "ambiguous":
        updates.update(
            {
                "ok": False,
                "message": "找到多个可能对应的现有订阅，无法安全判断要更新哪一个。请先在订阅列表中处理重复项。",
                "warnings": [
                    *response.warnings,
                    f"候选订阅：{'、'.join(f'#{item}' for item in candidate_ids)}",
                ],
            }
        )
    return response.model_copy(update=updates)


def _subscription_auto_organize_status(subscription: Subscription, episodes: list[SubscriptionLogicalEpisodeStatus]) -> str:
    if not subscription.auto_organize:
        return "未开启"
    target_episodes = [item for item in episodes if not item.excluded_by_episode_start]
    if not target_episodes:
        if episodes:
            return "暂无需处理集数"
        return "等待匹配资源"
    matched_target_episodes = [item for item in target_episodes if item.matched_resources]
    if any(item.auto_organize_status == "整理失败" for item in target_episodes):
        return "整理失败"
    if matched_target_episodes and all(item.organize_status == "已整理" for item in matched_target_episodes):
        return "已整理"
    if any(item.organize_available for item in target_episodes):
        return "等待整理"
    if any(item.download_status in {"已提交下载", "下载中"} for item in target_episodes):
        return "等待下载完成"
    return "等待下载"


async def _build_subscription_detail(subscription_id: int, store: Store) -> SubscriptionDetail:
    subscription = _subscription_or_404(subscription_id, store)
    organize_target = None
    if subscription.organize_target_id is not None:
        target = store.get_organize_target(subscription.organize_target_id)
        if target is not None:
            organize_target = OrganizeTarget(**target)
    all_matches = [
        _subscription_match_with_episode_mapping(subscription, match)
        for match in _reparsed_subscription_match_models(
            subscription,
            store.list_subscription_matches(subscription_id),
            store,
        )
    ]
    history = _cached_download_history_models(store, subscription_id=subscription_id)
    current_matches = _subscription_matches_with_current_size_bounds(subscription, all_matches)
    current_match_ids = {match.id for match in current_matches}
    historical_fingerprints = {item.fingerprint for item in history}
    matches = [
        match
        for match in all_matches
        if match.id in current_match_ids or match.fingerprint in historical_fingerprints
    ]
    refresh_history = _subscription_refresh_history_models(store.list_subscription_refresh_history(subscription_id))
    metadata_bindings = _subscription_detail_metadata_bindings(subscription_id, matches, store)
    plex_mappings = _subscription_detail_plex_mappings(metadata_bindings, store)
    mapping = _mapping_for_subscription(subscription, metadata_bindings, plex_mappings)
    media_target = _media_target_for_subscription(subscription, store)
    media_index = _build_episode_media_index(subscription, media_target, mapping, store)
    organize_target_preview = _organize_target_preview_for_subscription(
        subscription,
        organize_target,
        metadata_bindings,
        plex_mappings,
        store,
    )
    preview_keys = _organize_preview_keys(store)
    done_keys = _organize_done_keys(store)
    episodes = _episode_statuses(matches, history, preview_keys, done_keys)
    episode_statuses, unmatched_resources = _logical_episode_statuses(
        subscription,
        matches,
        history,
        metadata_bindings,
        preview_keys,
        done_keys,
        media_index,
    )
    latest_refresh_at, latest_refresh_summary, latest_error = _subscription_latest_status(refresh_history, matches)
    latest_organized_at = _subscription_latest_organized_at(subscription.id, store)
    catalog_total, _catalog_source = _subscription_total_episodes(subscription, metadata_bindings)
    coverage = _subscription_coverage_summary(
        subscription,
        matches,
        history,
        store,
        media_index,
        catalog_total_episodes=catalog_total,
    )
    return SubscriptionDetail(
        subscription=subscription,
        organize_target=organize_target,
        organize_target_preview=organize_target_preview,
        matches=matches,
        history=history,
        refresh_history=refresh_history,
        metadata_bindings=metadata_bindings,
        metadata_hierarchy=_metadata_hierarchy(subscription, metadata_bindings, episodes),
        plex_mappings=plex_mappings,
        episodes=episodes,
        episode_statuses=episode_statuses,
        unmatched_resources=unmatched_resources,
        auto_organize_status=_subscription_auto_organize_status(subscription, episode_statuses),
        matched_count=len(current_matches),
        queued_count=sum(1 for item in current_matches if item.status == "queued"),
        skipped_count=sum(1 for item in current_matches if item.status == "skipped"),
        error_count=sum(1 for item in current_matches if item.status == "error"),
        latest_refresh_at=latest_refresh_at,
        latest_refresh_summary=latest_refresh_summary,
        latest_organized_at=latest_organized_at,
        latest_error=latest_error,
        coverage=coverage,
    )


def _reset_response(
    *,
    subscription_id: int,
    message: str,
    counts: dict[str, int],
) -> ResetSubscriptionResponse:
    return ResetSubscriptionResponse(
        ok=True,
        subscription_id=subscription_id,
        message=message,
        download_history_deleted=counts.get("download_history_deleted", 0),
        subscription_matches_deleted=counts.get("subscription_matches_deleted", 0),
        subscription_refreshes_deleted=counts.get("subscription_refreshes_deleted", 0),
        organize_previews_deleted=counts.get("organize_previews_deleted", 0),
        organize_history_deleted=counts.get("organize_history_deleted", 0),
        metadata_bindings_deleted=counts.get("metadata_bindings_deleted", 0),
        plex_mappings_deleted=counts.get("plex_mappings_deleted", 0),
        poster_cache_deleted=counts.get("poster_cache_deleted", 0),
    )


@router.post("/subscriptions", response_model=Subscription)
async def create_subscription(request: SubscriptionCreate, store: Store = Depends(get_store)) -> Subscription:
    _reject_new_brush_only_subscription_sites(request, store)
    request = _with_default_organize_target(request, store)
    _reject_duplicate_subscription(request, store)
    try:
        created = store.create_subscription(request.model_dump(mode="json"))
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return Subscription(**created)


@router.post("/subscriptions/suggest", response_model=SubscriptionSuggestionResponse)
async def suggest_subscription(
    request: SubscriptionSuggestionRequest,
    store: Store = Depends(get_store),
) -> SubscriptionSuggestionResponse:
    return _build_subscription_suggestion(request, store)


@router.post("/subscriptions/smart-prefill", response_model=SmartSubscriptionPrefillResponse)
async def smart_subscription_prefill(
    request: SmartSubscriptionPrefillRequest,
    store: Store = Depends(get_store),
) -> SmartSubscriptionPrefillResponse:
    response = await _build_smart_subscription_prefill(request, store)
    return _with_smart_subscription_identity_match(response, store)


@router.post("/subscriptions/test-match", response_model=SubscriptionTestMatchResponse)
async def test_subscription_match(
    request: SubscriptionTestMatchRequest,
    store: Store = Depends(get_store),
) -> SubscriptionTestMatchResponse:
    subscription = Subscription(
        **_with_default_organize_target(request, store).model_dump(mode="json"),
        id=0,
        created_at=datetime.now(timezone.utc),
        updated_at=None,
    )
    timeout_seconds = stored_search_settings(store).site_timeout_seconds
    try:
        fetch_response = await fetch_subscription_results(
            subscription,
            stored_site_settings(store),
            timeout_seconds=timeout_seconds,
        )
    except TypeError as exc:
        if "positional" not in str(exc) and "argument" not in str(exc):
            raise
        try:
            fetch_response = await fetch_subscription_results(subscription, stored_site_settings(store))
        except TypeError as nested_exc:
            if "positional" not in str(nested_exc) and "argument" not in str(nested_exc):
                raise
            fetch_response = await fetch_subscription_results(subscription)
    if len(fetch_response) == 2:
        results, warnings = fetch_response
        search_diagnostics = SearchDiagnostics(total_fetched=len(results), total_unique=len(results))
    else:
        results, warnings, search_diagnostics = fetch_response
    is_mikan_bangumi = subscription.source_type == "mikan_bangumi" and bool(
        subscription.mikan_bangumi_url or subscription.source_url
    )
    if len(results) > request.limit and not is_mikan_bangumi:
        results = results[: request.limit]
    effective_rules = _effective_episode_rules(subscription, store)
    matched, diagnostics = match_results_with_diagnostics(store, subscription, results, effective_rules)
    diagnostics.search_diagnostics = search_diagnostics
    diagnostics.pages_fetched = search_diagnostics.pages_fetched
    diagnostics.total_unique = search_diagnostics.total_unique
    diagnostics.stop_reasons = search_diagnostics.stop_reasons
    diagnostics.reached_max_pages = search_diagnostics.reached_max_pages
    diagnostics.completed_all_accessible_pages = search_diagnostics.completed_all_accessible_pages
    diagnostics.reached_internal_safety_limit = search_diagnostics.reached_internal_safety_limit
    diagnostics.has_more = search_diagnostics.has_more
    matched_samples = []
    for result in matched[:12]:
        _, _, sample = analyze_match(
            subscription,
            result,
            effective_rules,
            include_matched_sample=True,
        )
        if sample is not None:
            matched_samples.append(sample)
    search_scope_message = (
        "结果过多，已在安全上限停止"
        if diagnostics.reached_internal_safety_limit
        else "已搜索全部可访问结果"
    )
    message = (
        f"{search_scope_message}，抓取 {diagnostics.pages_fetched} 页、{diagnostics.total_fetched} 条，去重后 {diagnostics.total_unique} 条，匹配 {diagnostics.matched_count} 条；"
        f"字幕组过滤 {diagnostics.excluded_by_fansub} 条，包含词过滤 {diagnostics.excluded_by_include} 条，"
        f"排除词过滤 {diagnostics.excluded_by_exclude} 条，分辨率过滤 {diagnostics.excluded_by_resolution} 条，"
        f"正则过滤 {diagnostics.excluded_by_regex} 条，集数过滤 {diagnostics.excluded_by_episode_filter} 条，"
        f"其中合集策略排除 {diagnostics.excluded_by_batch_policy} 条、范围未覆盖 {diagnostics.excluded_by_episode_coverage} 条；"
        f"副标题番名命中 {diagnostics.matched_by_subtitle} 条、副标题集数解析 {diagnostics.episode_parsed_from_subtitle} 条，"
        f"季度不匹配 {diagnostics.excluded_by_season_mismatch} 条，metadata 不匹配 {diagnostics.excluded_by_metadata_mismatch + diagnostics.excluded_by_bangumi_id_mismatch} 条。"
    )
    return SubscriptionTestMatchResponse(
        ok=True,
        message=message,
        matched=matched[: request.limit],
        matched_samples=matched_samples,
        excluded=diagnostics.sample_excluded_items,
        diagnostics=diagnostics,
        warnings=warnings,
    )


@router.post("/rss/test", response_model=RssTestResponse)
async def test_rss(request: RssTestRequest, store: Store = Depends(get_store)) -> RssTestResponse:
    return await _preview_rss(
        request.site,
        request.url,
        store,
        respect_site_enabled=True,
        keyword=request.keyword,
        category=request.category,
        limit=request.limit,
        page=request.page,
        page_size=request.page_size,
        usage_purpose="subscription",
    )


@router.post("/sites/{site_id}/rss/preview", response_model=RssTestResponse)
@router.post("/settings/sites/{site_id}/rss/preview", response_model=RssTestResponse)
async def preview_site_rss(
    site_id: str,
    request: RssTestRequest | None = None,
    store: Store = Depends(get_store),
) -> RssTestResponse:
    normalized_site_id = normalize_site_id(site_id)
    if normalized_site_id not in default_site_settings():
        raise HTTPException(status_code=404, detail="资源站点不存在")
    url = request.url if request and request.url else None
    return await _preview_rss(
        normalized_site_id,
        url,
        store,
        respect_site_enabled=False,
        site_settings=request.site_settings if request else None,
        keyword=request.keyword if request else None,
        category=request.category if request else None,
        limit=request.limit if request else 100,
        page=request.page if request else 1,
        page_size=request.page_size if request else 25,
        usage_purpose="site_diagnostics",
    )


async def _preview_rss(
    site_id: str,
    url: str | None,
    store: Store,
    *,
    respect_site_enabled: bool,
    site_settings: SiteSettingsUpdate | None = None,
    keyword: str | None = None,
    category: str | None = None,
    limit: int = 100,
    page: int = 1,
    page_size: int = 25,
    usage_purpose: str = "subscription",
) -> RssTestResponse:
    started_at = time.monotonic()
    site_id = normalize_site_id(site_id)
    diagnostics = SearchDiagnostics()
    site_diagnostics = SiteSearchDiagnostics(site=site_id)
    diagnostics.site_diagnostics.append(site_diagnostics)
    drain_rate_limit_events(site_id)
    try:
        raw_site_settings = stored_site_settings(store)
        if site_settings is not None:
            raw_site_settings = dict(raw_site_settings)
            current = dict(raw_site_settings.get(site_id) or {})
            raw_site_settings[site_id] = merge_site_secret_fields(current, site_settings)
        adapter = get_site_adapter(site_id, raw_site_settings)
        restriction = site_usage_restriction(adapter, usage_purpose, respect_site_enabled=respect_site_enabled)
        if restriction:
            site_diagnostics.stop_reason, message = restriction
            site_diagnostics.warnings.append(message)
            site_diagnostics.completed_all_accessible_pages = False
            return RssTestResponse(
                ok=False,
                message=f"{site_id} RSS：{message}",
                site=site_id,
                warnings=[message],
                diagnostics=diagnostics,
            )
        if respect_site_enabled and not getattr(adapter, "enabled", True):
            message = f"{site_id} RSS：站点已在设置中停用"
            site_diagnostics.error = message
            site_diagnostics.completed_all_accessible_pages = False
            site_diagnostics.stop_reason = "site_disabled"
            return RssTestResponse(
                ok=False,
                message=message,
                site=site_id,
                warnings=[message],
                diagnostics=diagnostics,
            )
        resource_preview = await adapter.preview_rss_resources(
            keyword=keyword,
            category=category,
            page=page,
            page_size=page_size,
        )
        if resource_preview is not None:
            preview_results = resource_preview["results"]
            source_results = resource_preview.get("source_results") or preview_results
            total_count = int(resource_preview["count"])
            effective_page = int(resource_preview["page"])
            effective_page_size = int(resource_preview["page_size"])
            total_pages = int(resource_preview["total_pages"])
            has_previous = bool(resource_preview["has_previous"])
            has_next = bool(resource_preview["has_next"])
            site_diagnostics.pages_fetched = 1
            site_diagnostics.total_fetched = len(source_results) if isinstance(source_results, list) else total_count
            site_diagnostics.total_unique = total_count
            preview_stop_reason = str(resource_preview.get("stop_reason") or "moviepilot_spider_window")
            site_diagnostics.stop_reason = preview_stop_reason
            site_diagnostics.has_more = has_next
            diagnostics.pages_fetched = 1
            diagnostics.total_fetched = len(source_results) if isinstance(source_results, list) else total_count
            diagnostics.total_unique = total_count
            diagnostics.has_more = has_next
            diagnostics.stop_reasons = [f"{site_id}: {preview_stop_reason}"]
            elapsed_ms = int((time.monotonic() - started_at) * 1000)
            preview_message = resource_preview.get("message")
            return RssTestResponse(
                ok=True,
                message=(
                    str(preview_message)
                    if preview_message
                    else f"读取到 {total_count} 条资源 · 第 {effective_page}/{max(total_pages, 1)} 页"
                ),
                site=site_id,
                url=mask_url_secret(adapter.resolved_rss_url(url)),
                count=total_count,
                page=effective_page,
                page_size=effective_page_size,
                total_pages=total_pages,
                has_previous=has_previous,
                has_next=has_next,
                elapsed_ms=elapsed_ms,
                categories=adapter.rss_categories(source_results if isinstance(source_results, list) else []),
                results=_sanitize_rss_preview_results(preview_results if isinstance(preview_results, list) else []),
                diagnostics=diagnostics,
            )
        rss_url = adapter.resolved_rss_url(url)
        if not rss_url:
            raise HTTPException(status_code=400, detail="请先填写 RSS 地址。")
        text = await adapter.fetch_text(rss_url)
        results = await adapter.parse_rss(text)
        filtered_results = _filter_rss_preview_results(results, keyword=keyword, category=category)
        total_count = len(filtered_results)
        effective_page_size = max(1, min(page_size, 100))
        total_pages = (total_count + effective_page_size - 1) // effective_page_size if total_count else 0
        effective_page = min(max(1, page), max(1, total_pages))
        page_start = (effective_page - 1) * effective_page_size
        page_results = filtered_results[page_start : page_start + effective_page_size]
        preview_results = await adapter.enrich_rss_preview_results(page_results, limit=effective_page_size)
        site_diagnostics.pages_fetched = 1
        site_diagnostics.total_fetched = len(results)
        site_diagnostics.total_unique = total_count
        site_diagnostics.stop_reason = "no_next_page"
        site_diagnostics.has_more = effective_page < total_pages
        diagnostics.pages_fetched = 1
        diagnostics.total_fetched = len(results)
        diagnostics.total_unique = total_count
        diagnostics.has_more = effective_page < total_pages
        diagnostics.stop_reasons = [f"{site_id}: no_next_page"]
        elapsed_ms = int((time.monotonic() - started_at) * 1000)
        return RssTestResponse(
            ok=True,
            message=f"读取到 {total_count} 条资源 · 第 {effective_page}/{max(total_pages, 1)} 页",
            site=site_id,
            url=mask_url_secret(rss_url),
            count=total_count,
            page=effective_page,
            page_size=effective_page_size,
            total_pages=total_pages,
            has_previous=effective_page > 1,
            has_next=effective_page < total_pages,
            elapsed_ms=elapsed_ms,
            categories=adapter.rss_categories(results),
            results=_sanitize_rss_preview_results(preview_results),
            diagnostics=diagnostics,
        )
    except HTTPException:
        raise
    except Exception as exc:
        message = f"{site_id} RSS：{describe_site_error(exc)}"
        site_diagnostics.error = message
        site_diagnostics.completed_all_accessible_pages = False
        site_diagnostics.stop_reason = "site_error"
        return RssTestResponse(
            ok=False,
            message=message,
            site=site_id,
            url=mask_url_secret(url),
            warnings=[message],
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            diagnostics=diagnostics,
        )
    finally:
        site_diagnostics.rate_limit_events.extend(event.message for event in drain_rate_limit_events(site_id))


def _filter_rss_preview_results(
    results: list[SearchResult],
    *,
    keyword: str | None,
    category: str | None,
) -> list[SearchResult]:
    filtered = results
    if keyword:
        lowered = keyword.lower()
        filtered = [
            result
            for result in filtered
            if lowered in result.title.lower()
            or lowered in (result.subtitle or "").lower()
            or lowered in (result.description or "").lower()
            or lowered in (result.category or "").lower()
        ]
    if category:
        lowered_category = category.lower()
        filtered = [
            result
            for result in filtered
            if (result.category or "").lower() == lowered_category
            or lowered_category in (result.category or "").lower()
        ]
    return filtered


def _sanitize_rss_preview_results(results: list[SearchResult]) -> list[SearchResult]:
    return [
        result.model_copy(
            update={
                "download_url": None,
                "magnet_url": None,
                "detail_url": mask_url_secret(result.detail_url),
            }
        )
        for result in results
    ]


@router.get("/subscriptions/{subscription_id}", response_model=SubscriptionDetail)
async def subscription_detail(subscription_id: int, store: Store = Depends(get_store)) -> SubscriptionDetail:
    subscription = _subscription_or_404(subscription_id, store)
    if subscription.auto_organize:
        with suppress(Exception):
            await _auto_organize_subscription_if_allowed(subscription_id, store)
    return await _build_subscription_detail(subscription_id, store)


@router.put("/subscriptions/{subscription_id}", response_model=Subscription)
async def update_subscription(
    subscription_id: int,
    request: SubscriptionCreate,
    expected_updated_at: datetime | None = Query(default=None),
    store: Store = Depends(get_store),
) -> Subscription:
    existing = _subscription_or_404(subscription_id, store)
    _reject_new_brush_only_subscription_sites(request, store, existing_site_ids=set(existing.sites))
    current_version = existing.updated_at or existing.created_at
    if expected_updated_at is not None and current_version != expected_updated_at:
        raise HTTPException(
            status_code=409,
            detail="订阅已在其他位置更新，请重新载入后再保存。",
        )
    preserve_existing_episode_start = "episode_start" not in request.model_fields_set
    if preserve_existing_episode_start:
        payload = request.model_dump(mode="json")
        payload["episode_start"] = existing.episode_start or 1
        request = SubscriptionCreate(**payload)
    request = _with_default_organize_target(request, store)
    _reject_duplicate_subscription(request, store, exclude_subscription_id=subscription_id)
    try:
        updated = store.update_subscription(subscription_id, request.model_dump(mode="json"))
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if not updated:
        raise HTTPException(status_code=404, detail="订阅不存在")
    return Subscription(**updated)


def _configured_subscription_download_roots(store: Store) -> dict[str, Path]:
    roots: dict[str, Path] = {}
    qbittorrent = load_qbittorrent_config(store)
    transmission = stored_transmission_config(store)
    if qbittorrent and qbittorrent.default_save_path:
        roots["qbittorrent"] = Path(qbittorrent.default_save_path).expanduser().absolute()
    if transmission and transmission.default_save_path:
        roots["transmission"] = Path(transmission.default_save_path).expanduser().absolute()
    return roots


def _subscription_managed_directory_targets(
    subscription: Subscription,
    store: Store,
    *,
    histories: list[dict[str, Any]] | None = None,
) -> list[ManagedDirectoryTarget]:
    roots = _configured_subscription_download_roots(store)
    history_rows = histories if histories is not None else store.list_history(subscription.id, limit=10_000)
    return subscription_directory_targets(
        name=subscription.name,
        configured_roots=roots.values(),
        save_path=subscription.save_path,
        history_paths=[row.get("save_path") for row in history_rows if row.get("save_path")],
    )


def _download_task_directory_usage(item: dict[str, Any], target: ManagedDirectoryTarget) -> bool | None:
    content_path = str(item.get("content_path") or item.get("contentPath") or "").strip()
    if content_path and paths_overlap(content_path, target.path):
        return True
    save_path_text = str(item.get("save_path") or item.get("savePath") or "").strip()
    if not save_path_text:
        return None
    save_path = Path(save_path_text).expanduser().absolute()
    if save_path == target.path:
        return True
    if save_path != target.root and save_path not in target.path.parents:
        return False
    files = item.get("files") if isinstance(item.get("files"), list) else []
    if not files:
        return None
    for file in files:
        if not isinstance(file, dict):
            return None
        raw_name = str(file.get("name") or "").replace("\\", "/")
        relative = PurePosixPath(raw_name)
        if (
            not raw_name
            or "\x00" in raw_name
            or relative.is_absolute()
            or any(part in {"", ".", ".."} for part in relative.parts)
        ):
            return None
        file_path = save_path.joinpath(*relative.parts).absolute()
        if file_path == target.path or target.path in file_path.parents:
            return True
    return False


async def _cleanup_deleted_subscription_directories(
    subscription: Subscription,
    histories: list[dict[str, Any]],
    store: Store,
) -> dict[str, int | str]:
    targets = _subscription_managed_directory_targets(subscription, store, histories=histories)
    if not targets:
        return {
            "download_directories_deleted": 0,
            "download_directory_cleanup_status": "skipped",
            "download_directory_cleanup_message": "未找到可安全确认的订阅专属目录，未清理。",
        }

    remaining_targets: list[ManagedDirectoryTarget] = []
    for row in store.list_subscriptions():
        remaining = Subscription(**row)
        remaining_targets.extend(_subscription_managed_directory_targets(remaining, store))

    configured_roots = _configured_subscription_download_roots(store)
    history_types_by_path = {
        Path(str(row["save_path"])).expanduser().absolute(): str(row.get("downloader_type") or "qbittorrent")
        for row in histories
        if row.get("save_path")
    }
    downloader_snapshots: dict[str, list[dict[str, Any]] | None] = {}
    messages: list[str] = []
    deleted_count = 0

    for target in targets:
        if any(paths_overlap(target.path, remaining.path) for remaining in remaining_targets):
            messages.append("目录仍由其他订阅使用，未清理。")
            continue
        if not target.path.exists():
            messages.append("订阅专属目录已不存在，无需清理。")
            continue

        relevant_downloaders = {
            downloader_type
            for downloader_type, root in configured_roots.items()
            if target.path == root or root in target.path.parents
        }
        relevant_downloaders.update(
            downloader_type
            for history_path, downloader_type in history_types_by_path.items()
            if paths_overlap(history_path, target.path)
        )
        blocked = False
        for downloader_type in relevant_downloaders:
            if downloader_type not in downloader_snapshots:
                try:
                    downloader_snapshots[downloader_type] = await _configured_downloader_client(
                        store,
                        downloader_type,
                    ).list_torrents()
                except Exception as exc:
                    downloader_snapshots[downloader_type] = None
                    messages.append(
                        f"无法确认 {downloader_display_name(downloader_type)} 的活跃任务，目录未清理："
                        f"{describe_downloader_error(downloader_type, exc)}"
                    )
            snapshot = downloader_snapshots[downloader_type]
            if snapshot is None:
                blocked = True
                break
            usage = [_download_task_directory_usage(item, target) for item in snapshot]
            if any(value is True for value in usage):
                messages.append(f"仍有 {downloader_display_name(downloader_type)} 任务使用该目录，未清理。")
                blocked = True
                break
            if any(value is None for value in usage):
                messages.append(f"无法确认 {downloader_display_name(downloader_type)} 任务的文件路径，目录未清理。")
                blocked = True
                break
        if blocked:
            continue

        cleanup = prune_empty_managed_directory(target.path, managed_root=target.root)
        deleted_count += cleanup.deleted_count
        messages.append(cleanup.message)

    unique_messages = list(dict.fromkeys(messages))
    status = "deleted" if deleted_count else "skipped"
    if deleted_count and any("未清理" in message for message in unique_messages):
        status = "partial"
    return {
        "download_directories_deleted": deleted_count,
        "download_directory_cleanup_status": status,
        "download_directory_cleanup_message": "；".join(unique_messages) or "没有需要清理的订阅目录。",
    }


@router.delete("/subscriptions/{subscription_id}")
async def delete_subscription(subscription_id: int, store: Store = Depends(get_store)) -> dict[str, bool | int | str]:
    subscription = _subscription_or_404(subscription_id, store)
    histories = store.list_history(subscription_id, limit=10_000)
    posters_deleted = _remove_subscription_poster_cache(subscription_id)
    counts = store.delete_subscription(subscription_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="订阅不存在")
    directory_cleanup = await _cleanup_deleted_subscription_directories(subscription, histories, store)
    return {
        "ok": True,
        "message": "订阅已删除",
        "poster_cache_deleted": posters_deleted,
        **directory_cleanup,
        **counts,
    }


@router.post("/subscriptions/{subscription_id}/cache-poster")
async def cache_subscription_poster(subscription_id: int, store: Store = Depends(get_store)) -> dict[str, bool | str | None]:
    _subscription_or_404(subscription_id, store)
    rows = store.list_metadata_bindings_for_target("subscription", str(subscription_id), limit=10)
    poster_url = next((row.get("poster_url") for row in rows if row.get("poster_url")), None)
    if not poster_url:
        return {"ok": False, "message": "当前订阅没有可缓存的海报 URL。", "poster_local_url": None}
    cached = await _cache_subscription_poster(subscription_id, poster_url)
    if not cached:
        return {"ok": False, "message": "海报缓存失败，将继续使用远程海报或占位图。", "poster_local_url": None}
    return {"ok": True, "message": "海报已缓存。", "poster_local_url": cached["poster_local_url"]}


@router.get("/subscriptions/{subscription_id}/poster")
async def subscription_poster(subscription_id: int, store: Store = Depends(get_store)) -> FileResponse:
    _subscription_or_404(subscription_id, store)
    path = _cached_subscription_poster_path(subscription_id)
    if path is None:
        raise HTTPException(status_code=404, detail="订阅海报缓存不存在")
    return FileResponse(path)


@router.post("/subscriptions/{subscription_id}/reset", response_model=ResetSubscriptionResponse)
async def reset_subscription_state(
    subscription_id: int,
    request: ResetSubscriptionRequest,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="重置订阅状态需要确认，当前未执行。")
    counts = store.reset_subscription_state(subscription_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="订阅不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message="订阅状态已重置，订阅规则和订阅级番剧信息已保留",
        counts=counts,
    )


@router.post("/subscriptions/{subscription_id}/clear-recognition", response_model=ResetSubscriptionResponse)
async def clear_subscription_recognition(
    subscription_id: int,
    request: ResetSubscriptionRequest,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    subscription = _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清除识别结果需要确认，当前未执行。")
    posters_deleted = _remove_subscription_poster_cache(subscription_id)
    counts = store.clear_subscription_recognition(subscription_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="订阅不存在")
    counts["poster_cache_deleted"] = posters_deleted
    return _reset_response(
        subscription_id=subscription_id,
        message=f"已清除“{subscription.name}”的番剧识别结果，可重新识别。",
        counts=counts,
    )


@router.post("/subscriptions/{subscription_id}/clear-match-history", response_model=ResetSubscriptionResponse)
async def clear_subscription_match_history(
    subscription_id: int,
    request: ResetSubscriptionRequest,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    subscription = _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清空匹配历史需要确认，当前未执行。")
    counts = store.clear_subscription_match_history(subscription_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="订阅不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message=f"已清空“{subscription.name}”的匹配历史。",
        counts=counts,
    )


@router.post("/subscriptions/{subscription_id}/clear-organize-records", response_model=ResetSubscriptionResponse)
async def clear_subscription_organize_records(
    subscription_id: int,
    request: ResetSubscriptionRequest,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    subscription = _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清空整理记录需要确认，当前未执行。")
    counts = store.clear_subscription_organize_records(subscription_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="订阅不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message=f"已清空“{subscription.name}”的整理预览和整理记录。",
        counts=counts,
    )


@router.delete("/subscriptions/{subscription_id}/episodes/{match_id}/download-record", response_model=ResetSubscriptionResponse)
async def delete_episode_download_record(
    subscription_id: int,
    match_id: int,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    _subscription_or_404(subscription_id, store)
    counts = store.delete_episode_download_record(subscription_id, match_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="剧集匹配记录不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message="已删除这一集的本地下载记录，不会删除原下载器任务或文件。",
        counts=counts,
    )


@router.delete("/subscriptions/{subscription_id}/episodes/{match_id}/organize-record", response_model=ResetSubscriptionResponse)
async def delete_episode_organize_record(
    subscription_id: int,
    match_id: int,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    _subscription_or_404(subscription_id, store)
    counts = store.delete_episode_organize_records(subscription_id, match_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="剧集匹配记录不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message="已删除这一集的整理预览和整理记录，不会删除真实文件。",
        counts=counts,
    )


@router.post("/subscriptions/{subscription_id}/episodes/{match_id}/reset", response_model=ResetSubscriptionResponse)
async def reset_episode_state(
    subscription_id: int,
    match_id: int,
    request: ResetSubscriptionRequest,
    store: Store = Depends(get_store),
) -> ResetSubscriptionResponse:
    _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="重置单集状态需要确认，当前未执行。")
    counts = store.reset_episode_state(subscription_id, match_id)
    if counts is None:
        raise HTTPException(status_code=404, detail="剧集匹配记录不存在")
    return _reset_response(
        subscription_id=subscription_id,
        message="这一集的下载记录、整理记录和匹配状态已重置。",
        counts=counts,
    )


@router.post("/subscriptions/{subscription_id}/history/clear", response_model=HistoryClearResponse)
async def clear_subscription_history(
    subscription_id: int,
    request: SubscriptionHistoryClearRequest,
    store: Store = Depends(get_store),
) -> HistoryClearResponse:
    subscription = _subscription_or_404(subscription_id, store)
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清空订阅历史需要确认，当前未执行。")

    download_deleted = 0
    refresh_deleted = 0
    if request.scope in {"download", "all"}:
        download_deleted = store.clear_download_history(subscription_id=subscription_id)
    if request.scope in {"refresh", "all"}:
        refresh_deleted = store.clear_subscription_refresh_history(subscription_id)

    if request.scope == "download":
        scope_label = "下载历史"
    elif request.scope == "refresh":
        scope_label = "刷新历史"
    else:
        scope_label = "刷新与下载历史"
    return HistoryClearResponse(
        ok=True,
        scope=f"subscription:{request.scope}",
        message=f"已清空“{subscription.name}”的{scope_label}",
        download_history_deleted=download_deleted,
        subscription_refreshes_deleted=refresh_deleted,
    )


@router.post("/subscriptions/{subscription_id}/refresh", response_model=RefreshResponse)
async def refresh_subscription(subscription_id: int, store: Store = Depends(get_store)) -> RefreshResponse:
    subscription = _subscription_or_404(subscription_id, store)
    response = await run_subscription_refresh(
        store,
        subscription,
        qbittorrent_config=stored_qbittorrent_config(store),
    )
    if subscription.auto_organize:
        with suppress(Exception):
            await _organize_subscription_matches(
                subscription_id,
                SubscriptionOrganizeRequest(confirm=True),
                store,
                all_downloaded=True,
            )
    return response


@router.get("/subscriptions/{subscription_id}/matches", response_model=list[SubscriptionMatch])
async def subscription_matches(subscription_id: int, store: Store = Depends(get_store)) -> list[SubscriptionMatch]:
    subscription = _subscription_or_404(subscription_id, store)
    matches = _reparsed_subscription_match_models(
        subscription,
        store.list_subscription_matches(subscription_id),
        store,
    )
    return _subscription_matches_with_current_size_bounds(subscription, matches)


@router.get("/subscriptions/{subscription_id}/refreshes", response_model=list[SubscriptionRefreshHistory])
async def subscription_refreshes(subscription_id: int, store: Store = Depends(get_store)) -> list[SubscriptionRefreshHistory]:
    _subscription_or_404(subscription_id, store)
    return _subscription_refresh_history_models(store.list_subscription_refresh_history(subscription_id))


@router.get("/subscriptions/{subscription_id}/episodes", response_model=list[SubscriptionEpisodeStatus])
async def subscription_episodes(subscription_id: int, store: Store = Depends(get_store)) -> list[SubscriptionEpisodeStatus]:
    detail = await _build_subscription_detail(subscription_id, store)
    return detail.episodes


def _organize_policy_for_subscription(subscription: Subscription, store: Store) -> OrganizePolicySettings:
    base = stored_organize_policy(store)
    data = subscription.model_dump(mode="json")
    action_policy = _organize_policy_or_400(data, base)
    if subscription.post_organize_action != "keep_seeding" or subscription.seeding_policy_mode != "custom":
        return action_policy
    custom = action_policy.model_dump(mode="json")
    custom.update(
        seeding_stop_ratio=subscription.seeding_stop_ratio,
        seeding_stop_minutes=subscription.seeding_stop_minutes,
        seeding_stop_mode=subscription.seeding_stop_mode,
        post_seeding_action=subscription.post_seeding_action,
    )
    return OrganizePolicySettings(**custom)


def _organize_target_for_subscription(
    subscription: Subscription,
    requested_target_id: int | None,
    store: Store,
) -> OrganizeTarget:
    target_id = requested_target_id or subscription.organize_target_id or _default_organize_target_id(store)
    target = _enabled_organize_target_or_400(target_id, store)
    if target is None:
        raise HTTPException(status_code=400, detail="请先在设置中添加并启用整理目标。")
    return target


def _mapping_for_subscription(subscription: Subscription, metadata_bindings: list[MetadataBindingRecord], plex_mappings: list[PlexMappingRecord]) -> PlexSeasonMapping:
    return shared_mapping_for_subscription(subscription, metadata_bindings, plex_mappings)


def _organize_target_preview_for_subscription(
    subscription: Subscription,
    organize_target: OrganizeTarget | None,
    metadata_bindings: list[MetadataBindingRecord],
    plex_mappings: list[PlexMappingRecord],
    store: Store,
) -> OrganizeTargetPreview:
    target = organize_target
    if target is None and subscription.organize_target_id is None:
        default_target = store.default_organize_target()
        if default_target is not None:
            target = OrganizeTarget(**default_target)
    if target is None:
        if subscription.organize_target_id is not None:
            return OrganizeTargetPreview(message="整理目标不可用，请在设置中检查。")
        return OrganizeTargetPreview(message="未设置整理目标，无法生成番剧目录预览。")
    mapping = _mapping_for_subscription(subscription, metadata_bindings, plex_mappings)
    show_dir = show_directory(mapping)
    season_dir = season_directory(mapping.season_number)
    root = Path(target.path)
    show_path = root / show_dir
    season_path = show_path / season_dir
    return OrganizeTargetPreview(
        target_name=target.name,
        root_path=target.path,
        show_directory=show_dir,
        season_directory=season_dir,
        show_path=str(show_path),
        season_path=str(season_path),
        message=None if plex_mappings else "按当前订阅/番剧信息预览，整理时会使用同一套命名规则。",
    )


def _host_download_roots(history: DownloadHistory, store: Store | None) -> list[Path]:
    roots: list[Path] = []
    if history.save_path:
        roots.append(Path(history.save_path).expanduser())
    if store is None:
        config = None
    elif history.downloader_type == "transmission":
        config = stored_transmission_config(store)
    else:
        config = stored_qbittorrent_config(store)
    if config and getattr(config, "default_save_path", None):
        default_root = Path(config.default_save_path).expanduser()
        roots.append(default_root)
        if history.save_path:
            raw = Path(history.save_path).expanduser()
            raw_parts = raw.parts
            if len(raw_parts) >= 2 and raw_parts[1] == "downloads":
                relative = Path(*raw_parts[2:]) if len(raw_parts) > 2 else Path()
                roots.insert(0, default_root / relative)
    unique: list[Path] = []
    seen: set[str] = set()
    for root in roots:
        key = str(root)
        if key not in seen:
            seen.add(key)
            unique.append(root)
    return unique


def _candidate_source_paths(history: DownloadHistory, title: str, store: Store | None = None) -> list[Path]:
    values = [history.save_path, history.torrent_name, title]
    names = [value for value in values if value]
    candidates: list[Path] = []
    roots = _host_download_roots(history, store)
    if roots:
        for root in roots:
            for name in names:
                path = Path(name).expanduser()
                candidates.append(path if path.is_absolute() else root / name)
            candidates.append(root)
            if root.exists() and root.is_dir():
                normalized_names = {_normalized_task_text(name) for name in names}
                for item in root.iterdir():
                    if not item.is_file() and not item.is_dir():
                        continue
                    if _normalized_task_text(item.name) in normalized_names:
                        candidates.insert(0, item)
                        continue
                    if any(_same_task_text(item.name, name) or _same_task_tokens(item.name, name) for name in names):
                        candidates.append(item)
    else:
        for name in names:
            candidates.append(Path(name).expanduser())

    seen: set[str] = set()
    unique: list[Path] = []
    for candidate in candidates:
        key = str(candidate)
        if key not in seen:
            seen.add(key)
            unique.append(candidate)
    return unique


def _source_path_for_history(
    history: DownloadHistory,
    title: str,
    store: Store | None = None,
    *,
    prefer_directory: bool = False,
) -> str | None:
    candidates = _candidate_source_paths(history, title, store)
    if prefer_directory:
        for candidate in candidates:
            if candidate.exists() and candidate.is_dir() and _safe_directory_video_candidates(candidate):
                return str(candidate)
    for candidate in candidates:
        if (
            candidate.exists()
            and candidate.is_file()
            and candidate.suffix.casefold() in VIDEO_EXTENSIONS
            and not is_ignored_media_metadata_path(candidate)
            and candidate.stat().st_size > 0
        ):
            return str(candidate)
    for candidate in candidates:
        if candidate.exists() and candidate.is_dir() and _safe_directory_video_candidates(candidate):
            return str(candidate)
    return None


VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".webm"}
SUBTITLE_EXTENSIONS = {".ass", ".ssa", ".srt", ".vtt", ".sup"}
IGNORED_TORRENT_MEDIA_DIRECTORIES = {
    "attachment",
    "attachments",
    "extra",
    "extras",
    "font",
    "fonts",
    "sample",
    "samples",
    "screenshot",
    "screenshots",
}


class OrganizeSourceResolutionError(Exception):
    def __init__(
        self,
        message: str,
        diagnostics: list[str],
        *,
        retryable: bool = False,
        reason_code: str = "unsafe_or_missing_source",
    ):
        super().__init__(message)
        self.message = message
        self.diagnostics = diagnostics
        self.retryable = retryable
        self.reason_code = reason_code


@dataclass(frozen=True)
class OrganizeSourceResolution:
    source_path: str
    diagnostics: tuple[str, ...]
    completed_video_paths: tuple[str, ...] = ()
    incomplete_video_files: tuple[str, ...] = ()
    task_files_authoritative: bool = False
    task_complete: bool | None = None


def _is_path_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _is_ignored_torrent_media_path(path: PurePosixPath | Path) -> bool:
    if is_ignored_media_metadata_path(path):
        return True
    parent_parts = {part.casefold() for part in path.parts[:-1]}
    if parent_parts & IGNORED_TORRENT_MEDIA_DIRECTORIES:
        return True
    stem = Path(path.name).stem.casefold()
    return bool(re.fullmatch(r"(?:sample|trailer|preview)(?:[._ -]?\d+)?", stem))


def _task_file_is_selected(item: dict[str, Any]) -> bool:
    for key in ("wanted", "selected", "is_selected", "isSelected"):
        if key not in item:
            continue
        value = item.get(key)
        if isinstance(value, str):
            return value.strip().casefold() not in {"", "0", "false", "no", "off"}
        return bool(value)
    priority = item.get("priority")
    if isinstance(priority, (int, float)) and not isinstance(priority, bool):
        return float(priority) > 0
    return True


def _task_video_items(files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for item in files:
        raw_name = str(item.get("name") or "").strip()
        if not raw_name or not _task_file_is_selected(item):
            continue
        relative = PurePosixPath(raw_name.replace("\\", "/"))
        if _is_ignored_torrent_media_path(relative):
            continue
        if Path(relative.name).suffix.casefold() in VIDEO_EXTENSIONS:
            items.append(item)
    return items


def _safe_task_video_candidates(files: list[dict[str, Any]], roots: list[Path]) -> list[Path]:
    resolved_roots: list[tuple[Path, Path]] = []
    for root in roots:
        try:
            lexical = root.expanduser()
            resolved = lexical.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if resolved.is_dir() and all(existing != resolved for _, existing in resolved_roots):
            resolved_roots.append((lexical, resolved))

    candidates: list[Path] = []
    seen: set[str] = set()
    for item in _task_video_items(files):
        raw_name = str(item.get("name") or "").strip()
        progress = item.get("progress")
        if isinstance(progress, (int, float)) and float(progress) < 0.999:
            continue
        relative = PurePosixPath(raw_name.replace("\\", "/"))
        if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            continue
        if _is_ignored_torrent_media_path(relative):
            continue
        if Path(relative.name).suffix.casefold() not in VIDEO_EXTENSIONS:
            continue
        for lexical_root, resolved_root in resolved_roots:
            candidate = lexical_root.joinpath(*relative.parts)
            try:
                resolved_candidate = candidate.resolve(strict=True)
            except (OSError, RuntimeError):
                continue
            if not resolved_candidate.is_file() or not _is_path_within(resolved_candidate, resolved_root):
                continue
            try:
                actual_size = resolved_candidate.stat().st_size
            except OSError:
                continue
            expected_size = item.get("size")
            if actual_size <= 0:
                continue
            if (
                isinstance(expected_size, (int, float))
                and not isinstance(expected_size, bool)
                and int(expected_size) > 0
                and actual_size != int(expected_size)
            ):
                continue
            key = str(resolved_candidate)
            if key not in seen:
                seen.add(key)
                candidates.append(candidate)
            break
    return sorted(candidates, key=lambda candidate: str(candidate).casefold())


def _incomplete_task_video_files(files: list[dict[str, Any]]) -> list[str]:
    incomplete: list[str] = []
    for item in _task_video_items(files):
        raw_name = str(item.get("name") or "").strip()
        relative = PurePosixPath(raw_name.replace("\\", "/"))
        progress = item.get("progress")
        if not isinstance(progress, (int, float)) or float(progress) < 0.999:
            incomplete.append(relative.name)
    return incomplete


def _incomplete_video_matches_episode(
    files: list[dict[str, Any]],
    *,
    expected_episode: int,
    episode_parse_rules: list[EpisodeParseRule] | None,
    context_season_number: int | None,
) -> bool:
    for filename in _incomplete_task_video_files(files):
        parsed = parse_title(
            filename,
            episode_parse_rules or [],
            context_season_number=context_season_number,
        )
        episode_start = parsed.episode_start or parsed.episode
        episode_end = parsed.episode_end or episode_start
        if episode_start is not None and episode_end is not None and episode_start <= expected_episode <= episode_end:
            return True
    return False


def _safe_directory_video_candidates(root: Path) -> list[Path]:
    try:
        resolved_root = root.expanduser().resolve(strict=True)
    except (OSError, RuntimeError):
        return []
    if not resolved_root.is_dir():
        return []
    candidates: list[Path] = []
    for item in resolved_root.rglob("*"):
        try:
            resolved_item = item.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if not resolved_item.is_file() or not _is_path_within(resolved_item, resolved_root):
            continue
        relative = resolved_item.relative_to(resolved_root)
        if _is_ignored_torrent_media_path(relative):
            continue
        if resolved_item.suffix.casefold() in VIDEO_EXTENSIONS:
            candidates.append(resolved_item)
    return sorted(set(candidates), key=lambda item: str(item).casefold())


def _select_single_episode_video(
    candidates: list[Path],
    *,
    expected_episode: int | None,
    episode_parse_rules: list[EpisodeParseRule] | None,
    context_season_number: int | None,
) -> tuple[Path | None, str | None]:
    if len(candidates) == 1:
        return candidates[0], None
    if not candidates:
        return None, "下载器任务文件列表中没有已完成且可访问的视频文件。"
    if expected_episode is not None:
        episode_matches: list[Path] = []
        for candidate in candidates:
            parsed = parse_title(
                candidate.name,
                episode_parse_rules or [],
                context_season_number=context_season_number,
            )
            episode_start = parsed.episode_start or parsed.episode
            episode_end = parsed.episode_end or episode_start
            if episode_start is not None and episode_end is not None and episode_start <= expected_episode <= episode_end:
                episode_matches.append(candidate)
        if len(episode_matches) == 1:
            return episode_matches[0], None
        if len(episode_matches) > 1:
            return None, f"下载器任务中有 {len(episode_matches)} 个视频都匹配第 {expected_episode} 集，无法安全确定整理源文件。"
    return None, f"下载器任务中有 {len(candidates)} 个视频，无法唯一确定单集整理源文件。"


def _distinct_episode_video_count(
    candidates: list[Path],
    *,
    episode_parse_rules: list[EpisodeParseRule] | None,
    context_season_number: int | None,
) -> int:
    episodes: set[int] = set()
    for candidate in candidates:
        parsed = parse_title(
            candidate.name,
            episode_parse_rules or [],
            context_season_number=context_season_number,
        )
        episode_start = parsed.episode_start or parsed.episode
        episode_end = parsed.episode_end or episode_start
        if episode_start is not None and episode_end == episode_start:
            episodes.add(episode_start)
    return len(episodes)


def _task_directory_containing_candidates(
    directories: list[Path],
    candidates: list[Path],
) -> Path | None:
    for directory in directories:
        try:
            resolved_directory = directory.expanduser().resolve(strict=True)
            resolved_candidates = [candidate.expanduser().resolve(strict=True) for candidate in candidates]
        except (OSError, RuntimeError):
            continue
        if resolved_directory.is_dir() and all(
            _is_path_within(candidate, resolved_directory) for candidate in resolved_candidates
        ):
            return directory
    return None


def _batch_video_files(source_path: str) -> list[Path]:
    root = Path(source_path).expanduser()
    if not root.exists() or not root.is_dir():
        return []
    return sorted(
        (
            item
            for item in root.rglob("*")
            if item.is_file()
            and item.suffix.lower() in VIDEO_EXTENSIONS
            and not _is_ignored_torrent_media_path(item.relative_to(root))
        ),
        key=lambda item: str(item),
    )


def _source_path_from_download_history(
    history: DownloadHistory,
    store: Store | None = None,
    *,
    prefer_directory: bool = False,
) -> str | None:
    return _source_path_for_history(history, history.title, store, prefer_directory=prefer_directory)


async def _resolve_download_history_source(
    history: DownloadHistory,
    store: Store,
    *,
    prefer_directory: bool = False,
    allow_partial_batch: bool = False,
    expected_episode: int | None = None,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
    context_season_number: int | None = None,
) -> OrganizeSourceResolution:
    diagnostics: list[str] = [
        f"download_record_id={history.id}",
        f"torrent_hash_configured={bool(history.qbittorrent_hash)}",
        f"torrent_name_configured={bool(history.torrent_name)}",
        f"save_path_configured={bool(history.save_path)}",
    ]
    resolution_error: str | None = None
    resolution_retryable = False
    resolution_reason_code = "unsafe_or_missing_source"
    task_complete: bool | None = None

    def resolved(
        source_path: str | Path,
        *,
        candidates: list[Path] | None = None,
        incomplete: list[str] | None = None,
        task_files_authoritative: bool = False,
    ) -> OrganizeSourceResolution:
        return OrganizeSourceResolution(
            source_path=str(source_path),
            diagnostics=tuple(diagnostics),
            completed_video_paths=tuple(str(item) for item in (candidates or [])),
            incomplete_video_files=tuple(incomplete or []),
            task_files_authoritative=task_files_authoritative,
            task_complete=task_complete,
        )

    with suppress(Exception):
        client = _configured_downloader_client(store, history.downloader_type)
        match = _match_torrent_for_history(history, await client.list_torrents())
        torrent = match.torrent
        diagnostics.append(f"downloader={history.downloader_type} match={match.reason} confidence={match.confidence:.2f}")
        if torrent is not None:
            torrent.setdefault("downloader_type", history.downloader_type)
            _remember_history_torrent(store, history.id, torrent)
            task_progress = torrent.get("progress")
            task_complete = (
                float(task_progress) >= 1.0
                if isinstance(task_progress, (int, float)) and not isinstance(task_progress, bool)
                else None
            )
            task_progress_incomplete = isinstance(task_progress, (int, float)) and float(task_progress) < 0.999
            content_directories: list[Path] = []
            content_files: list[Path] = []
            for key in ("content_path", "contentPath", "download_path", "downloadPath", "root_path", "rootPath"):
                raw_path = str(torrent.get(key) or "").strip()
                if not raw_path:
                    continue
                candidate = Path(raw_path).expanduser()
                prefix = "qb" if history.downloader_type == "qbittorrent" else "transmission"
                diagnostics.append(f"{prefix}_{key}=present exists={candidate.exists()} dir={candidate.is_dir()}")
                if candidate.exists() and candidate.is_file():
                    content_files.append(candidate)
                if candidate.exists() and candidate.is_dir():
                    content_directories.append(candidate)
            torrent_save_path = str(torrent.get("save_path") or torrent.get("savePath") or "").strip()
            torrent_name = _torrent_name(torrent)
            task_id = str(torrent.get("remote_id") or _torrent_hash(torrent) or "")
            file_items: list[dict[str, Any]] = []
            task_files_error: str | None = None
            if task_id:
                try:
                    files = await client.torrent_files(task_id)
                    file_items = [
                        item
                        for item in files
                        if isinstance(item, dict) and str(item.get("name") or "").strip()
                    ]
                except Exception as exc:
                    task_files_error = type(exc).__name__
                    diagnostics.append(f"task_files_unavailable={task_files_error}")
            if file_items or content_directories or content_files:
                roots = [*content_directories]
                roots.extend(candidate.parent for candidate in content_files)
                if torrent_save_path:
                    roots.insert(0, Path(torrent_save_path).expanduser())
                candidates = _safe_task_video_candidates(file_items, roots)
                incomplete_video_files = _incomplete_task_video_files(file_items)
                selected_video_items = _task_video_items(file_items)
                if incomplete_video_files:
                    diagnostics.append(f"incomplete_video_files={len(incomplete_video_files)}")
                if prefer_directory and candidates and (not incomplete_video_files or allow_partial_batch):
                    task_directory = _task_directory_containing_candidates(content_directories, candidates)
                    diagnostics.append(
                        f"prefer_directory=True task_directory={task_directory is not None} "
                        f"partial={bool(incomplete_video_files)}"
                    )
                    if task_directory is not None:
                        return resolved(
                            task_directory,
                            candidates=candidates,
                            incomplete=incomplete_video_files,
                            task_files_authoritative=bool(file_items),
                        )
                if expected_episode is not None and incomplete_video_files:
                    selected, selection_error = _select_single_episode_video(
                        candidates,
                        expected_episode=expected_episode,
                        episode_parse_rules=episode_parse_rules,
                        context_season_number=context_season_number,
                    )
                    diagnostics.append(
                        f"task_files={len(file_items)} video_candidates={len(candidates)} "
                        f"selected_episode={expected_episode} selected={selected is not None}"
                    )
                    if selected is not None:
                        return resolved(
                            selected,
                            candidates=candidates,
                            incomplete=incomplete_video_files,
                            task_files_authoritative=bool(file_items),
                        )
                    if _incomplete_video_matches_episode(
                        file_items,
                        expected_episode=expected_episode,
                        episode_parse_rules=episode_parse_rules,
                        context_season_number=context_season_number,
                    ):
                        resolution_error = f"第 {expected_episode} 集源视频尚未完成，等待下载完成。"
                    else:
                        resolution_error = selection_error
                    resolution_retryable = True
                    resolution_reason_code = "waiting_for_target_video"
                elif incomplete_video_files:
                    resolution_error = f"下载器任务中仍有 {len(incomplete_video_files)} 个视频文件未完成，等待下载完成。"
                    resolution_retryable = True
                    resolution_reason_code = "waiting_for_video_files"
                if not candidates and content_directories:
                    task_progress = torrent.get("progress")
                    complete_for_legacy_fallback = isinstance(task_progress, (int, float)) and float(task_progress) >= 0.999
                    if complete_for_legacy_fallback and not task_id and not file_items and not incomplete_video_files:
                        candidates = [
                            candidate
                            for directory in content_directories
                            for candidate in _safe_directory_video_candidates(directory)
                        ]
                        candidates = sorted(set(candidates), key=lambda item: str(item).casefold())
                distinct_episode_count = _distinct_episode_video_count(
                    candidates,
                    episode_parse_rules=episode_parse_rules,
                    context_season_number=context_season_number,
                )
                if resolution_error is None and distinct_episode_count > 1 and not incomplete_video_files:
                    task_directory = _task_directory_containing_candidates(content_directories, candidates)
                    diagnostics.append(
                        f"auto_collection_detected=True distinct_episodes={distinct_episode_count} "
                        f"task_directory={task_directory is not None}"
                    )
                    if task_directory is not None:
                        return resolved(
                            task_directory,
                            candidates=candidates,
                            task_files_authoritative=bool(file_items),
                        )
                selected, selection_error = _select_single_episode_video(
                    candidates,
                    expected_episode=expected_episode,
                    episode_parse_rules=episode_parse_rules,
                    context_season_number=context_season_number,
                )
                diagnostics.append(
                    f"task_files={len(file_items)} video_candidates={len(candidates)} selected={selected is not None}"
                )
                if resolution_error is None and selected is not None:
                    return resolved(
                        selected,
                        candidates=candidates,
                        task_files_authoritative=bool(file_items),
                    )
                if content_directories:
                    if resolution_error is not None:
                        pass
                    elif not candidates and task_files_error:
                        resolution_error = "下载器文件列表暂时不可用，任务目录中也没有可验证的视频文件。"
                        resolution_retryable = True
                        resolution_reason_code = "task_files_unavailable"
                    elif not candidates and task_id and not file_items:
                        resolution_error = "下载器文件列表尚未同步，任务目录中没有可验证的视频文件。"
                        resolution_retryable = True
                        resolution_reason_code = "task_files_not_synchronized"
                    elif not candidates and selected_video_items:
                        resolution_error = "目标视频文件尚未稳定或本地大小与下载器记录不一致，等待下载完成。"
                        resolution_retryable = True
                        resolution_reason_code = "target_video_not_stable"
                    elif not candidates and file_items:
                        resolution_error = "下载目录存在，但任务文件列表中没有已选择且可访问的视频文件。"
                    else:
                        resolution_error = selection_error
            elif task_progress_incomplete:
                resolution_error = "下载器任务尚未完成，且无法验证目标视频文件，等待下载完成。"
                resolution_retryable = True
                resolution_reason_code = "task_incomplete"
            if resolution_error is None and torrent_save_path and torrent_name:
                candidate = Path(torrent_save_path).expanduser() / torrent_name
                diagnostics.append(f"save_plus_name_exists={candidate.exists()} dir={candidate.is_dir()}")
                if (
                    candidate.exists()
                    and candidate.is_file()
                    and candidate.suffix.casefold() in VIDEO_EXTENSIONS
                    and candidate.stat().st_size > 0
                    and not prefer_directory
                ):
                    return resolved(candidate)
                if candidate.exists() and candidate.is_dir() and prefer_directory:
                    directory_candidates = _safe_directory_video_candidates(candidate)
                    if directory_candidates:
                        return resolved(candidate, candidates=directory_candidates)
    if resolution_error:
        diagnostics.append("source_resolution=ambiguous_or_missing_video")
        raise OrganizeSourceResolutionError(
            resolution_error,
            diagnostics,
            retryable=resolution_retryable,
            reason_code=resolution_reason_code,
        )
    source_path = _source_path_from_download_history(history, store, prefer_directory=prefer_directory)
    if source_path is None:
        diagnostics.append("source_resolution=no_supported_local_video")
        local_candidates = _candidate_source_paths(history, history.title, store)
        if prefer_directory and not any(candidate.exists() for candidate in local_candidates):
            message = "下载路径不存在，无法建立合集整理预览。"
            reason_code = "download_path_missing"
        elif prefer_directory:
            message = "合集目录中未找到可整理的视频文件。"
            reason_code = "batch_has_no_video"
        else:
            message = "没有找到可安全整理的视频文件。"
            reason_code = "no_supported_local_video"
        raise OrganizeSourceResolutionError(
            message,
            diagnostics,
            reason_code=reason_code,
        )
    candidate = Path(source_path).expanduser()
    diagnostics.append(f"local_candidate={candidate} exists={candidate.exists()} dir={candidate.is_dir()}")
    if candidate.is_file() and (
        candidate.suffix.casefold() not in VIDEO_EXTENSIONS
        or is_ignored_media_metadata_path(candidate)
        or candidate.stat().st_size <= 0
    ):
        diagnostics.append("source_resolution=unsafe_local_file")
        raise OrganizeSourceResolutionError(
            "本地候选不是可安全整理的视频文件。",
            diagnostics,
            reason_code="unsafe_local_file",
        )
    return resolved(source_path)


async def _source_path_from_download_history_with_downloader(
    history: DownloadHistory,
    store: Store,
    *,
    prefer_directory: bool = False,
    expected_episode: int | None = None,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
    context_season_number: int | None = None,
) -> tuple[str, list[str]]:
    resolution = await _resolve_download_history_source(
        history,
        store,
        prefer_directory=prefer_directory,
        expected_episode=expected_episode,
        episode_parse_rules=episode_parse_rules,
        context_season_number=context_season_number,
    )
    return resolution.source_path, list(resolution.diagnostics)


async def _source_path_from_download_history_with_qbittorrent(
    history: DownloadHistory,
    store: Store,
    *,
    prefer_directory: bool = False,
) -> tuple[str, list[str]]:
    return await _source_path_from_download_history_with_downloader(
        history,
        store,
        prefer_directory=prefer_directory,
    )


def _preview_with_destination(
    *,
    source_path: str,
    library_root: str,
    original_filename: str,
    mapping: PlexSeasonMapping,
    season_number: int,
    episode_number: int | None,
    is_special: bool = False,
    episode_title: str | None = None,
) -> OrganizePreviewItem:
    parsed = ParsedAnimeTitle(
        original_title=original_filename,
        title=mapping.show_name,
        season=season_number,
        season_number=season_number,
        episode=episode_number,
        episode_number=episode_number,
        is_special=is_special,
    )
    return build_preview(
        OrganizePreviewRequest(
            source_path=source_path,
            library_root=library_root,
            original_filename=original_filename,
            parsed_title=parsed,
            mapping=mapping.model_copy(update={"season_number": season_number}),
            episode_title=episode_title,
            is_special=is_special,
        )
    )


def _batch_file_mapping(
    *,
    file_path: Path,
    library_root: str,
    mapping: PlexSeasonMapping,
    subscription: Subscription | None = None,
    fallback_season: int | None = None,
    parsed_title: ParsedAnimeTitle | None = None,
) -> OrganizePreviewFileMapping:
    parsed = parsed_title or parse_title(
        file_path.name,
        subscription.episode_parse_rules if subscription else [],
        context_season_number=subscription.season if subscription else fallback_season,
    )
    season = parsed.effective_season_number or parsed.season_number or parsed.season or fallback_season or mapping.season_number
    episode = parsed.episode
    is_special = bool(parsed.is_special or season == 0)
    status: Literal["ready", "needs_confirmation", "skipped", "error"] = "ready"
    message = "可整理"
    warnings: list[str] = []
    if episode is None:
        status = "needs_confirmation"
        message = "需要确认集数"
        warnings.append("未识别到集数，请填写 Episode 或跳过该文件。")
        episode = 1
    preview = _preview_with_destination(
        source_path=str(file_path),
        library_root=library_root,
        original_filename=file_path.name,
        mapping=mapping,
        season_number=season,
        episode_number=episode,
        is_special=is_special,
    )
    if status == "needs_confirmation":
        episode = None
    elif _organize_target_conflicts(file_path, Path(preview.destination_preview).expanduser()):
        status = "error"
        message = "目标文件已存在"
        warnings.append("目标路径已经存在其他文件，不能覆盖。")
    return OrganizePreviewFileMapping(
        id=str(file_path),
        source_path=str(file_path),
        original_filename=file_path.name,
        parsed_episode=parsed.episode,
        season_number=season,
        episode_number=episode,
        is_special=is_special,
        target_filename=preview.filename,
        target_path=preview.destination_preview,
        status=status,
        message=message,
        warnings=warnings,
        subtitle_mappings=preview.subtitle_mappings,
    )


def _subscription_batch_file_plan(
    *,
    files: list[Path],
    library_root: str,
    mapping: PlexSeasonMapping,
    subscription: Subscription,
    manual_override: bool,
    override_reason: str | None,
) -> tuple[list[OrganizePreviewFileMapping], dict[str, ParsedAnimeTitle]]:
    rows: list[OrganizePreviewFileMapping] = []
    parsed_by_source: dict[str, ParsedAnimeTitle] = {}
    reason = (override_reason or "").strip()
    for file_path in files:
        parsed = parse_title(
            file_path.name,
            subscription.episode_parse_rules,
            context_season_number=subscription.season,
        )
        source_key = str(file_path)
        parsed_by_source[source_key] = parsed
        row = _batch_file_mapping(
            file_path=file_path,
            library_root=library_root,
            mapping=mapping,
            subscription=subscription,
            fallback_season=subscription.season,
            parsed_title=parsed,
        )
        conflict_message = _season_conflict_message(subscription, parsed)
        if conflict_message and row.status != "error":
            if not manual_override:
                row = row.model_copy(
                    update={
                        "status": "needs_confirmation",
                        "message": conflict_message,
                        "warnings": [*row.warnings, conflict_message],
                    }
                )
            elif not reason:
                message = "跨季整理需要填写确认原因。"
                row = row.model_copy(
                    update={
                        "status": "needs_confirmation",
                        "message": message,
                        "warnings": [*row.warnings, message],
                    }
                )
            else:
                row = row.model_copy(
                    update={
                        "manual_override": True,
                        "override_reason": reason,
                    }
                )
        rows.append(row)
    return _mark_duplicate_mapping_targets(rows), parsed_by_source


async def _apply_preview_without_blocking(
    preview: OrganizePreviewItem,
    *,
    preserve_source: bool,
) -> OrganizeApplyResult:
    worker = asyncio.create_task(asyncio.to_thread(
        apply_preview,
        preview,
        preserve_source=preserve_source,
    ))
    try:
        return await asyncio.shield(worker)
    except asyncio.CancelledError:
        # A filesystem thread cannot be cancelled. Observe its commit before recording the outcome.
        return await worker


def _file_identity(path: str) -> dict[str, int] | None:
    candidate = Path(path).expanduser()
    try:
        if candidate.is_symlink() or not candidate.is_file():
            return None
        stat = candidate.stat()
        return {"device": stat.st_dev, "inode": stat.st_ino, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
    except OSError:
        return None


def _successful_preview_payload(preview: OrganizePreviewItem) -> dict[str, Any]:
    payload = preview.model_dump(mode="json")
    payload["_target_identity"] = _file_identity(preview.destination_preview)
    return payload


def _existing_successful_apply_result(
    store: Store,
    preview: OrganizePreviewItem,
    *,
    subscription_id: int | None,
) -> tuple[OrganizeApplyResult, dict[str, Any]] | None:
    record = store.successful_organize_history(
        source_path=preview.source_path,
        destination_path=preview.destination_preview,
        subscription_id=subscription_id,
    )
    if record is None:
        return None
    identity = record.get("preview", {}).get("_target_identity")
    if identity is not None and identity != _file_identity(preview.destination_preview):
        return None
    destination = Path(preview.destination_preview).expanduser()
    try:
        if not destination.is_file() or destination.stat().st_size <= 0:
            return None
    except OSError:
        return None
    return (
        OrganizeApplyResult(
            status="skipped",
            message="该源文件已成功整理，已跳过重复执行",
            source_path=preview.source_path,
            destination_path=preview.destination_preview,
        ),
        record,
    )


def _preview_has_persisted_success(
    store: Store,
    preview: OrganizePreviewItem,
    *,
    subscription_id: int | None,
) -> bool:
    mappings = [row for row in preview.file_mappings if row.status != "skipped"]
    if mappings:
        return all(
            _existing_successful_apply_result(
                store,
                _file_preview_from_mapping(preview, row),
                subscription_id=subscription_id,
            )
            is not None
            for row in mappings
        )
    return _existing_successful_apply_result(
        store,
        preview,
        subscription_id=subscription_id,
    ) is not None


def _organize_target_conflicts(source: Path, target: Path) -> bool:
    if not target.exists():
        return False
    try:
        return not source.samefile(target)
    except OSError:
        return True


def _rebuild_mapping_target(
    row: OrganizePreviewFileMapping,
    *,
    library_root: str,
    mapping: PlexSeasonMapping,
) -> OrganizePreviewFileMapping:
    if row.status == "skipped":
        return row
    if row.episode_number is None:
        return row.model_copy(update={"status": "needs_confirmation", "message": "需要确认集数"})
    preview = _preview_with_destination(
        source_path=row.source_path,
        library_root=library_root,
        original_filename=row.original_filename,
        mapping=mapping,
        season_number=row.season_number,
        episode_number=row.episode_number,
        is_special=row.is_special,
    )
    target_path = Path(preview.destination_preview).expanduser()
    conflicts = _organize_target_conflicts(Path(row.source_path).expanduser(), target_path)
    return row.model_copy(
        update={
            "target_filename": preview.filename,
            "target_path": preview.destination_preview,
            "status": "error" if conflicts else "ready",
            "message": "目标文件已存在" if conflicts else "可整理",
            "warnings": ["目标路径已经存在其他文件，不能覆盖。"] if conflicts else [],
            "subtitle_mappings": preview.subtitle_mappings,
        }
    )


def _mark_duplicate_mapping_targets(
    rows: list[OrganizePreviewFileMapping],
) -> list[OrganizePreviewFileMapping]:
    target_groups: dict[str, list[int]] = {}
    for index, row in enumerate(rows):
        if row.status == "skipped":
            continue
        target_key = str(Path(row.target_path).expanduser())
        target_groups.setdefault(target_key, []).append(index)

    duplicate_indexes = {
        index
        for indexes in target_groups.values()
        if len(indexes) > 1
        for index in indexes
    }
    if not duplicate_indexes:
        return rows

    updated = list(rows)
    for index in duplicate_indexes:
        row = updated[index]
        warning = "多个源文件映射到同一个目标文件，请修改集数或跳过重复文件。"
        updated[index] = row.model_copy(
            update={
                "status": "error",
                "message": "目标映射重复",
                "warnings": [*row.warnings, warning],
            }
        )
    return updated


def _apply_file_mapping_overrides(
    rows: list[OrganizePreviewFileMapping],
    request: OrganizePreviewRequest,
) -> list[OrganizePreviewFileMapping]:
    overrides = {item.id: item for item in request.file_mapping_overrides}
    updated: list[OrganizePreviewFileMapping] = []
    for row in rows:
        override = overrides.get(row.id)
        if override is None:
            updated.append(row)
            continue
        if override.skipped:
            updated.append(
                row.model_copy(
                    update={
                        "season_number": override.season_number,
                        "episode_number": override.episode_number,
                        "is_special": override.is_special,
                        "status": "skipped",
                        "message": "已跳过",
                        "manual_override": True,
                        "override_reason": "用户在整理预览中跳过该文件",
                    }
                )
            )
            continue
        manually_changed = (
            row.season_number != override.season_number
            or row.episode_number != override.episode_number
            or row.is_special != override.is_special
        )
        overridden = row.model_copy(
            update={
                "season_number": override.season_number,
                "episode_number": override.episode_number,
                "is_special": override.is_special,
                "status": "ready" if override.episode_number is not None else "needs_confirmation",
                "message": "可整理" if override.episode_number is not None else "需要确认集数",
                "manual_override": manually_changed,
                "override_reason": "用户在整理预览中修改季集映射" if manually_changed else None,
            }
        )
        updated.append(
            _rebuild_mapping_target(
                overridden,
                library_root=request.library_root,
                mapping=request.mapping,
            )
        )
    return _mark_duplicate_mapping_targets(updated)


def _single_file_batch_preview(
    preview: OrganizePreviewItem,
    *,
    parsed: ParsedAnimeTitle,
    mapping: PlexSeasonMapping,
    mode: Literal["as_batch_file", "episode_range", "specials_batch"] = "as_batch_file",
) -> OrganizePreviewItem:
    season = parsed.effective_season_number or parsed.season_number or parsed.season or mapping.season_number
    episode_start = parsed.episode_start or parsed.episode or 1
    episode_end = parsed.episode_end or episode_start
    extension = Path(preview.filename).suffix or Path(preview.source_path).suffix or ".mkv"
    show_name = preview.show_directory.rsplit(" (", 1)[0]
    season_dir = f"Season {season:02d}"
    if mode == "episode_range":
        filename = f"{show_name} - S{season:02d}E{episode_start:02d}-E{episode_end:02d}{extension}"
    elif mode == "specials_batch":
        season_dir = "Specials"
        filename = f"{show_name} - Batch{extension}"
    else:
        filename = f"{show_name} - Batch{extension}"
    destination = str(Path(preview.library_root) / preview.show_directory / season_dir / filename)
    return preview.model_copy(
        update={
            "season_directory": season_dir,
            "filename": filename,
            "destination_preview": destination,
            "is_batch": True,
            "batch_mode": "single_file",
            "single_file_mode": mode,
            "episode_start": episode_start,
            "episode_end": episode_end,
        }
    )


async def _post_apply_download_record_cleanup(
    preview: OrganizePreviewItem,
    store: Store,
    *,
    source_path: str,
) -> tuple[bool, list[str], dict[str, Any]]:
    if preview.download_record_id is None:
        return False, [], _cleanup_result(attempted=False)
    history_item = store.get_history(preview.download_record_id)
    if history_item is None:
        return False, ["下载记录已不存在，整理文件已完成。"], _cleanup_result(attempted=False)
    history = DownloadHistory(**history_item)
    policy = stored_organize_policy(store)
    warnings: list[str] = []
    task_deleted = False
    if policy.delete_task_after_organize:
        try:
            deleted, delete_warnings = await _delete_qbittorrent_tasks_for_history_rows(
                [history.model_dump(mode="json")],
                store,
                delete_files=policy.delete_files_after_organize,
            )
            task_deleted = deleted > 0
            if not task_deleted and delete_warnings:
                warnings.append(f"任务已不在 {downloader_display_name(history.downloader_type)} 中，整理已完成。")
            warnings.extend(delete_warnings)
        except HTTPException as exc:
            warnings.append(str(exc.detail))
        except Exception as exc:
            warnings.append(f"下载器任务清理失败：{describe_downloader_error(history.downloader_type, exc)}")
    store.update_history_status(history.id, "organized_task_removed" if task_deleted else "organized")
    cleanup = await _cleanup_empty_download_dir(history, source_path, store, policy)
    if cleanup.get("cleanup_message"):
        warnings.append(str(cleanup["cleanup_message"]))
    return task_deleted, warnings, cleanup


def _single_batch_review_result(
    match: SubscriptionMatch,
    preview: OrganizePreviewItem,
) -> SubscriptionOrganizeEpisodeResult:
    return SubscriptionOrganizeEpisodeResult(
        episode_number=match.parsed_title.episode,
        match_id=match.id,
        title=match.result.title,
        status="batch_needs_review",
        message="这是单个合集文件，无法自动拆分为单集。请确认后作为合集文件整理。",
        source_path=preview.source_path,
        destination_path=preview.destination_preview,
        subtitle_mappings=preview.subtitle_mappings,
    )


def _batch_mapping_for_match(mapping: PlexSeasonMapping, match: SubscriptionMatch) -> PlexSeasonMapping:
    return mapping


def _season_conflict_message(subscription: Subscription, parsed: ParsedAnimeTitle) -> str | None:
    if parsed.season_conflict and parsed.season_conflict_reason:
        return f"{parsed.season_conflict_reason}。请确认后再整理。"
    if subscription.season is None:
        return None
    explicit = parsed.explicit_season_number
    if explicit is not None and explicit != subscription.season:
        return f"这个资源看起来属于第 {explicit} 季，但当前订阅是第 {subscription.season} 季。请确认后再整理。"
    return None


def _parsed_with_subscription_season(parsed: ParsedAnimeTitle, subscription: Subscription) -> ParsedAnimeTitle:
    if subscription.season is None or _season_conflict_message(subscription, parsed):
        return parsed
    return parsed.model_copy(
        update={
            "season": subscription.season,
            "season_number": subscription.season,
            "context_season_number": subscription.season,
            "effective_season_number": subscription.season,
            "season_source": "subscription",
            "season_conflict": False,
            "season_conflict_reason": None,
        }
    )


def _organize_season_audit(
    subscription: Subscription | None,
    parsed: ParsedAnimeTitle | None,
    *,
    manual_override: bool = False,
    override_reason: str | None = None,
) -> dict[str, Any]:
    return {
        "subscription_season": subscription.season if subscription else None,
        "resource_explicit_season": parsed.explicit_season_number if parsed else None,
        "effective_season": parsed.effective_season_number or parsed.season_number or parsed.season if parsed else None,
        "season_source": parsed.season_source if parsed else None,
        "manual_override": manual_override,
        "override_reason": override_reason,
    }


def _select_organize_matches(
    detail: SubscriptionDetail,
    request: SubscriptionOrganizeRequest,
    *,
    all_downloaded: bool,
) -> list[SubscriptionMatch]:
    match_ids = set(request.match_ids)
    history_by_fingerprint = {item.fingerprint: item for item in detail.history}
    history_by_match_id = {
        match.id: history_by_fingerprint.get(match.fingerprint)
        for match in detail.matches
    }
    if request.episode_numbers:
        episode_numbers = set(request.episode_numbers)
        match_ids.update(
            resource.match_id
            for episode in detail.episode_statuses
            if episode.episode_number in episode_numbers
            and not episode.excluded_by_episode_start
            for resource in episode.matched_resources
        )
    if all_downloaded:
        match_ids.update(
            resource.match_id
            for episode in detail.episode_statuses
            if not episode.excluded_by_episode_start
            and episode.organize_status not in {"已整理", "需要检查"}
            for resource in episode.matched_resources
            if (
                episode.organize_status == "待重新整理"
                or resource.organize_status not in {"已整理", "需要检查", "整理失败"}
            )
            and resource.download_record_id is not None
            and (
                _resource_is_download_complete(resource)
                or (
                    resource.resource_type in {"batch", "episode_range"}
                    and resource.download_status == "下载中"
                )
                or (
                    episode.organize_status == "待重新整理"
                    and history_by_match_id.get(resource.match_id) is not None
                    and _exact_history_source_exists(history_by_match_id[resource.match_id])
                )
            )
            and (
                episode.organize_status == "待重新整理"
                or history_by_match_id.get(resource.match_id) is None
                or history_by_match_id[resource.match_id].status
                not in {"organized_task_removed", "seeding_stopped"}
            )
        )
    if not match_ids:
        return []
    return [match for match in detail.matches if match.id in match_ids]


async def _organize_subscription_matches(
    subscription_id: int,
    request: SubscriptionOrganizeRequest,
    store: Store,
    *,
    all_downloaded: bool = False,
) -> SubscriptionOrganizeResponse:
    if subscription_id in _ORGANIZING_SUBSCRIPTION_IDS:
        return SubscriptionOrganizeResponse(
            ok=True,
            subscription_id=subscription_id,
            message="该订阅正在整理，本次未重复提交",
            dry_run=request.dry_run,
        )
    _ORGANIZING_SUBSCRIPTION_IDS.add(subscription_id)
    try:
        return await _organize_subscription_matches_once(
            subscription_id,
            request,
            store,
            all_downloaded=all_downloaded,
        )
    finally:
        _ORGANIZING_SUBSCRIPTION_IDS.discard(subscription_id)


async def _organize_subscription_matches_once(
    subscription_id: int,
    request: SubscriptionOrganizeRequest,
    store: Store,
    *,
    all_downloaded: bool = False,
) -> SubscriptionOrganizeResponse:
    if not request.confirm and not request.dry_run:
        raise HTTPException(status_code=403, detail="整理媒体文件需要确认，当前未执行。")

    detail = await _build_subscription_detail(subscription_id, store)
    subscription = detail.subscription
    target = _organize_target_for_subscription(subscription, request.organize_target_id, store)
    policy = _organize_policy_for_subscription(subscription, store)
    override_data = {
        "delete_task_after_organize": request.delete_qbittorrent_task_after_success,
        "delete_files_after_organize": request.delete_files_from_qbittorrent,
        "keep_seeding": request.keep_seeding,
    }
    effective_policy = _organize_policy_or_400(override_data, policy)
    keep_seeding = effective_policy.keep_seeding
    delete_task = effective_policy.delete_task_after_organize
    delete_files = effective_policy.delete_files_after_organize

    matches = _select_organize_matches(detail, request, all_downloaded=all_downloaded)
    if not matches:
        return SubscriptionOrganizeResponse(
            ok=True,
            subscription_id=subscription_id,
            message="没有可整理的已下载剧集",
            dry_run=request.dry_run,
            target=target,
        )

    history_by_fingerprint = {item.fingerprint: item for item in detail.history}
    mapping = _mapping_for_subscription(subscription, detail.metadata_bindings, detail.plex_mappings)
    results: list[SubscriptionOrganizeEpisodeResult] = []
    warnings: list[str] = []

    for match in matches:
        history = history_by_fingerprint.get(match.fingerprint)
        episode_number = match.parsed_title.episode
        title = match.result.title
        conflict_message = _season_conflict_message(subscription, match.parsed_title)
        if conflict_message and not request.manual_override:
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="needs_review",
                    message=conflict_message,
                )
            )
            continue
        if conflict_message and request.manual_override and not (request.override_reason or "").strip():
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="needs_review",
                    message="跨季整理需要填写确认原因。",
                )
            )
            continue
        if history is None:
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="skipped",
                    message="没有下载记录，已跳过",
                )
            )
            continue
        resource_mapping = _batch_mapping_for_match(mapping, match)
        match_parsed = _parsed_with_subscription_season(match.parsed_title, subscription)
        collection_resource = is_collection_parsed(match.parsed_title)
        try:
            source_resolution = await _resolve_download_history_source(
                history,
                store,
                prefer_directory=collection_resource,
                allow_partial_batch=collection_resource,
                expected_episode=match.parsed_title.episode,
                episode_parse_rules=subscription.episode_parse_rules,
                context_season_number=subscription.season,
            )
            source_path = source_resolution.source_path
            source_diagnostics = list(source_resolution.diagnostics)
        except OrganizeSourceResolutionError as exc:
            logger.info("subscription organize source diagnostics: %s", " | ".join(exc.diagnostics))
            if exc.retryable:
                results.append(
                    SubscriptionOrganizeEpisodeResult(
                        episode_number=episode_number,
                        match_id=match.id,
                        title=title,
                        status="waiting_download",
                        message=exc.message,
                    )
                )
                continue
            source_hint = history.save_path or history.torrent_name or title
            failed_preview = build_preview(
                OrganizePreviewRequest(
                    source_path=source_hint,
                    download_record_id=history.id,
                    library_root=target.path,
                    organize_target_id=target.id,
                    original_filename=history.torrent_name or Path(source_hint).name or title,
                    parsed_title=match_parsed,
                    mapping=resource_mapping,
                )
            )
            if request.dry_run:
                results.append(
                    SubscriptionOrganizeEpisodeResult(
                        episode_number=episode_number,
                        match_id=match.id,
                        title=title,
                        status="error",
                        message=exc.message,
                        source_path=source_hint,
                        destination_path=failed_preview.destination_preview,
                    )
                )
                continue
            record = store.add_organize_history(
                source_path=source_hint,
                destination_path=failed_preview.destination_preview,
                status="error",
                message=exc.message,
                preview=failed_preview.model_dump(mode="json"),
                subscription_id=subscription_id,
                **_organize_season_audit(
                    subscription,
                    match_parsed,
                    manual_override=bool(conflict_message and request.manual_override),
                    override_reason=request.override_reason if conflict_message and request.manual_override else None,
                ),
            )
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="error",
                    message=exc.message,
                    source_path=source_hint,
                    destination_path=failed_preview.destination_preview,
                    history_id=record["id"],
                )
            )
            continue
        logger.info("subscription organize source diagnostics: %s", " | ".join(source_diagnostics))
        original_filename = Path(source_path).name or history.torrent_name or title
        source_is_existing_file = Path(source_path).expanduser().is_file()
        if collection_resource:
            batch_files = (
                [Path(item) for item in source_resolution.completed_video_paths]
                if source_resolution.task_files_authoritative
                else _batch_video_files(source_path)
            )
            partial_batch = bool(source_resolution.incomplete_video_files)
            if batch_files:
                batch_rows, parsed_by_source = _subscription_batch_file_plan(
                    files=batch_files,
                    library_root=target.path,
                    mapping=resource_mapping,
                    subscription=subscription,
                    manual_override=request.manual_override,
                    override_reason=request.override_reason,
                )
                batch_preview = build_preview(
                    OrganizePreviewRequest(
                        source_path=source_path,
                        download_record_id=history.id,
                        library_root=target.path,
                        organize_target_id=target.id,
                        original_filename=original_filename,
                        parsed_title=match_parsed,
                        mapping=resource_mapping,
                    )
                ).model_copy(
                    update={
                        "is_batch": True,
                        "batch_mode": "multi_file",
                        "partial_batch": partial_batch,
                        "file_mappings": batch_rows,
                    }
                )
                blocking_rows = [
                    row
                    for row in batch_rows
                    if row.status in {"error", "needs_confirmation"} or row.episode_number is None
                ]
                if blocking_rows:
                    warnings.append("合集逐文件预检未通过，整批未执行，未写入整理成功记录。")
                    for row in batch_rows:
                        parsed = parsed_by_source[row.source_path]
                        blocked = row in blocking_rows
                        results.append(
                            SubscriptionOrganizeEpisodeResult(
                                episode_number=parsed.episode,
                                match_id=match.id,
                                title=row.original_filename,
                                status="error" if row.status == "error" else "needs_review",
                                message=row.message if blocked else "同批次存在冲突，整批未执行。",
                                source_path=row.source_path,
                                destination_path=row.target_path,
                                subtitle_mappings=row.subtitle_mappings,
                            )
                        )
                    continue
                try:
                    _preflight_batch_apply(batch_preview)
                except HTTPException as exc:
                    warnings.append("合集目标预检未通过，整批未执行，未写入整理成功记录。")
                    results.append(
                        SubscriptionOrganizeEpisodeResult(
                            episode_number=episode_number,
                            match_id=match.id,
                            title=title,
                            status="error",
                            message=str(exc.detail),
                            source_path=source_path,
                        )
                    )
                    continue
                if request.dry_run:
                    for row in batch_rows:
                        parsed = parsed_by_source[row.source_path]
                        results.append(
                            SubscriptionOrganizeEpisodeResult(
                                episode_number=parsed.episode,
                                match_id=match.id,
                                title=row.original_filename,
                                status="preview",
                                message="合集文件将按文件名中的明确集数整理",
                                source_path=row.source_path,
                                destination_path=row.target_path,
                                subtitle_mappings=row.subtitle_mappings,
                            )
                        )
                    continue

                batch_completed = 0
                runtime_failed = False
                for index, row in enumerate(batch_rows):
                    file_parsed = parsed_by_source[row.source_path]
                    file_preview = _file_preview_from_mapping(batch_preview, row)
                    replayed = _existing_successful_apply_result(
                        store,
                        file_preview,
                        subscription_id=subscription_id,
                    )
                    if replayed is not None:
                        apply_result, record = replayed
                        batch_completed += 1
                        results.append(
                            SubscriptionOrganizeEpisodeResult(
                                episode_number=file_parsed.episode,
                                match_id=match.id,
                                title=row.original_filename,
                                status=apply_result.status,
                                message=apply_result.message,
                                source_path=apply_result.source_path,
                                destination_path=apply_result.destination_path,
                                history_id=record["id"],
                                subtitle_mappings=file_preview.subtitle_mappings,
                            )
                        )
                        continue
                    try:
                        apply_result = await _apply_preview_without_blocking(file_preview, preserve_source=keep_seeding)
                    except OrganizeApplyError as exc:
                        runtime_failed = True
                        destination_path = exc.destination_path or file_preview.destination_preview
                        record = store.add_organize_history(
                            source_path=file_preview.source_path,
                            destination_path=destination_path,
                            status="error",
                            message=exc.message,
                            preview=file_preview.model_dump(mode="json"),
                            subscription_id=subscription_id,
                            **_organize_season_audit(
                                subscription,
                                file_parsed,
                                manual_override=row.manual_override,
                                override_reason=row.override_reason,
                            ),
                        )
                        results.append(
                            SubscriptionOrganizeEpisodeResult(
                                episode_number=file_parsed.episode,
                                match_id=match.id,
                                title=row.original_filename,
                                status="error",
                                message=exc.message,
                                source_path=file_preview.source_path,
                                destination_path=destination_path,
                                history_id=record["id"],
                            )
                        )
                        for pending_row in batch_rows[index + 1 :]:
                            pending_parsed = parsed_by_source[pending_row.source_path]
                            results.append(
                                SubscriptionOrganizeEpisodeResult(
                                    episode_number=pending_parsed.episode,
                                    match_id=match.id,
                                    title=pending_row.original_filename,
                                    status="needs_review",
                                    message="同批次前序文件整理失败，后续文件未执行。",
                                    source_path=pending_row.source_path,
                                    destination_path=pending_row.target_path,
                                )
                            )
                        break
                    batch_completed += 1
                    record = store.add_organize_history(
                        source_path=apply_result.source_path,
                        destination_path=apply_result.destination_path,
                        status=apply_result.status,
                        message=apply_result.message,
                        preview=file_preview.model_dump(mode="json"),
                        subscription_id=subscription_id,
                        **_organize_season_audit(
                            subscription,
                            file_parsed,
                            manual_override=row.manual_override,
                            override_reason=row.override_reason,
                        ),
                    )
                    if not record.get("deduplicated"):
                        await _notification_service(store).send_best_effort(
                            organize_completed_event(store, record, subscription)
                        )
                    results.append(
                        SubscriptionOrganizeEpisodeResult(
                            episode_number=file_parsed.episode,
                            match_id=match.id,
                            title=row.original_filename,
                            status=apply_result.status,
                            message=apply_result.message,
                            source_path=apply_result.source_path,
                            destination_path=apply_result.destination_path,
                            history_id=record["id"],
                            subtitle_mappings=file_preview.subtitle_mappings,
                        )
                    )
                if runtime_failed:
                    warnings.append("合集整理发生运行时错误，已停止后续文件，下载记录未标记为已整理。")
                if batch_completed == len(batch_rows) and not runtime_failed and not partial_batch:
                    task_deleted = False
                    if delete_task:
                        try:
                            deleted, delete_warnings = await _delete_qbittorrent_tasks_for_history_rows(
                                [history.model_dump(mode="json")],
                                store,
                                delete_files=delete_files,
                            )
                            task_deleted = deleted > 0
                            if not task_deleted and delete_warnings:
                                warnings.append(f"任务已不在 {downloader_display_name(history.downloader_type)} 中，整理已完成。")
                            warnings.extend(delete_warnings)
                        except HTTPException as exc:
                            warnings.append(str(exc.detail))
                        except Exception as exc:
                            warnings.append(f"下载器任务清理失败：{describe_downloader_error(history.downloader_type, exc)}")
                    store.update_history_status(history.id, "organized_task_removed" if task_deleted else "organized")
                    cleanup = await _cleanup_empty_download_dir(history, source_path, store, effective_policy)
                    if cleanup.get("cleanup_message"):
                        warnings.append(str(cleanup["cleanup_message"]))
                elif batch_completed and not runtime_failed and partial_batch:
                    warnings.append(
                        f"本轮已整理 {batch_completed} 个已完成视频，另有 "
                        f"{len(source_resolution.incomplete_video_files)} 个视频等待下载完成。"
                    )
                continue
        preview_request = OrganizePreviewRequest(
            source_path=source_path,
            download_record_id=history.id,
            library_root=target.path,
            organize_target_id=target.id,
            original_filename=original_filename,
            parsed_title=match_parsed,
            mapping=resource_mapping,
        )
        preview = build_preview(preview_request)
        preview_payload = preview.model_dump(mode="json")
        if collection_resource and source_is_existing_file and request.dry_run:
            results.append(_single_batch_review_result(match, preview))
            continue
        if request.dry_run:
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="preview",
                    message="将整理到目标路径",
                    source_path=preview.source_path,
                    destination_path=preview.destination_preview,
                    subtitle_mappings=preview.subtitle_mappings,
                )
            )
            continue
        replayed = _existing_successful_apply_result(
            store,
            preview,
            subscription_id=subscription_id,
        )
        replayed_record: dict[str, Any] | None = None
        try:
            if replayed is None:
                apply_result = await _apply_preview_without_blocking(preview, preserve_source=keep_seeding)
            else:
                apply_result, replayed_record = replayed
        except OrganizeApplyError as exc:
            destination_path = exc.destination_path or preview.destination_preview
            record = store.add_organize_history(
                source_path=preview.source_path,
                destination_path=destination_path,
                status="error",
                message=exc.message,
                preview=preview_payload,
                subscription_id=subscription_id,
                **_organize_season_audit(
                    subscription,
                    match_parsed,
                    manual_override=bool(conflict_message and request.manual_override),
                    override_reason=request.override_reason if conflict_message and request.manual_override else None,
                ),
            )
            results.append(
                SubscriptionOrganizeEpisodeResult(
                    episode_number=episode_number,
                    match_id=match.id,
                    title=title,
                    status="error",
                    message=exc.message,
                    source_path=preview.source_path,
                    destination_path=destination_path,
                    history_id=record["id"],
                )
            )
            continue

        task_deleted = False
        if delete_task:
            try:
                deleted, delete_warnings = await _delete_qbittorrent_tasks_for_history_rows(
                    [history.model_dump(mode="json")],
                    store,
                    delete_files=delete_files,
                )
                task_deleted = deleted > 0
                warnings.extend(delete_warnings)
            except HTTPException as exc:
                warnings.append(str(exc.detail))
            except Exception as exc:
                warnings.append(f"下载器任务清理失败：{describe_downloader_error(history.downloader_type, exc)}")
        if history.id:
            store.update_history_status(history.id, "organized_task_removed" if task_deleted else "organized")
        cleanup = await _cleanup_empty_download_dir(history, apply_result.source_path, store, effective_policy)
        record = replayed_record or store.add_organize_history(
            source_path=apply_result.source_path,
            destination_path=apply_result.destination_path,
            status=apply_result.status,
            message=apply_result.message,
            preview=preview_payload,
            subscription_id=subscription_id,
            qbittorrent_task_deleted=task_deleted,
            delete_files_from_qbittorrent=delete_files,
            **cleanup,
            **_organize_season_audit(
                subscription,
                match_parsed,
                manual_override=bool(conflict_message and request.manual_override),
                override_reason=request.override_reason if conflict_message and request.manual_override else None,
            ),
        )
        if replayed_record is None and not record.get("deduplicated"):
            await _notification_service(store).send_best_effort(
                organize_completed_event(store, record, subscription)
            )
        results.append(
            SubscriptionOrganizeEpisodeResult(
                episode_number=episode_number,
                match_id=match.id,
                title=title,
                status=apply_result.status,
                message=f"已整理并移除 {downloader_display_name(history.downloader_type)} 任务" if task_deleted else apply_result.message,
                source_path=apply_result.source_path,
                destination_path=apply_result.destination_path,
                history_id=record["id"],
                qbittorrent_task_deleted=task_deleted,
                delete_files_from_qbittorrent=delete_files,
                subtitle_mappings=preview.subtitle_mappings,
                **cleanup,
            )
        )

    organized = sum(1 for item in results if item.status in {"moved", "skipped"})
    failed = sum(1 for item in results if item.status == "error")
    skipped = sum(1 for item in results if item.status == "skipped")
    waiting = sum(1 for item in results if item.status == "waiting_download")
    if request.dry_run:
        if waiting and waiting == len(results):
            message = f"{waiting} 个下载项仍在等待下载完成"
        else:
            message = f"将整理 {len(results) - waiting} 集到 {target.name}"
    else:
        message = f"已整理 {organized} 集"
        if waiting:
            message += f"，等待下载 {waiting} 项"
        if failed:
            message += f"，失败 {failed} 集"
    return SubscriptionOrganizeResponse(
        ok=failed == 0,
        subscription_id=subscription_id,
        message=message,
        organized=organized,
        skipped=skipped,
        failed=failed,
        dry_run=request.dry_run,
        target=target,
        results=results,
        warnings=warnings,
    )


@router.post("/subscriptions/{subscription_id}/organize", response_model=SubscriptionOrganizeResponse)
async def organize_subscription_downloaded(
    subscription_id: int,
    request: SubscriptionOrganizeRequest,
    store: Store = Depends(get_store),
) -> SubscriptionOrganizeResponse:
    return await _organize_subscription_matches(subscription_id, request, store, all_downloaded=True)


@router.post("/subscriptions/{subscription_id}/episodes/organize", response_model=SubscriptionOrganizeResponse)
async def organize_subscription_selected_episodes(
    subscription_id: int,
    request: SubscriptionOrganizeRequest,
    store: Store = Depends(get_store),
) -> SubscriptionOrganizeResponse:
    return await _organize_subscription_matches(subscription_id, request, store, all_downloaded=False)


@router.post("/subscriptions/{subscription_id}/episodes/{episode_id}/organize", response_model=SubscriptionOrganizeResponse)
async def organize_subscription_episode(
    subscription_id: int,
    episode_id: int,
    request: SubscriptionOrganizeRequest | None = None,
    store: Store = Depends(get_store),
) -> SubscriptionOrganizeResponse:
    payload = request or SubscriptionOrganizeRequest(confirm=True)
    detail = await _build_subscription_detail(subscription_id, store)
    match_exists = any(match.id == episode_id for match in detail.matches)
    payload = payload.model_copy(
        update={
            "match_ids": [episode_id] if match_exists else payload.match_ids,
            "episode_numbers": payload.episode_numbers if match_exists else [episode_id],
        }
    )
    return await _organize_subscription_matches(subscription_id, payload, store, all_downloaded=False)


@router.post("/subscriptions/{subscription_id}/download", response_model=SubscriptionDownloadResponse)
async def download_subscription_matches(
    subscription_id: int,
    request: SubscriptionDownloadRequest,
    store: Store = Depends(get_store),
) -> SubscriptionDownloadResponse:
    subscription = _subscription_or_404(subscription_id, store)
    if request.all_matches:
        matches = _subscription_match_models(store.list_subscription_matches(subscription_id))
    else:
        if not request.match_ids:
            raise HTTPException(status_code=400, detail="请选择要下载的匹配条目")
        matches = []
        for match_id in request.match_ids:
            item = store.get_subscription_match(subscription_id, match_id)
            if item is None:
                raise HTTPException(status_code=404, detail=f"匹配条目不存在：{match_id}")
            matches.append(SubscriptionMatch(**item))

    current_matches = _subscription_matches_with_current_size_bounds(subscription, matches)
    current_match_ids = {match.id for match in current_matches}
    stale_matches = [match for match in matches if match.id not in current_match_ids]
    matches = current_matches
    stale_results = [match.result for match in stale_matches]
    stale_warnings = [
        f"{match.result.title}：不再符合当前订阅规则，已跳过"
        for match in stale_matches
    ]

    if not matches:
        return SubscriptionDownloadResponse(
            subscription_id=subscription_id,
            ok=True,
            message=f"没有可提交的匹配条目，跳过 {len(stale_results)} 个失效候选",
            skipped=stale_results,
            warnings=stale_warnings,
        )

    downloader_type = stored_downloader_routing(store).subscription_downloader
    config = stored_transmission_config(store) if downloader_type == "transmission" else stored_qbittorrent_config(store)
    client = None
    if not request.dry_run:
        try:
            client = _configured_downloader_client(store, downloader_type)
        except Exception as exc:
            raise HTTPException(status_code=400, detail=describe_downloader_error(downloader_type, exc)) from exc

    existing_history = {
        item["fingerprint"]: item
        for item in store.list_history(subscription_id=subscription_id)
    }
    submitted: list[SearchResult] = []
    skipped: list[SearchResult] = list(stale_results)
    history_ids: list[int] = []
    warnings: list[str] = list(stale_warnings)

    for match in matches:
        result = match.result
        source = normalize_site_id(result.source)
        if source in default_site_settings():
            adapter = get_site_adapter(source, stored_site_settings(store))
            restriction = site_usage_restriction(adapter, "subscription", respect_site_enabled=False)
            if restriction and restriction[0] == "site_brush_only":
                skipped.append(result)
                warnings.append(f"{result.title}：{restriction[1]}")
                continue
        previous = existing_history.get(match.fingerprint)
        if previous and previous["status"] == "queued":
            skipped.append(result)
            warnings.append(f"已提交过，跳过：{result.title}")
            continue
        url = result.magnet_url or result.download_url
        if not url:
            skipped.append(result)
            warnings.append(f"资源没有可下载链接：{result.title}")
            store.upsert_subscription_match(
                subscription_id=subscription.id,
                fingerprint=match.fingerprint,
                result=result.model_dump(mode="json"),
                parsed_title=match.parsed_title.model_dump(mode="json"),
                status="error",
            )
            continue
        if request.dry_run:
            dry_save_path = _download_save_path(subscription.save_path or (config.default_save_path if config else None), subscription.name)
            history_id = _record_download_history(store, result, subscription_id=subscription.id, status="dry_run", save_path=dry_save_path, downloader_type=downloader_type)
            store.upsert_subscription_match(
                subscription_id=subscription.id,
                fingerprint=match.fingerprint,
                result=result.model_dump(mode="json"),
                parsed_title=match.parsed_title.model_dump(mode="json"),
                status="dry_run",
            )
        else:
            try:
                assert client is not None
                assert config is not None
                effective_save_path = _download_save_path(subscription.save_path or config.default_save_path, subscription.name)
                category = subscription.category or (config.default_category if isinstance(config, QbittorrentConfig) else None)
                default_tags = config.default_tags if isinstance(config, QbittorrentConfig) else config.default_labels
                lookup_tag = subscription_download_tag(subscription.id, match.fingerprint) if downloader_type == "qbittorrent" else None
                submission_tags = list(dict.fromkeys([*(subscription.tags or default_tags), *([lookup_tag] if lookup_tag else [])]))
                add_result = await submit_result_to_downloader(
                    client,
                    result,
                    save_path=effective_save_path,
                    category=category,
                    tags=submission_tags,
                    lookup_tag=lookup_tag,
                    site_settings=stored_site_settings(store),
                )
                history_id = _record_download_history(
                    store,
                    result,
                    subscription_id=subscription.id,
                    status="queued",
                    save_path=effective_save_path,
                    downloader_type=downloader_type,
                    remote_task_id=add_result.remote_task_id,
                    torrent_hash=add_result.torrent_hash,
                    torrent_name=add_result.torrent_name,
                )
                await _remember_submitted_torrent(
                    client,
                    store,
                    history_id,
                    add_result=add_result,
                    downloader_type=downloader_type,
                )
                if downloader_type == "qbittorrent":
                    mapped_history = store.get_history(history_id) or {}
                    with suppress(Exception):
                        await release_subscription_download_tag(
                            client,
                            lookup_tag,
                            torrent_hash=add_result.torrent_hash or mapped_history.get("qbittorrent_hash"),
                        )
                store.upsert_subscription_match(
                    subscription_id=subscription.id,
                    fingerprint=match.fingerprint,
                    result=result.model_dump(mode="json"),
                    parsed_title=match.parsed_title.model_dump(mode="json"),
                    status="queued",
                )
                if add_result.duplicate:
                    skipped.append(result)
                    warnings.append(f"{downloader_display_name(downloader_type)} 任务已存在，已完成映射：{result.title}")
                else:
                    notification_size = resource_total_size_bytes(result) or add_result.content_size or await confirmed_task_size_bytes(client, add_result)
                    event = download_started_event(
                        store,
                        subscription,
                        result,
                        history_id,
                        effective_save_path,
                        size_bytes=notification_size,
                        downloader_type=downloader_type,
                    )
                    await send_or_defer_size_notification(
                        store,
                        event,
                        [history_size_target(history_id, notification_size)],
                    )
            except Exception as exc:
                error_message = describe_downloader_error(downloader_type, exc)
                skipped.append(result)
                warnings.append(f"{downloader_display_name(downloader_type)} 添加任务失败：{result.title}，{error_message}")
                store.upsert_subscription_match(
                    subscription_id=subscription.id,
                    fingerprint=match.fingerprint,
                    result=result.model_dump(mode="json"),
                    parsed_title=match.parsed_title.model_dump(mode="json"),
                    status="error",
                )
                await _notification_service(store).send_best_effort(
                    download_failed_event(store, subscription, result, error_message)
                )
                continue
        if request.dry_run or not add_result.duplicate:
            submitted.append(result)
        history_ids.append(history_id)

    action = "记录试运行" if request.dry_run else "提交下载"
    return SubscriptionDownloadResponse(
        subscription_id=subscription_id,
        ok=True,
        message=f"已{action} {len(submitted)} 个匹配条目，跳过 {len(skipped)} 个",
        submitted=submitted,
        skipped=skipped,
        history_ids=history_ids,
        warnings=warnings,
    )


@router.post("/subscriptions/refresh-all", response_model=RefreshAllResponse)
@router.post("/subscriptions/refresh_all", response_model=RefreshAllResponse)
async def refresh_all_subscriptions(store: Store = Depends(get_store)) -> RefreshAllResponse:
    return await refresh_all_enabled(
        store,
        qbittorrent_config=stored_qbittorrent_config(store),
    )


def _automation_service(request: Request):
    if not hasattr(request.app.state, "automation"):
        request.app.state.automation = AutomationService(get_store)
    configure_automation_service(request.app.state.automation)
    return request.app.state.automation


def configure_automation_service(service: AutomationService) -> AutomationService:
    service.post_refresh_hook = _automation_post_refresh_hook
    return service


async def _automation_post_refresh_hook(store: Store, response: RefreshAllResponse) -> dict[str, int]:
    organized_count = 0
    error_count = 0
    seen_subscription_ids = {item.subscription_id for item in response.responses}
    for subscription_id in sorted(seen_subscription_ids):
        result = await _auto_organize_subscription_if_allowed(subscription_id, store)
        organized_count += int(result.get("organized_count", 0))
        error_count += int(result.get("error_count", 0))
    return {"organized_count": organized_count, "error_count": error_count}


async def _auto_organize_subscription_if_allowed(subscription_id: int, store: Store) -> dict[str, int]:
    subscription = _subscription_or_404(subscription_id, store)
    if not subscription.auto_organize:
        return {"attempted_count": 0, "organized_count": 0, "error_count": 0}
    policy = _organize_policy_for_subscription(subscription, store)
    if policy.post_organize_action == "manual":
        logger.info("skip auto organize for manual policy subscription_id=%s", subscription_id)
        return {"attempted_count": 0, "organized_count": 0, "error_count": 0}
    try:
        organize_response = await _organize_subscription_matches(
            subscription_id,
            SubscriptionOrganizeRequest(confirm=True),
            store,
            all_downloaded=True,
        )
        if organize_response.warnings:
            logger.warning(
                "auto organize completed with warnings subscription_id=%s warnings=%s",
                subscription_id,
                "；".join(organize_response.warnings[:3]),
            )
        return {
            "attempted_count": 1,
            "organized_count": organize_response.organized,
            "error_count": organize_response.failed,
        }
    except HTTPException as exc:
        logger.warning("auto organize failed subscription_id=%s: %s", subscription_id, exc.detail)
    except Exception as exc:
        logger.exception("auto organize failed subscription_id=%s: %s", subscription_id, exc)
    return {"attempted_count": 1, "organized_count": 0, "error_count": 1}


async def _auto_organize_completed_histories(histories: list[DownloadHistory], store: Store) -> dict[str, int]:
    subscription_ids = sorted(
        {
            int(item.subscription_id)
            for item in histories
            if item.subscription_id is not None
            and (
                (
                    item.organize_status not in {"已整理", "需要检查", "整理失败"}
                    and (
                        item.status in {"completed", "organized"}
                        or (
                            item.qbittorrent is not None
                            and item.qbittorrent.progress is not None
                            and item.qbittorrent.progress >= 0.999
                        )
                        or (
                            item.status == "queued"
                            and item.qbittorrent is not None
                            and item.qbittorrent.matched
                            and is_collection_parsed(
                                parse_title(item.torrent_name or item.title)
                            )
                        )
                    )
                )
                or (
                    item.status in {"deleted", "organized_task_removed", "seeding_stopped"}
                    and _exact_history_source_exists(item)
                )
            )
        }
    )
    result = {"attempted_count": 0, "organized_count": 0, "error_count": 0}
    for subscription_id in subscription_ids:
        item_result = await _auto_organize_subscription_if_allowed(subscription_id, store)
        result["attempted_count"] += int(item_result.get("attempted_count", 0))
        result["organized_count"] += int(item_result.get("organized_count", 0))
        result["error_count"] += int(item_result.get("error_count", 0))
    return result


async def background_sync_download_history(
    store: Store,
    task_snapshots: dict[str, list[dict[str, Any]]],
    downloader_clients: dict[str, Any],
    snapshot_errors: dict[str, Exception],
) -> dict[str, int]:
    if "qbittorrent" in task_snapshots:
        await reconcile_pending_confirmations(
            store,
            client=downloader_clients.get("qbittorrent"),
            torrents=task_snapshots["qbittorrent"],
            manage_session=False,
        )
    histories = await _download_history_models_with_progress(
        store.list_history(limit=100000),
        store,
        task_snapshots=task_snapshots,
        downloader_clients=downloader_clients,
        snapshot_errors=snapshot_errors,
    )
    # Auto-organize rebuilds subscription details from this cache. Publish the
    # fresh downloader state first so a newly completed task is eligible in
    # the same scheduler cycle.
    _cache_download_history_models(store, histories)
    auto_result = await _auto_organize_completed_histories(histories, store)
    if auto_result.get("attempted_count", 0):
        histories = await _download_history_models_with_progress(
            store.list_history(limit=100000),
            store,
            task_snapshots=task_snapshots,
            downloader_clients=downloader_clients,
            snapshot_errors=snapshot_errors,
        )
    _cache_download_history_models(store, histories)
    return {
        "updated_count": len(histories),
        "organized_count": int(auto_result.get("organized_count", 0)),
        "organize_error_count": int(auto_result.get("error_count", 0)),
    }


@router.get("/automation/status", response_model=AutomationStatus)
async def automation_status(request: Request) -> AutomationStatus:
    return await _automation_service(request).status()


@router.put("/automation/settings", response_model=AutomationStatus)
async def automation_settings(request_body: AutomationSettingsRequest, request: Request) -> AutomationStatus:
    logger.info(
        "automation settings updated auto_refresh_enabled=%s interval_seconds=%s auto_download_enabled=%s auto_organize_enabled=%s notifications_enabled=%s",
        request_body.auto_refresh_enabled,
        request_body.auto_refresh_interval_seconds,
        request_body.auto_download_enabled,
        request_body.auto_organize_enabled,
        request_body.notifications_enabled,
    )
    return await _automation_service(request).update_settings(request_body)


@router.put("/automation/interval", response_model=AutomationStatus)
async def automation_interval(request_body: AutomationIntervalRequest, request: Request) -> AutomationStatus:
    return await _automation_service(request).update_interval(request_body.interval_seconds)


@router.post("/automation/start", response_model=AutomationStatus)
async def automation_start(request_body: SchedulerStartRequest, request: Request) -> AutomationStatus:
    return await _automation_service(request).start(request_body.interval_seconds)


@router.post("/automation/stop", response_model=AutomationStatus)
async def automation_stop(request: Request) -> AutomationStatus:
    return await _automation_service(request).stop()


@router.post("/automation/run-now", response_model=AutomationRunNowResponse)
async def automation_run_now(request: Request) -> AutomationRunNowResponse:
    return await _automation_service(request).run_now()


@router.get("/automation/jobs/recent", response_model=list[AutomationJobRecord])
async def automation_recent_jobs(request: Request, limit: int = Query(default=20, ge=1, le=50)) -> list[AutomationJobRecord]:
    return await _automation_service(request).recent_jobs(limit)


@router.get("/scheduler/status", response_model=SchedulerStatus)
async def scheduler_status(request: Request) -> SchedulerStatus:
    return await _automation_service(request).scheduler_status()


@router.post("/scheduler/start", response_model=SchedulerStatus)
async def scheduler_start(request_body: SchedulerStartRequest, request: Request) -> SchedulerStatus:
    await _automation_service(request).start(request_body.interval_seconds)
    return await _automation_service(request).scheduler_status()


@router.post("/scheduler/stop", response_model=SchedulerStatus)
async def scheduler_stop(request: Request) -> SchedulerStatus:
    await _automation_service(request).stop()
    return await _automation_service(request).scheduler_status()


@router.get("/history", response_model=list[DownloadHistory])
async def history(
    request: Request,
    subscription_id: int | None = None,
    refresh: bool = False,
    store: Store = Depends(get_store),
) -> list[DownloadHistory]:
    if subscription_id is not None:
        _subscription_or_404(subscription_id, store)
    scheduler = getattr(request.app.state, "task_state", None)
    cache = store.get_config(DOWNLOAD_HISTORY_CACHE_KEY)
    if scheduler is not None and (refresh or not cache):
        await scheduler.run_now(trigger="manual_history" if refresh else "history_cache_warmup")
    elif refresh or not cache:
        await reconcile_pending_confirmations(store, subscription_id=subscription_id)
        await background_sync_download_history(store, {}, {}, {})
    return _cached_download_history_models(store, subscription_id=subscription_id)


@router.get("/task-state/status")
async def task_state_status(request: Request) -> dict[str, Any]:
    scheduler = getattr(request.app.state, "task_state", None)
    if scheduler is None:
        raise HTTPException(status_code=503, detail="任务状态后台同步尚未启动。")
    return await scheduler.status()


@router.post("/task-state/refresh")
async def task_state_refresh(request: Request) -> dict[str, Any]:
    scheduler = getattr(request.app.state, "task_state", None)
    if scheduler is None:
        raise HTTPException(status_code=503, detail="任务状态后台同步尚未启动。")
    await scheduler.run_now(trigger="manual")
    return await scheduler.status()


def _history_or_404(history_id: int, store: Store) -> dict:
    history_item = store.get_history(history_id)
    if history_item is None:
        raise HTTPException(status_code=404, detail="下载历史不存在")
    return history_item


def _history_downloader_client_or_400(store: Store, history_item: dict):
    downloader_type = str(history_item.get("downloader_type") or "qbittorrent")
    try:
        return _configured_downloader_client(store, downloader_type)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=describe_downloader_error(downloader_type, exc)) from exc


async def _delete_qbittorrent_tasks_for_history_rows(
    rows: list[dict],
    store: Store,
    *,
    delete_files: bool,
) -> tuple[int, list[str]]:
    candidates = [item for item in rows if item.get("status") not in {"dry_run", "deleted"}]
    if not candidates:
        return 0, []

    grouped: dict[str, list[dict]] = {}
    for item in candidates:
        grouped.setdefault(str(item.get("downloader_type") or "qbittorrent"), []).append(item)
    deleted_count = 0
    warnings: list[str] = []
    for downloader_type, items in grouped.items():
        client = _history_downloader_client_or_400(store, items[0])
        torrents = await client.list_torrents()
        task_ids: list[str] = []
        for item in items:
            torrent = _find_torrent_for_history(DownloadHistory(**item), torrents)
            if torrent is None:
                warnings.append(f"{downloader_display_name(downloader_type)} 中未找到对应任务：{item['title']}")
                continue
            task_id = str(torrent.get("remote_id") or _torrent_hash(torrent) or "")
            if not task_id:
                warnings.append(f"{downloader_display_name(downloader_type)} 任务缺少标识：{item['title']}")
                continue
            task_ids.append(task_id)
        unique_ids = sorted(set(task_ids))
        if unique_ids:
            await client.delete_torrents(unique_ids, delete_files=delete_files)
            deleted_count += len(unique_ids)
    return deleted_count, warnings


@router.delete("/history/{history_id}", response_model=DownloadHistoryDeleteResponse)
async def delete_download_history_record(
    history_id: int,
    store: Store = Depends(get_store),
) -> DownloadHistoryDeleteResponse:
    deleted = store.delete_history(history_id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="下载历史不存在")
    return DownloadHistoryDeleteResponse(
        ok=True,
        history_id=history_id,
        message="下载历史记录已删除",
    )


@router.post("/history/clear", response_model=HistoryClearResponse)
async def clear_history(
    request: HistoryClearRequest,
    store: Store = Depends(get_store),
) -> HistoryClearResponse:
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清空历史需要确认，当前未执行。")
    if request.scope == "all" and request.subscription_id is not None:
        raise HTTPException(status_code=400, detail="清空全部历史时不能限定订阅")
    if request.subscription_id is not None:
        _subscription_or_404(request.subscription_id, store)

    qbit_deleted = 0
    warnings: list[str] = []
    history_rows = store.list_history(subscription_id=request.subscription_id, limit=100000)
    if request.delete_qbittorrent_tasks or request.delete_files:
        try:
            qbit_deleted, warnings = await _delete_qbittorrent_tasks_for_history_rows(
                history_rows,
                store,
                delete_files=request.delete_files,
            )
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"qBittorrent 操作失败：{describe_qbittorrent_error(exc)}") from exc

    if request.scope == "download":
        deleted_count = store.clear_download_history(subscription_id=request.subscription_id)
        scope_label = "当前订阅下载历史" if request.subscription_id is not None else "全部下载历史"
        message = f"已清空{scope_label}，删除 {deleted_count} 条记录"
        if qbit_deleted:
            message += f"，同步删除 {qbit_deleted} 个下载器任务"
        return HistoryClearResponse(
            ok=True,
            scope=request.scope,
            message=message,
            download_history_deleted=deleted_count,
            qbittorrent_tasks_deleted=qbit_deleted,
            warnings=warnings,
        )

    counts = store.clear_all_history_state()
    total = sum(counts.values())
    message = f"已清空全部历史，删除 {total} 条状态记录"
    if qbit_deleted:
        message += f"，同步删除 {qbit_deleted} 个下载器任务"
    return HistoryClearResponse(
        ok=True,
        scope=request.scope,
        message=message,
        qbittorrent_tasks_deleted=qbit_deleted,
        warnings=warnings,
        **counts,
    )


async def _torrent_hash_for_history(client, store: Store, history_item: dict) -> str:
    history_model = DownloadHistory(**history_item)
    downloader_name = downloader_display_name(history_model.downloader_type)
    torrents = await client.list_torrents()
    match = _match_torrent_for_history(history_model, torrents)
    torrent = match.torrent if match.confidence >= TRUSTED_TASK_MATCH_CONFIDENCE else None
    logger.debug(
        "download history manage match downloader=%s history_id=%s reason=%s confidence=%.2f",
        history_model.downloader_type,
        history_model.id,
        match.reason,
        match.confidence,
    )
    if torrent is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "TASK_NOT_FOUND",
                "message": f"任务已不在 {downloader_name} 中，可删除本地记录或重新添加。",
            },
        )
    task_id = str(torrent.get("remote_id") or _torrent_hash(torrent) or "")
    if not task_id:
        raise HTTPException(
            status_code=404,
            detail=f"{downloader_name} 任务缺少标识，无法管理；可刷新任务状态、删除本地记录或重新添加。",
        )
    _remember_history_torrent(store, int(history_item["id"]), torrent)
    return task_id


def _torrent_for_identifier(torrents: list[dict], identifier: str) -> dict | None:
    normalized = identifier.casefold()
    matches = [
        torrent
        for torrent in torrents
        if str(torrent.get("remote_id") or "") == identifier
        or _torrent_hash(torrent) == normalized
    ]
    return matches[0] if len(matches) == 1 else None


async def _confirm_history_action(client, identifier: str, action: str) -> tuple[bool, str | None, bool]:
    last_state: str | None = None
    for attempt in range(3):
        torrent = _torrent_for_identifier(await client.list_torrents(), identifier)
        if torrent is None:
            return False, None, False
        last_state = str(torrent.get("state") or "") or None
        stopped = last_state in {"pausedDL", "pausedUP", "stoppedDL", "stoppedUP"}
        if (action == "pause" and stopped) or (action == "resume" and not stopped):
            return True, last_state, True
        if attempt < 2:
            await asyncio.sleep(1.5 * (attempt + 1))
    return False, last_state, True


@router.post("/history/{history_id}/manage", response_model=DownloadHistoryManageResponse)
async def manage_download_history(
    history_id: int,
    request: DownloadHistoryManageRequest,
    store: Store = Depends(get_store),
) -> DownloadHistoryManageResponse:
    history_item = _history_or_404(history_id, store)
    downloader_type = str(history_item.get("downloader_type") or "qbittorrent")
    downloader_name = downloader_display_name(downloader_type)
    client = _history_downloader_client_or_400(store, history_item)
    command_sent = False
    task_found = True
    before_state: str | None = None
    after_state: str | None = None
    needs_refresh = False

    try:
        if request.action == "readd":
            url = history_item.get("download_url")
            if not url:
                raise HTTPException(status_code=400, detail="下载历史没有可重新添加的链接")
            result = SearchResult(
                id=f"history-{history_id}",
                title=str(history_item.get("title") or history_item.get("torrent_name") or "重新添加任务"),
                source=str(history_item.get("source") or "manual"),
                download_url=url,
            )
            add_result = await submit_result_to_downloader(
                client,
                result,
                save_path=history_item.get("save_path"),
                site_settings=stored_site_settings(store),
            )
            store.update_history_qbittorrent_task(
                history_id,
                qbittorrent_hash=add_result.torrent_hash,
                downloader_type=downloader_type,
                remote_task_id=add_result.remote_task_id,
                torrent_name=add_result.torrent_name,
                save_path=history_item.get("save_path"),
            )
            await _remember_submitted_torrent(
                client,
                store,
                history_id,
                add_result=add_result,
                downloader_type=downloader_type,
            )
            status = "queued"
            message = f"已重新添加到 {downloader_name}"
            command_sent = True
        else:
            hash_value = await _torrent_hash_for_history(client, store, history_item)
            before_torrent = _torrent_for_identifier(await client.list_torrents(), hash_value)
            before_state = str(before_torrent.get("state") or "") or None if before_torrent else None
            if request.action == "pause":
                await client.pause_torrents([hash_value])
                command_sent = True
                confirmed, after_state, task_found = await _confirm_history_action(client, hash_value, request.action)
                if confirmed:
                    status = "paused"
                    message = f"已暂停 {downloader_name} 任务"
                else:
                    status = str(history_item.get("status") or "queued")
                    needs_refresh = True
                    message = f"暂停命令已发送，但 {downloader_name} 状态尚未变化"
            elif request.action == "resume":
                await client.resume_torrents([hash_value])
                command_sent = True
                confirmed, after_state, task_found = await _confirm_history_action(client, hash_value, request.action)
                if confirmed:
                    status = "queued"
                    message = f"已恢复 {downloader_name} 任务"
                else:
                    status = str(history_item.get("status") or "paused")
                    needs_refresh = True
                    message = f"恢复命令已发送，但 {downloader_name} 状态尚未变化"
            elif request.action == "delete":
                await client.delete_torrents([hash_value], delete_files=False)
                command_sent = True
                status = "deleted"
                message = f"已从 {downloader_name} 删除任务，未删除文件"
            elif request.action == "delete_files":
                await client.delete_torrents([hash_value], delete_files=True)
                command_sent = True
                status = "deleted"
                message = f"已从 {downloader_name} 删除任务和文件"
            else:
                raise HTTPException(status_code=400, detail="不支持的下载管理操作")
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception(
            "download history manage failed downloader=%s history_id=%s action=%s",
            downloader_type,
            history_id,
            request.action,
        )
        raise HTTPException(status_code=502, detail=f"{downloader_name} 操作失败：{describe_downloader_error(downloader_type, exc)}")

    if not needs_refresh:
        store.update_history_status(history_id, status)
    return DownloadHistoryManageResponse(
        ok=True,
        history_id=history_id,
        action=request.action,
        status=status,
        message=message,
        command_sent=command_sent,
        task_found=task_found,
        before_state=before_state,
        after_state=after_state,
        needs_refresh=needs_refresh,
    )


@router.post("/metadata/search", response_model=MetadataSearchResponse)
async def metadata_search(request: MetadataSearchRequest, store: Store = Depends(get_store)) -> MetadataSearchResponse:
    sync_runtime_settings(store)
    return await search_metadata(request)


@router.post("/metadata/match", response_model=MetadataSearchResponse)
async def metadata_match(request: MetadataMatchRequest, store: Store = Depends(get_store)) -> MetadataSearchResponse:
    sync_runtime_settings(store)
    match_title = request.title
    if request.download_record_id is not None:
        history_item = store.get_history(request.download_record_id)
        if history_item is None:
            raise HTTPException(status_code=404, detail="下载记录不存在")
        history = DownloadHistory(**history_item)
        context_titles = [request.title, history.torrent_name or ""]
        source_context_loaded = False
        try:
            source_path, _diagnostics = await _source_path_from_download_history_with_downloader(
                history,
                store,
                prefer_directory=True,
            )
            source = Path(source_path).expanduser()
            context_titles.extend([source.name, source.parent.name])
            if source.is_dir():
                context_titles.extend(item.name for item in _batch_video_files(str(source))[:12])
            elif source.is_file():
                context_titles.append(source.name)
            source_context_loaded = True
        except Exception as exc:
            logger.info(
                "manual organize metadata context unavailable history_id=%s error=%s",
                history.id,
                type(exc).__name__,
            )
        unique_titles = list(
            dict.fromkeys(value.strip() for value in context_titles if value and value.strip())
        )

        def title_score(value: str) -> tuple[int, int, int, int]:
            parsed = parse_title(value)
            parsed_name = (parsed.title or "").strip()
            return (
                int(bool(parsed_name)),
                int(parsed.explicit_season_number is not None),
                int(is_collection_parsed(parsed)),
                min(len(parsed_name), 200),
            )

        if unique_titles:
            match_title = max(unique_titles, key=title_score)
        logger.info(
            "manual organize metadata context history_id=%s titles=%s source_context=%s",
            history.id,
            len(unique_titles),
            source_context_loaded,
        )
    return await match_metadata_title(match_title, request.year, media_type=request.media_type)


def _metadata_binding_records(rows: list[dict]) -> list[MetadataBindingRecord]:
    return [MetadataBindingRecord(**item) for item in rows]


async def _notify_and_refresh_subscription_after_metadata_bind(store: Store, subscription_id: int, selected_title: str | None) -> None:
    data = store.get_subscription(subscription_id)
    if data is None:
        return
    subscription = Subscription(**data)
    await NotificationService(store).send_best_effort(
        subscription_metadata_bound_event(store, subscription, selected_title)
    )
    try:
        await run_subscription_refresh(
            store,
            subscription,
            qbittorrent_config=stored_qbittorrent_config(store),
            notify_total_episodes=False,
        )
    except Exception as exc:
        message = describe_site_error(exc)
        logger.warning("metadata bind auto refresh failed subscription=%s: %s", subscription_id, message)
        await NotificationService(store).send_best_effort(
            subscription_refresh_failed_event(store, subscription, message)
        )


def _validate_metadata_target_type(target_type: str) -> None:
    if target_type not in {"subscription", "resource"}:
        raise HTTPException(status_code=400, detail="target_type 必须是 subscription 或 resource")


@router.get("/metadata/bindings", response_model=list[MetadataBindingRecord])
async def metadata_bindings(
    target_type: str | None = None,
    target_id: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    store: Store = Depends(get_store),
) -> list[MetadataBindingRecord]:
    if (target_type is None) != (target_id is None):
        raise HTTPException(status_code=400, detail="target_type 和 target_id 需要同时提供")
    if target_type is not None and target_id is not None:
        _validate_metadata_target_type(target_type)
        return _metadata_binding_records(store.list_metadata_bindings_for_target(target_type, target_id, limit))
    return _metadata_binding_records(store.list_metadata_bindings(limit))


@router.get("/metadata/bindings/{target_type}/{target_id:path}", response_model=list[MetadataBindingRecord])
async def metadata_bindings_for_target(
    target_type: str,
    target_id: str,
    limit: int = Query(default=100, ge=1, le=500),
    store: Store = Depends(get_store),
) -> list[MetadataBindingRecord]:
    _validate_metadata_target_type(target_type)
    return _metadata_binding_records(store.list_metadata_bindings_for_target(target_type, target_id, limit))


@router.post("/metadata/bind", response_model=MetadataBindResponse)
async def metadata_bind(request: MetadataBindRequest, store: Store = Depends(get_store)) -> MetadataBindResponse:
    payload = request.model_dump(mode="json")
    subscription_id_for_post_bind: int | None = None
    if request.target_type == "subscription":
        try:
            subscription_id = int(request.target_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="订阅元数据目标 ID 无效。") from exc
        source_ids = [value for value in (request.bangumi_id, request.tmdb_id) if value]
        if len(source_ids) != 1:
            raise HTTPException(status_code=400, detail="订阅元数据必须且只能选择一个来源。")

        source = "bangumi" if request.bangumi_id else "tmdb"
        current_rows = store.list_metadata_bindings_for_target("subscription", str(subscription_id), limit=1)
        current = current_rows[0] if current_rows else None
        same_cached_poster = bool(
            current
            and current.get("poster_url") == request.poster_url
            and current.get("bangumi_id") == request.bangumi_id
            and current.get("tmdb_id") == request.tmdb_id
            and current.get("local_poster_path")
            and Path(current["local_poster_path"]).exists()
        )
        if same_cached_poster and current is not None:
            for key in ("poster_local_url", "local_poster_path", "poster_cached_at", "poster_palette"):
                payload[key] = current.get(key)
        else:
            cached = await _cache_subscription_poster(
                subscription_id,
                request.poster_url,
                metadata_source=source,
                metadata_id=request.bangumi_id or request.tmdb_id,
            )
            if cached:
                payload.update(cached)

        staged_path = payload.get("local_poster_path") if not same_cached_poster else None
        metadata_episode_count = request.total_episodes if request.total_episodes and request.total_episodes > 0 else None
        if metadata_episode_count is None and source == "bangumi" and request.bangumi_id:
            with suppress(Exception):
                subject = await fetch_bangumi_subject_with_episodes(request.bangumi_id)
                metadata_episode_count = total_episodes_from_subject(subject)
                if metadata_episode_count is not None:
                    payload["total_episodes"] = metadata_episode_count
        try:
            binding_id = store.bind_subscription_metadata(
                subscription_id,
                payload,
                metadata_source=source,
                metadata_episode_count=metadata_episode_count,
            )
        except Exception:
            _discard_staged_subscription_poster(subscription_id, staged_path)
            raise
        if binding_id is None:
            _discard_staged_subscription_poster(subscription_id, staged_path)
            raise HTTPException(status_code=404, detail="订阅不存在。")
        _finalize_subscription_poster_cache(subscription_id, payload.get("local_poster_path"))
        subscription_id_for_post_bind = subscription_id
    else:
        binding_id = store.add_metadata_binding(payload)
    if subscription_id_for_post_bind is not None:
        await _notify_and_refresh_subscription_after_metadata_bind(
            store,
            subscription_id_for_post_bind,
            request.selected_title,
        )
    return MetadataBindResponse(ok=True, binding_id=binding_id)


@router.post("/title/parse")
async def title_parse(request: TitleParseRequest, store: Store = Depends(get_store)):
    rules = request.episode_parse_rules or stored_global_episode_rules(store)
    return parse_title(request.title, rules)


@router.post("/subscriptions/{subscription_id}/episode-rules/test", response_model=EpisodeRuleTestResponse)
async def test_subscription_episode_rules(
    subscription_id: int,
    request: EpisodeRuleTestRequest,
    store: Store = Depends(get_store),
) -> EpisodeRuleTestResponse:
    subscription = _subscription_or_404(subscription_id, store)
    rules = request.episode_parse_rules or _effective_episode_rules(subscription, store)
    parsed = parse_title(request.title, rules)
    ok, message, _ = episode_rule_preview_message(parsed, [])
    return EpisodeRuleTestResponse(ok=ok, parsed_title=parsed, message=message)


@router.put("/subscriptions/{subscription_id}/episode-rules", response_model=Subscription)
async def update_subscription_episode_rules(
    subscription_id: int,
    request: EpisodeRulesUpdateRequest,
    store: Store = Depends(get_store),
) -> Subscription:
    data = store.get_subscription(subscription_id)
    if data is None:
        raise HTTPException(status_code=404, detail="订阅不存在。")
    try:
        rules = [normalize_episode_rule(rule, index) for index, rule in enumerate(sorted(request.episode_parse_rules, key=lambda item: item.priority))]
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    data["episode_parse_rules"] = [rule.model_dump(mode="json") for rule in rules]
    updated = store.update_subscription(subscription_id, SubscriptionCreate(**data).model_dump(mode="json"))
    if updated is None:
        raise HTTPException(status_code=404, detail="订阅不存在。")
    return Subscription(**updated)


@router.post("/plex/mapping", response_model=PlexMappingResponse)
async def save_plex_mapping(request: PlexSeasonMapping, store: Store = Depends(get_store)) -> PlexMappingResponse:
    mapping_id = store.upsert_plex_mapping(request.model_dump(mode="json"))
    return PlexMappingResponse(ok=True, mapping_id=mapping_id)


@router.get("/plex/mappings", response_model=list[PlexMappingRecord])
async def plex_mappings(store: Store = Depends(get_store)) -> list[PlexMappingRecord]:
    return [PlexMappingRecord(**item) for item in store.list_plex_mappings()]


@router.get("/plex/mapping/{subject_key:path}", response_model=PlexMappingRecord)
async def plex_mapping(subject_key: str, store: Store = Depends(get_store)) -> PlexMappingRecord:
    item = store.get_plex_mapping(subject_key)
    if item is None:
        raise HTTPException(status_code=404, detail="Plex 映射不存在")
    return PlexMappingRecord(**item)


@router.get("/organize/previews", response_model=list[OrganizePreviewRecord])
async def organize_previews(store: Store = Depends(get_store)) -> list[OrganizePreviewRecord]:
    from app.overview import cached_history
    from app.pending_organize import pending_previews
    records = [OrganizePreviewRecord(**item) for item in store.list_organize_previews(limit=-1)]
    history = cached_history(store)
    results = [OrganizeHistoryRecord(**item) for item in store.list_organize_history(limit=-1)]
    for record in records:
        matches = pending_previews([record], history, results)
        record.remaining_source_paths = list(matches[0].remaining_sources) if matches else []
    return records


@router.get("/organize/history", response_model=list[OrganizeHistoryRecord])
async def organize_history(
    subscription_id: int | None = Query(default=None),
    status: str | None = Query(default=None),
    search: str | None = Query(default=None),
    store: Store = Depends(get_store),
) -> list[OrganizeHistoryRecord]:
    records = [OrganizeHistoryRecord(**item) for item in store.list_organize_history(limit=500)]
    if subscription_id is not None:
        subscription = _subscription_or_404(subscription_id, store)
        titles = {subscription.name, subscription.keyword}
        for match in _subscription_match_models(store.list_subscription_matches(subscription_id, limit=1000)):
            titles.add(match.result.title)
            if match.parsed_title.title:
                titles.add(match.parsed_title.title)
        needles = {title.casefold() for title in titles if title}
        records = [
            record
            for record in records
            if record.subscription_id == subscription_id
            or (
                record.subscription_id is None
                and any(
                    needle in "\n".join(
                        [
                            record.source_path,
                            record.destination_path,
                            record.preview.filename,
                            record.preview.show_directory,
                        ]
                    ).casefold()
                    for needle in needles
                )
            )
        ]
    if status and status != "all":
        records = [record for record in records if record.status == status]
    if search:
        needle = search.strip().casefold()
        if needle:
            records = [
                record
                for record in records
                if needle in record.preview.filename.casefold()
                or needle in record.preview.show_directory.casefold()
                or needle in record.source_path.casefold()
                or needle in record.destination_path.casefold()
            ]
    return records


@router.get("/organize/history/failed/summary", response_model=OrganizeFailedHistorySummary)
async def failed_organize_history_summary(
    subscription_id: int | None = Query(default=None),
    store: Store = Depends(get_store),
) -> OrganizeFailedHistorySummary:
    if subscription_id is not None:
        _subscription_or_404(subscription_id, store)
    return OrganizeFailedHistorySummary(
        subscription_id=subscription_id,
        failed_count=store.count_failed_organize_history(subscription_id),
    )


@router.post("/organize/history/failed/delete", response_model=OrganizeFailedHistoryDeleteResponse)
async def delete_failed_organize_history(
    request: OrganizeFailedHistoryDeleteRequest,
    store: Store = Depends(get_store),
) -> OrganizeFailedHistoryDeleteResponse:
    if not request.confirm:
        raise HTTPException(status_code=403, detail="删除失败整理记录需要确认，当前未执行。")
    subscription = None
    if request.subscription_id is not None:
        subscription = _subscription_or_404(request.subscription_id, store)
    deleted_count = store.delete_failed_organize_history(request.subscription_id)
    scope = "all" if subscription is None else f"subscription:{subscription.id}"
    message = (
        f"已删除全部订阅的 {deleted_count} 条失败记录"
        if subscription is None
        else f"已删除《{subscription.name}》的 {deleted_count} 条失败记录"
    )
    return OrganizeFailedHistoryDeleteResponse(
        deleted_count=deleted_count,
        scope=scope,
        message=message,
    )


@router.post("/organize/history/clear", response_model=HistoryClearResponse)
async def clear_organize_history(
    request: OrganizeHistoryClearRequest,
    store: Store = Depends(get_store),
) -> HistoryClearResponse:
    if not request.confirm:
        raise HTTPException(status_code=403, detail="清空整理历史需要确认，当前未执行。")
    counts = store.clear_organize_history()
    total = counts["organize_previews_deleted"] + counts["organize_history_deleted"]
    return HistoryClearResponse(
        ok=True,
        scope="organize",
        message=f"已清空整理历史，删除 {total} 条记录",
        **counts,
    )


@router.post("/organize/preview", response_model=OrganizePreviewItem)
async def organize_preview(request: OrganizePreviewRequest, store: Store = Depends(get_store)) -> OrganizePreviewItem:
    history: DownloadHistory | None = None
    source_resolution: OrganizeSourceResolution | None = None
    if request.download_record_id is not None:
        history_item = store.get_history(request.download_record_id)
        if history_item is None:
            raise HTTPException(status_code=404, detail="下载记录不存在，无法生成整理预览。")
        history = DownloadHistory(**history_item)
        if history.source == "manual" and request.organize_target_id is None:
            raise HTTPException(status_code=400, detail="手动下载任务必须选择已配置的整理目标。")
        prefer_directory = request.select_files or request.media_type == "movie" or bool(
            request.parsed_title
            and is_collection_parsed(request.parsed_title)
        )
        try:
            if request.select_files or request.media_type == "movie":
                source_resolution = await _manual_download_source(history, store, prefer_directory=prefer_directory)
                source_path, path_diagnostics = source_resolution.source_path, list(source_resolution.diagnostics)
            else:
                source_path, path_diagnostics = await _source_path_from_download_history_with_downloader(
                    history,
                    store,
                    prefer_directory=prefer_directory,
                    expected_episode=request.parsed_title.episode if request.parsed_title else None,
                    context_season_number=request.parsed_title.effective_season_number if request.parsed_title else None,
                )
        except OrganizeSourceResolutionError as exc:
            logger.info("organize preview path diagnostics: %s", " | ".join(exc.diagnostics))
            raise HTTPException(status_code=400, detail=exc.message) from exc
        source_candidate = Path(source_path).expanduser()
        logger.info("organize preview path diagnostics: %s", " | ".join(path_diagnostics))
        if not source_candidate.exists():
            raise HTTPException(
                status_code=400,
                detail=f"下载路径不存在：{source_candidate}。请检查原下载器任务文件列表、保存路径或本地下载记录。",
            )
        if prefer_directory and not request.select_files and request.media_type != "movie" and not source_candidate.is_dir():
            raise HTTPException(
                status_code=400,
                detail=f"合集资源需要目录，但当前路径不是目录：{source_candidate}。",
            )
        request_updates: dict[str, Any] = {"source_path": source_path}
        if source_candidate.is_file():
            # The downloader's resolved file is authoritative for the media extension.
            # History torrent names often identify a parent directory and may end in a
            # release-group token that Path.suffix would otherwise treat as an extension.
            request_updates["original_filename"] = source_candidate.name
        elif not request.original_filename:
            request_updates["original_filename"] = source_candidate.name or history.torrent_name or history.title
        request = request.model_copy(update=request_updates)
    if request.organize_target_id is not None:
        target = _enabled_organize_target_or_400(request.organize_target_id, store)
        if target is not None:
            request = request.model_copy(update={"library_root": target.path})
    if not request.source_path:
        raise HTTPException(status_code=400, detail="请提供源文件或下载记录。")
    if not request.original_filename:
        request = request.model_copy(update={"original_filename": Path(request.source_path).name or "未命名资源"})
    if request.media_type == "movie" and Path(request.source_path).is_file():
        source_file = Path(request.source_path)
        if source_file.is_symlink() or _is_ignored_torrent_media_path(source_file):
            raise HTTPException(status_code=400, detail="电影源文件不是可整理的正片。")
        request = request.model_copy(update={"original_filename": source_file.name})
    preview = build_preview(request)
    preview = preview.model_copy(
        update={
            "download_record_id": request.download_record_id,
            "organize_target_id": request.organize_target_id,
        }
    )
    source = Path(request.source_path).expanduser()
    parsed = request.parsed_title or ParsedAnimeTitle(original_title=request.original_filename)
    is_batch_resource = bool(is_collection_parsed(parsed) or (source.exists() and source.is_dir()))
    allowed_files = (
        sorted((Path(path) for path in source_resolution.completed_video_paths), key=lambda path: str(path).casefold())
        if source_resolution is not None and source_resolution.task_files_authoritative else None
    )
    if request.media_type == "movie" and source.is_dir():
        mappings = _movie_file_mappings(request, allowed_files=allowed_files)
        preview = preview.model_copy(update={
            "is_batch": True,
            "batch_mode": "multi_file",
            "file_mappings": mappings,
        })
    elif request.media_type != "movie" and is_batch_resource:
        if source.exists() and source.is_dir():
            batch_files = allowed_files if allowed_files is not None else _batch_video_files(str(source))
            single_file_episode_range = bool(
                parsed.resource_type == "episode_range"
                or (
                    parsed.episode_start is not None
                    and parsed.episode_end is not None
                    and parsed.episode_end > parsed.episode_start
                )
            )
            if len(batch_files) == 1 and single_file_episode_range:
                single_source = batch_files[0]
                request = request.model_copy(
                    update={
                        "source_path": str(single_source),
                        "original_filename": single_source.name,
                    }
                )
                source = single_source
                preview = build_preview(request).model_copy(
                    update={
                        "download_record_id": request.download_record_id,
                        "organize_target_id": request.organize_target_id,
                    }
                )
                warnings = [
                    *preview.warnings,
                    "任务中只有一个视频文件，无法自动拆分为单集。",
                    "可选择按合集文件整理、标记为集数范围，或放入 Specials / Batch。",
                ]
                preview = _single_file_batch_preview(
                    preview,
                    parsed=parsed,
                    mapping=request.mapping,
                    mode=request.single_file_mode or "as_batch_file",
                ).model_copy(update={"warnings": warnings})
            else:
                mappings = [
                    _batch_file_mapping(
                        file_path=file_path,
                        library_root=preview.library_root,
                        mapping=request.mapping,
                        fallback_season=parsed.effective_season_number or parsed.season_number or parsed.season,
                    )
                    for file_path in batch_files
                ]
                mappings = _apply_file_mapping_overrides(mappings, request)
                warnings = list(preview.warnings)
                if not mappings:
                    raise HTTPException(status_code=400, detail=f"合集目录中未找到可整理的视频文件：{source}")
                preview = preview.model_copy(
                    update={
                        "is_batch": True,
                        "batch_mode": "multi_file",
                        "file_mappings": mappings,
                        "warnings": warnings,
                    }
                )
        else:
            warnings = [
                *preview.warnings,
                "这是单个合集文件，无法自动拆分为单集。",
                "可选择按合集文件整理、标记为 SxxE01-E12，或放入 Specials / Batch。",
            ]
            preview = _single_file_batch_preview(
                preview,
                parsed=parsed,
                mapping=request.mapping,
                mode=request.single_file_mode or "as_batch_file",
            ).model_copy(update={"warnings": warnings})
    availability = organize_preview_availability(preview)
    has_mapping_errors = any(item.status == "error" for item in preview.file_mappings)
    needs_confirmation = any(
        item.status == "needs_confirmation" and item.episode_number is None
        for item in preview.file_mappings
    )
    block_reason = None
    if request.select_files and request.media_type != "movie" and not preview.file_mappings and parsed.episode is None and parsed.episode_start is None:
        block_reason = "未确认源文件集数，请填写集数后重新生成预览。"
    elif request.media_type == "movie" and preview.file_mappings and not any(
        row.status != "skipped" for row in preview.file_mappings
    ):
        block_reason = "请选择一个电影正片文件。"
    elif has_mapping_errors:
        block_reason = "存在目标冲突或无效文件映射，请处理后重新生成预览。"
    elif needs_confirmation:
        block_reason = "电影有多个视频文件，请只选择一个正片版本。" if request.media_type == "movie" else "仍有文件需要确认集数。"
    elif availability.destination_exists:
        block_reason = "整理目标文件已存在，不能覆盖。"
    elif not availability.source_exists:
        block_reason = availability.reason
    preview = preview.model_copy(
        update={
            "can_apply": bool(
                availability.pending
                and availability.source_exists
                and not availability.destination_exists
                and not has_mapping_errors
                and not needs_confirmation
                and block_reason is None
            ),
            "block_reason": block_reason,
        }
    )
    request_payload = request.model_dump(mode="json")
    if request.select_files or request.media_type == "movie":
        sources = [row.source_path for row in preview.file_mappings if row.status != "skipped"] or [preview.source_path]
        request_payload["_source_identities"] = {path: _file_identity(path) for path in sources}
    record = store.add_organize_preview(
        request_payload,
        preview.model_dump(mode="json"),
    )
    return OrganizePreviewRecord(**record).preview


async def _manual_download_source(
    history: DownloadHistory, store: Store, *, prefer_directory: bool
) -> OrganizeSourceResolution:
    resolution = await _resolve_download_history_source(history, store, prefer_directory=prefer_directory)
    if resolution.task_complete is not True or resolution.incomplete_video_files:
        raise OrganizeSourceResolutionError(
            "下载器尚未确认任务完整下载，请完成下载后重试。",
            list(resolution.diagnostics), retryable=True, reason_code="manual_task_not_complete",
        )
    if Path(resolution.source_path).is_dir() and not resolution.task_files_authoritative:
        raise OrganizeSourceResolutionError(
            "下载器文件列表不可用，无法安全选择整理文件。",
            list(resolution.diagnostics), retryable=True, reason_code="manual_files_unavailable",
        )
    return resolution


def _movie_file_mappings(
    request: OrganizePreviewRequest, *, allowed_files: list[Path] | None = None
) -> list[OrganizePreviewFileMapping]:
    root = Path(request.source_path).expanduser()
    if root.is_symlink():
        raise HTTPException(status_code=400, detail="电影源目录不能是符号链接。")
    files = []
    for path in allowed_files if allowed_files is not None else _batch_video_files(str(root)):
        if _is_ignored_torrent_media_path(path) or path.suffix.casefold() not in VIDEO_EXTENSIONS:
            continue
        if path.is_symlink() or path.stat().st_size <= 0:
            continue
        try:
            path.resolve(strict=True).relative_to(root.resolve(strict=True))
        except (OSError, ValueError):
            continue
        files.append(path)
    if not files:
        raise HTTPException(status_code=400, detail="目录中没有可整理的电影正片文件。")
    overrides = {row.id: row for row in request.file_mapping_overrides}
    if set(overrides) - {str(path) for path in files}:
        raise HTTPException(status_code=409, detail="电影文件列表已经变化，请重新生成预览。")
    selected_count = sum(not (overrides.get(str(path)) and overrides[str(path)].skipped) for path in files)
    rows = []
    for path in files:
        file_preview = build_preview(request.model_copy(update={
            "source_path": str(path), "original_filename": path.name,
        }))
        override = overrides.get(str(path))
        skipped = override is not None and override.skipped
        status = "skipped" if skipped else "ready"
        message = "已跳过" if skipped else "可整理"
        if not skipped and selected_count != 1:
            status, message = "needs_confirmation", "请选择一个电影正片版本"
        elif not skipped and _organize_target_conflicts(path, Path(file_preview.destination_preview)):
            status, message = "error", "目标文件已存在，未覆盖"
        rows.append(OrganizePreviewFileMapping(
            id=str(path), source_path=str(path), original_filename=path.name,
            season_number=0, episode_number=None,
            target_filename=file_preview.filename, target_path=file_preview.destination_preview,
            status=status, message=message,
            manual_override=override is not None,
            override_reason="用户选择电影正片文件" if override is not None else None,
            subtitle_mappings=file_preview.subtitle_mappings,
        ))
    return rows


def _resolved_path(path: str | Path, *, strict: bool) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise HTTPException(status_code=409, detail="整理路径不是绝对路径，请重新生成预览。")
    try:
        return candidate.resolve(strict=strict)
    except (OSError, RuntimeError) as exc:
        raise HTTPException(status_code=409, detail="整理路径已失效，请重新生成预览。") from exc


async def _validate_download_record_apply_paths(
    preview: OrganizePreviewItem,
    store: Store,
) -> None:
    if preview.download_record_id is None:
        return
    if preview.preview_id is None:
        raise HTTPException(status_code=409, detail="整理预览缺少后端校验记录，请重新生成预览。")
    persisted_record = store.get_organize_preview(preview.preview_id)
    if persisted_record is None:
        raise HTTPException(status_code=409, detail="整理预览已失效，请重新生成预览。")
    persisted_preview = OrganizePreviewItem(**persisted_record["preview"])
    history_item = store.get_history(preview.download_record_id)
    if history_item is None:
        raise HTTPException(status_code=404, detail="下载记录不存在，无法确认整理源文件。")
    if preview.organize_target_id is not None:
        target_item = store.get_organize_target(preview.organize_target_id)
        if target_item is None or not bool(target_item.get("enabled")):
            raise HTTPException(status_code=409, detail="整理目标已不存在或已停用，请重新选择。")
        configured_root = _resolved_path(str(target_item["path"]), strict=False)
        preview_root = _resolved_path(preview.library_root, strict=False)
        if configured_root != preview_root:
            raise HTTPException(status_code=409, detail="整理目标路径与当前配置不一致，请重新生成预览。")

    history = DownloadHistory(**history_item)
    if _preview_has_persisted_success(store, preview, subscription_id=history.subscription_id):
        return
    prefer_directory = bool(preview.file_mappings or preview.batch_mode == "multi_file")
    manual_selection = preview.media_type == "movie" or persisted_record["request"].get("select_files", False)
    resolution: OrganizeSourceResolution | None = None
    try:
        if manual_selection:
            resolution = await _manual_download_source(history, store, prefer_directory=prefer_directory)
            source_path, diagnostics = resolution.source_path, list(resolution.diagnostics)
        else:
            source_path, diagnostics = await _source_path_from_download_history_with_downloader(
                history, store, prefer_directory=prefer_directory,
            )
    except OrganizeSourceResolutionError as exc:
        logger.info("organize apply path diagnostics: %s", " | ".join(exc.diagnostics))
        raise HTTPException(status_code=409, detail=f"{exc.message}，请重新生成预览。") from exc
    logger.info("organize apply path diagnostics: %s", " | ".join(diagnostics))
    authoritative_candidate = Path(source_path).expanduser()
    preview_candidate = Path(preview.source_path).expanduser()
    if authoritative_candidate.is_symlink() or preview_candidate.is_symlink():
        raise HTTPException(status_code=409, detail="整理源路径是符号链接，未执行整理。")
    authoritative_source = _resolved_path(authoritative_candidate, strict=True)
    preview_source = _resolved_path(preview_candidate, strict=True)
    if preview_source != authoritative_source:
        raise HTTPException(status_code=409, detail="整理源路径与下载器任务不一致，请重新生成预览。")

    if not preview.file_mappings:
        if not authoritative_source.is_file():
            raise HTTPException(status_code=409, detail="整理源文件类型不安全，请重新生成预览。")
        if Path(preview.filename).suffix.casefold() != authoritative_source.suffix.casefold():
            raise HTTPException(status_code=409, detail="整理预览的媒体扩展名与源文件不一致，请重新生成预览。")
        if persisted_preview.model_dump(mode="json") != preview.model_dump(mode="json"):
            raise HTTPException(status_code=409, detail="整理预览已被修改，请重新生成预览并完成后端校验。")
        return
    if not authoritative_source.is_dir():
        raise HTTPException(status_code=409, detail="合集整理源路径不是任务目录，请重新生成预览。")

    for row in preview.file_mappings:
        if row.status == "skipped":
            continue
        if _existing_successful_apply_result(store, _file_preview_from_mapping(preview, row), subscription_id=history.subscription_id):
            continue
        source = Path(row.source_path).expanduser()
        if source.is_symlink():
            raise HTTPException(status_code=409, detail="整理文件包含符号链接，未执行整理。")
        resolved = _resolved_path(source, strict=True)
        if resolution is not None and resolution.task_files_authoritative and str(resolved) not in resolution.completed_video_paths:
            raise HTTPException(status_code=409, detail="整理文件不在下载器已完成文件列表中，未执行整理。")
        try:
            resolved.relative_to(authoritative_source)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail="整理文件不属于当前下载器任务，未执行整理。") from exc
        if not resolved.is_file() or resolved.suffix.casefold() not in VIDEO_EXTENSIONS:
            raise HTTPException(status_code=409, detail="整理文件不是受支持的视频文件，未执行整理。")
        if Path(row.target_path).suffix.casefold() != resolved.suffix.casefold():
            raise HTTPException(status_code=409, detail="合集文件的目标扩展名与源文件不一致，请重新生成预览。")
    if persisted_preview.model_dump(mode="json") != preview.model_dump(mode="json"):
        raise HTTPException(status_code=409, detail="整理预览已被修改，请重新生成预览并完成后端校验。")


def _file_preview_from_mapping(
    preview: OrganizePreviewItem,
    row: OrganizePreviewFileMapping,
) -> OrganizePreviewItem:
    file_preview = OrganizePreviewItem(
        media_type=preview.media_type,
        source_path=row.source_path,
        library_root=preview.library_root,
        organize_target_id=preview.organize_target_id,
        download_record_id=preview.download_record_id,
        preview_id=preview.preview_id,
        show_directory=preview.show_directory,
        season_directory="" if preview.media_type == "movie" else f"Season {row.season_number:02d}",
        filename=row.target_filename,
        destination_preview=row.target_path,
        will_move=preview.will_move,
        warnings=row.warnings,
        is_batch=False,
        batch_mode="none",
    )
    return file_preview.model_copy(
        update={"subtitle_mappings": subtitle_mappings_for_preview(file_preview)}
    )


def _preflight_batch_apply(
    preview: OrganizePreviewItem,
    *,
    store: Store | None = None,
    subscription_id: int | None = None,
) -> None:
    if preview.media_type == "movie" and sum(row.status != "skipped" for row in preview.file_mappings) != 1:
        raise HTTPException(status_code=409, detail="电影整理必须且只能选择一个正片文件。")
    if not any(row.status != "skipped" for row in preview.file_mappings):
        raise HTTPException(status_code=409, detail="请选择至少一个可整理的视频文件。")
    destinations: dict[Path, str] = {}
    subtitle_destinations: dict[Path, str] = {}
    for row in preview.file_mappings:
        if row.status == "skipped":
            continue
        if row.status in {"error", "needs_confirmation"} or (preview.media_type != "movie" and row.episode_number is None):
            raise HTTPException(status_code=409, detail="整理预览仍有冲突或未确认集数，未执行整理。")
        file_preview = _file_preview_from_mapping(preview, row)
        destination = destination_path_for_preview(file_preview).resolve(strict=False)
        if destination in destinations:
            raise HTTPException(status_code=409, detail="多个源文件映射到同一目标文件，未执行整理。")
        destinations[destination] = row.source_path
        if store is not None and _existing_successful_apply_result(
            store,
            file_preview,
            subscription_id=subscription_id,
        ) is not None:
            continue
        source = _resolved_path(row.source_path, strict=True)
        if not source.is_file() or source.stat().st_size <= 0 or source.suffix.casefold() not in VIDEO_EXTENSIONS:
            raise HTTPException(status_code=409, detail="源文件不可用，请重新生成预览。")
        if destination.exists():
            try:
                same_file = source.samefile(destination)
            except OSError:
                same_file = False
            if not same_file:
                raise HTTPException(status_code=409, detail="整理目标文件已存在，未覆盖，也未执行任何文件整理。")
        for subtitle in file_preview.subtitle_mappings:
            subtitle_destination = _resolved_path(subtitle.target_path, strict=False)
            if subtitle_destination in subtitle_destinations:
                raise HTTPException(status_code=409, detail="多个字幕映射到同一目标文件，未执行整理。")
            subtitle_destinations[subtitle_destination] = subtitle.source_path
            subtitle_source = _resolved_path(subtitle.source_path, strict=True)
            if subtitle_destination.exists():
                try:
                    same_subtitle = subtitle_source.samefile(subtitle_destination)
                except OSError:
                    same_subtitle = False
                if not same_subtitle:
                    raise HTTPException(status_code=409, detail="整理目标字幕已存在，未覆盖，也未执行任何文件整理。")


_MANUAL_ORGANIZE_RESERVATION_LOCK = threading.Lock()
_MANUAL_ORGANIZE_ACTIVE_PATHS: set[str] = set()


@router.post("/organize/apply", response_model=OrganizeApplyResponse)
async def organize_apply(request: OrganizeApplyRequest, store: Store = Depends(get_store)) -> OrganizeApplyResponse:
    if not request.confirm_real_move:
        raise HTTPException(status_code=403, detail="真实媒体移动需要单独确认，当前未执行。")
    rows = [row for row in request.preview.file_mappings if row.status != "skipped"]
    paths = [value for row in rows for value in (row.source_path, row.target_path)] if rows else [request.preview.source_path, request.preview.destination_preview]
    keys = {str(_resolved_path(path, strict=False)) for path in paths}
    with _MANUAL_ORGANIZE_RESERVATION_LOCK:
        if keys.intersection(_MANUAL_ORGANIZE_ACTIVE_PATHS):
            raise HTTPException(status_code=409, detail="这些文件正在整理，请等待当前操作完成。")
        _MANUAL_ORGANIZE_ACTIVE_PATHS.update(keys)
    try:
        return await _organize_apply_reserved(request, store)
    finally:
        with _MANUAL_ORGANIZE_RESERVATION_LOCK:
            _MANUAL_ORGANIZE_ACTIVE_PATHS.difference_update(keys)


async def _organize_apply_reserved(request: OrganizeApplyRequest, store: Store) -> OrganizeApplyResponse:
    persisted = store.get_organize_preview(request.preview.preview_id) if request.preview.preview_id is not None else None
    strict_manual = request.preview.media_type == "movie" or bool(persisted and (
        persisted["request"].get("select_files") or persisted["request"].get("media_type") == "movie"
    ))
    if strict_manual or request.preview.download_record_id is not None:
        if persisted is None or OrganizePreviewItem(**persisted["preview"]) != request.preview:
            raise HTTPException(status_code=409, detail="整理预览已失效或被修改，请重新生成预览。")
        if strict_manual and not request.preview.can_apply:
            raise HTTPException(status_code=409, detail=request.preview.block_reason or "当前预览未通过校验，请重新生成预览。")

    preview_payload = request.preview.model_dump(mode="json")
    mapping_errors = [row for row in request.preview.file_mappings if row.status == "error"]
    if mapping_errors:
        raise HTTPException(status_code=409, detail="整理预览中存在目标冲突或无效文件映射，未执行整理。")
    await _validate_download_record_apply_paths(request.preview, store)
    apply_subscription_id: int | None = None
    if request.preview.download_record_id is not None:
        history_item = store.get_history(request.preview.download_record_id)
        if history_item and history_item.get("subscription_id") is not None:
            apply_subscription_id = int(history_item["subscription_id"])
    if request.preview.file_mappings:
        _preflight_batch_apply(
            request.preview,
            store=store,
            subscription_id=apply_subscription_id,
        )
    if request.preview.preview_id is not None:
        persisted_record = store.get_organize_preview(request.preview.preview_id)
        identities = persisted_record["request"].get("_source_identities", {}) if persisted_record else {}
        items = [_file_preview_from_mapping(request.preview, row) for row in request.preview.file_mappings if row.status != "skipped"] or [request.preview]
        for item in items:
            if _existing_successful_apply_result(store, item, subscription_id=apply_subscription_id):
                continue
            if item.source_path in identities and identities[item.source_path] != _file_identity(item.source_path):
                raise HTTPException(status_code=409, detail="源文件在预览后发生变化，请重新生成预览。")
    availability = organize_preview_availability(request.preview)
    already_organized = preview_targets_already_organized(request.preview) or _preview_has_persisted_success(
        store,
        request.preview,
        subscription_id=apply_subscription_id,
    )
    if not request.preview.file_mappings and availability.destination_exists and not already_organized:
        raise HTTPException(status_code=409, detail="整理目标文件已存在，未覆盖，也未执行任何文件整理。")
    if not request.preview.file_mappings and (not availability.pending or not availability.source_exists) and not already_organized:
        raise HTTPException(status_code=409, detail=f"{availability.reason}，未执行整理。")
    policy = stored_organize_policy(store)
    preserve_source = request.preview.download_record_id is not None and policy.keep_seeding
    if request.preview.file_mappings:
        rows = list(request.preview.file_mappings)
        blockers = [row for row in rows if row.status == "needs_confirmation" and row.episode_number is None]
        if blockers:
            message = f"仍有 {len(blockers)} 个文件需要确认集数，未执行整理。"
            await _notification_service(store).send_best_effort(
                organize_needs_review_event(store, request.preview.source_path, message)
            )
            raise HTTPException(status_code=400, detail=message)
        success_count = 0
        failed_count = 0
        skipped_count = 0
        first_history_id: int | None = None
        first_destination = request.preview.destination_preview
        messages: list[str] = []
        subtitle_mappings = []
        for row in rows:
            if row.status == "skipped":
                skipped_count += 1
                continue
            file_preview = _file_preview_from_mapping(request.preview, row)
            replayed = _existing_successful_apply_result(
                store,
                file_preview,
                subscription_id=apply_subscription_id,
            )
            replayed_record: dict[str, Any] | None = None
            try:
                if replayed is None:
                    result = await _apply_preview_without_blocking(file_preview, preserve_source=preserve_source)
                else:
                    result, replayed_record = replayed
            except OrganizeApplyError as exc:
                failed_count += 1
                destination_path = exc.destination_path or row.target_path
                record = store.add_organize_history(
                    source_path=row.source_path,
                    destination_path=destination_path,
                    status="error",
                    message=exc.message,
                    preview=file_preview.model_dump(mode="json"),
                    subscription_id=apply_subscription_id,
                    manual_override=row.manual_override,
                    override_reason=row.override_reason,
                )
                first_history_id = first_history_id or record["id"]
                messages.append(f"{row.original_filename}：{exc.message}")
                await _notification_service(store).send_best_effort(
                    organize_failed_event(store, row.original_filename, exc.message, record["id"])
                )
                continue
            success_count += 1
            first_destination = result.destination_path
            subtitle_mappings.extend(file_preview.subtitle_mappings)
            record = replayed_record or store.add_organize_history(
                source_path=result.source_path,
                destination_path=result.destination_path,
                status=result.status,
                message=result.message if not row.manual_override else f"{result.message}（使用手动集数映射）",
                preview=_successful_preview_payload(file_preview),
                subscription_id=apply_subscription_id,
                manual_override=row.manual_override,
                override_reason=row.override_reason,
                effective_season=row.season_number,
            )
            first_history_id = first_history_id or record["id"]
            if replayed_record is None and not record.get("deduplicated"):
                await _notification_service(store).send_best_effort(
                    organize_completed_event(store, record)
                )
        if request.preview.download_record_id is not None and success_count and not failed_count and not skipped_count:
            _task_deleted, post_warnings, _cleanup = await _post_apply_download_record_cleanup(
                request.preview,
                store,
                source_path=request.preview.source_path,
            )
            messages.extend(post_warnings)
        elif request.preview.download_record_id is not None and success_count:
            messages.append("部分文件未整理，保留下载器任务与原文件，未将整个下载记录标记为整理完成。")
        total = len(rows)
        kind = "电影" if request.preview.media_type == "movie" else "合集"
        outcome = "未全部完成" if failed_count else "完成"
        message = f"{kind}整理{outcome}：共 {total} 个文件，成功 {success_count}，失败 {failed_count}，跳过 {skipped_count}。"
        if messages:
            message += " " + "；".join(messages[:3])
        return OrganizeApplyResponse(
            ok=failed_count == 0,
            status="moved" if success_count else "error" if failed_count else "skipped",
            message=message,
            source_path=request.preview.source_path,
            destination_path=first_destination,
            history_id=first_history_id or 0,
            subtitle_mappings=subtitle_mappings,
        )

    replayed = _existing_successful_apply_result(
        store,
        request.preview,
        subscription_id=apply_subscription_id,
    )
    replayed_record: dict[str, Any] | None = None
    try:
        if replayed is None:
            result = await _apply_preview_without_blocking(request.preview, preserve_source=preserve_source)
        else:
            result, replayed_record = replayed
    except OrganizeApplyError as exc:
        destination_path = exc.destination_path
        if destination_path is None:
            try:
                destination_path = str(destination_path_for_preview(request.preview))
            except OrganizeApplyError:
                destination_path = request.preview.destination_preview
        store.add_organize_history(
            source_path=request.preview.source_path,
            destination_path=destination_path,
            status="error",
            message=exc.message,
            preview=preview_payload,
            subscription_id=apply_subscription_id,
        )
        await _notification_service(store).send_best_effort(
            organize_failed_event(store, request.preview.source_path, exc.message)
        )
        raise HTTPException(status_code=exc.status_code, detail=exc.message)

    task_deleted, post_warnings, cleanup = await _post_apply_download_record_cleanup(
        request.preview,
        store,
        source_path=result.source_path,
    )
    message = result.message
    if task_deleted:
        message = "已整理并移除 qBittorrent 任务"
    if post_warnings:
        message = f"{message}（{'；'.join(post_warnings[:3])}）"
    record = replayed_record or store.add_organize_history(
        source_path=result.source_path,
        destination_path=result.destination_path,
        status=result.status,
        message=message,
        preview=_successful_preview_payload(request.preview),
        subscription_id=apply_subscription_id,
        qbittorrent_task_deleted=task_deleted,
        delete_files_from_qbittorrent=policy.delete_files_after_organize if request.preview.download_record_id is not None else False,
        **cleanup,
    )
    if replayed_record is None and not record.get("deduplicated"):
        await _notification_service(store).send_best_effort(
            organize_completed_event(store, record)
        )
    return OrganizeApplyResponse(
        ok=True,
        status=result.status,
        message=message,
        source_path=result.source_path,
        destination_path=result.destination_path,
        history_id=record["id"],
        subtitle_mappings=request.preview.subtitle_mappings,
    )
