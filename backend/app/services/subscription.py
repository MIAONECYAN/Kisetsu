from __future__ import annotations

import hashlib
import base64
import binascii
import re
import unicodedata
from urllib.parse import parse_qs, urlparse

from app.db import Store
from app.keyword_expression import KeywordExpressionError, keyword_expression_matches
from app.models import EpisodeParseRule, MatchDiagnostics, MatchDiagnosticSample, RefreshResponse, SearchResult, Subscription
from app.services.episode_fulfillment import subscription_episode_range_reaches_target
from app.services.downloads import resource_total_size_bytes
from app.services.search import result_dedupe_key
from app.services.search_result_analysis import (
    analyze_search_result,
    combined_search_result_text,
    is_collection_parsed,
    search_result_text_fields,
)
from app.services.title_parser import normalize_resolution_preset

BTIH_RE = re.compile(r"btih[:=]([a-z2-7]{32}|[a-f0-9]{40})", re.IGNORECASE)
TORRENT_PATH_HASH_RE = re.compile(r"/([a-f0-9]{40})(?:\.torrent)?(?:$|[/?#])", re.IGNORECASE)


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


def btih_hash_from_url(value: str | None) -> str | None:
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


def fingerprint_result(result: SearchResult) -> str:
    payload = result.magnet_url or result.download_url or f"{result.source}:{result.title}"
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def subscription_result_dedupe_key(result: SearchResult) -> str:
    stable_id = result.id.strip()
    if stable_id:
        return f"id:{result.source.casefold()}:{stable_id.casefold()}"
    return result_dedupe_key(result)


def normalize_match_text(value: str | None) -> str:
    if not value:
        return ""
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = re.sub(r"[？?/:：~～·・,，.。!！\-_+|()[\]【】「」『』〈〉《》]+", " ", normalized)
    normalized = re.sub(r"\s+", " ", normalized).strip()
    return normalized


def compact_match_text(value: str | None) -> str:
    return re.sub(r"\s+", "", normalize_match_text(value))


def split_title_aliases(value: str | None) -> list[str]:
    if not value:
        return []
    parts = re.split(r"\s*(?:/|／|\||｜|;|；)\s*", value)
    return [part.strip() for part in parts if part.strip()]


def subscription_aliases(subscription: Subscription) -> list[str]:
    aliases: list[str] = []
    aliases.extend(split_title_aliases(subscription.name))
    aliases.extend(split_title_aliases(subscription.keyword))
    aliases.extend(subscription.aliases)
    seen: set[str] = set()
    unique: list[str] = []
    for alias in aliases:
        key = compact_match_text(alias)
        if key and key not in seen:
            seen.add(key)
            unique.append(alias)
    return unique


def _has_explicit_mikan_source(subscription: Subscription) -> bool:
    source = subscription.mikan_bangumi_url or subscription.source_url or subscription.keyword
    return bool(source and re.search(r"(mikanani\.me/.*/Bangumi/\d+|/Home/Bangumi/\d+|^\d+$)", source.strip(), flags=re.I))


def _subscription_mikan_bangumi_id(subscription: Subscription) -> str | None:
    source = subscription.mikan_bangumi_url or subscription.source_url
    if not source:
        return subscription.keyword.strip() if subscription.keyword.strip().isdigit() else None
    match = re.search(r"(?:/Home/Bangumi/|^)(\d+)(?:\D|$)", source.strip(), flags=re.I)
    return match.group(1) if match else None


def _subscription_mikan_group_id(subscription: Subscription) -> str | None:
    source = subscription.mikan_bangumi_url or subscription.source_url
    if not source:
        return None
    fragment = urlparse(source.strip()).fragment.strip()
    return fragment if fragment.isdigit() else None


def _subscription_bangumi_ids(store: Store | None, subscription: Subscription) -> set[str]:
    ids = {item for item in [_subscription_mikan_bangumi_id(subscription)] if item}
    if store is not None and subscription.id is not None:
        for binding in store.list_metadata_bindings_for_target("subscription", str(subscription.id)):
            bangumi_id = binding.get("bangumi_id")
            if bangumi_id:
                ids.add(str(bangumi_id))
    return ids


def title_match_source(subscription: Subscription, result: SearchResult) -> str | None:
    if _has_explicit_mikan_source(subscription) and result.source == "mikan":
        return "metadata"
    alias_keys = [compact_match_text(alias) for alias in subscription_aliases(subscription)]
    for source, value in search_result_text_fields(result):
        text = compact_match_text(value)
        if any(alias and alias in text for alias in alias_keys):
            return source
    return None


def title_matches_subscription(subscription: Subscription, result: SearchResult) -> bool:
    return title_match_source(subscription, result) is not None


def fansub_matches(
    expected: str | None,
    parsed_fansub: str | None,
    title: str,
    *,
    site_fansub: str | None = None,
) -> bool:
    if not expected:
        return True
    expected_key = compact_match_text(expected)
    parsed_key = compact_match_text(parsed_fansub)
    site_key = compact_match_text(site_fansub)
    title_key = compact_match_text(title)
    return bool(expected_key and (expected_key in {parsed_key, site_key} or expected_key in title_key))


def term_in_title(term: str, title: str) -> bool:
    return compact_match_text(term) in compact_match_text(title)


def term_in_result(term: str, result: SearchResult) -> bool:
    return any(term_in_title(term, value) for _, value in search_result_text_fields(result))


def resolution_filter_terms(subscription: Subscription) -> tuple[str, list[str]]:
    mode = subscription.resolution_mode
    if mode == "preset":
        term = (subscription.resolution_preset or subscription.resolution or "").strip()
        return "preset", [term] if term else []
    if mode == "custom":
        value = (subscription.resolution_custom or subscription.resolution or "").strip()
        terms = [part.strip() for part in re.split(r"[,，;；、]+", value) if part.strip()]
        return "custom", terms
    legacy = (subscription.resolution or "").strip()
    if legacy:
        return "preset", [legacy]
    return "any", []


def resolution_matches(subscription: Subscription, parsed_resolution: str | None, title: str) -> tuple[bool, str | None]:
    mode, terms = resolution_filter_terms(subscription)
    if mode == "any" or not terms:
        return True, None
    if mode == "preset":
        for term in terms:
            expected_preset = normalize_resolution_preset(term)
            parsed_preset = normalize_resolution_preset(parsed_resolution)
            if (
                (expected_preset is not None and expected_preset == parsed_preset)
                or (parsed_resolution or "").casefold() == term.casefold()
                or term_in_title(term, title)
            ):
                return True, None
        return False, f"分辨率不匹配：需要 {terms[0]}，解析到 {parsed_resolution or '未知'}"
    for term in terms:
        if term_in_title(term, title):
            return True, None
    return False, f"标题不包含自定义分辨率关键词 {', '.join(terms)}"


def parsed_episode_range(parsed_episode: int | None, parsed_episode_end: int | None) -> tuple[int | None, int | None]:
    if parsed_episode is None:
        return None, None
    end = parsed_episode_end if parsed_episode_end is not None else parsed_episode
    return parsed_episode, max(parsed_episode, end)


def range_contains(start: int | None, end: int | None, target: int) -> bool:
    return start is not None and end is not None and start <= target <= end


def range_overlaps(start: int | None, end: int | None, targets: set[int]) -> bool:
    if start is None or end is None:
        return False
    return any(start <= target <= end for target in targets)


def parse_episode_filter(value: str | None) -> set[int] | None:
    if not value or not value.strip():
        return None
    selected: set[int] = set()
    for raw_part in value.split(","):
        part = raw_part.strip()
        if not part:
            continue
        if re.fullmatch(r"\d+", part):
            selected.add(int(part))
            continue
        match = re.fullmatch(r"(\d+)\s*-\s*(\d+)", part)
        if not match:
            raise ValueError("指定集数格式无效，请使用 1-6, 8, 10-12 这样的格式。")
        start = int(match.group(1))
        end = int(match.group(2))
        if start > end:
            raise ValueError("指定集数范围无效，请确认起始集数不大于结束集数。")
        selected.update(range(start, end + 1))
    return selected


def subscription_size_matches(
    subscription: Subscription,
    result: SearchResult,
) -> tuple[bool, str | None]:
    if subscription.min_size_bytes is None and subscription.max_size_bytes is None:
        return True, None
    size_bytes = resource_total_size_bytes(result)
    if size_bytes is None:
        return False, "体积未知，无法通过视频体积过滤"
    if subscription.min_size_bytes is not None and size_bytes < subscription.min_size_bytes:
        return False, f"视频体积小于最小值：{size_bytes} B < {subscription.min_size_bytes} B"
    if subscription.max_size_bytes is not None and size_bytes > subscription.max_size_bytes:
        return False, f"视频体积大于最大值：{size_bytes} B > {subscription.max_size_bytes} B"
    return True, None


def analyze_match(
    subscription: Subscription,
    result: SearchResult,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
    *,
    subscription_bangumi_ids: set[str] | None = None,
    include_matched_sample: bool = False,
) -> tuple[bool, str | None, MatchDiagnosticSample | None]:
    analysis = analyze_search_result(
        result,
        episode_parse_rules if episode_parse_rules is not None else subscription.episode_parse_rules,
        context_season_number=subscription.season,
    )
    parsed = analysis.effective
    matched_title_source = title_match_source(subscription, result)
    sample = MatchDiagnosticSample(
        title=result.title,
        source=result.source,
        reason="",
        parsed_fansub=parsed.fansub,
        site_fansub_id=result.mikan_group_id,
        site_fansub=result.mikan_group_name,
        parsed_resolution=parsed.resolution,
        parsed_episode=parsed.episode,
        parsed_episode_start=parsed.episode_start,
        parsed_episode_end=parsed.episode_end,
        resource_type=parsed.resource_type,
        display_episode_label=parsed.display_episode_label,
        is_batch=parsed.is_batch,
        is_multi_episode=parsed.is_multi_episode,
        absolute_episode_start=parsed.absolute_episode_start,
        absolute_episode_end=parsed.absolute_episode_end,
        season_episode_start=parsed.season_episode_start,
        season_episode_end=parsed.season_episode_end,
        is_final=parsed.is_final,
        parse_rule_name=parsed.parse_rule_name,
        parse_failure_reason=parsed.parse_failure_reason,
        explicit_season_number=parsed.explicit_season_number,
        inferred_season_number=parsed.inferred_season_number,
        context_season_number=parsed.context_season_number,
        effective_season_number=parsed.effective_season_number,
        season_source=parsed.season_source,
        season_conflict=parsed.season_conflict,
        season_conflict_reason=parsed.season_conflict_reason,
        title_match_source=matched_title_source or "unknown",
        episode_parse_source=analysis.episode_source if parsed.episode is not None else "unknown",
        season_parse_source=analysis.season_source,
        fansub_parse_source=analysis.fansub_source,
        resolution_parse_source=analysis.resolution_source,
        parse_conflict_reason="；".join(analysis.conflicts) or None,
    )
    if parsed.episode is None:
        parse_failed = True
    else:
        parse_failed = False

    if matched_title_source is None:
        sample.reason = "番名或别名未命中"
        return False, "excluded_by_title", sample

    bangumi_ids = subscription_bangumi_ids if subscription_bangumi_ids is not None else _subscription_bangumi_ids(None, subscription)
    result_bangumi_id = result.mikan_bangumi_id or result.bangumi_id
    if bangumi_ids and result_bangumi_id and result_bangumi_id not in bangumi_ids:
        expected = " / ".join(sorted(bangumi_ids))
        sample.reason = f"资源 Bangumi ID {result_bangumi_id} 与订阅 Bangumi ID {expected} 不一致，已排除。"
        return False, "excluded_by_bangumi_id_mismatch", sample

    expected_group_id = _subscription_mikan_group_id(subscription)
    if expected_group_id and result.mikan_group_id and result.mikan_group_id != expected_group_id:
        sample.reason = (
            f"资源 Mikan 字幕组 ID {result.mikan_group_id} 与订阅选择的字幕组 ID "
            f"{expected_group_id} 不一致，已排除。"
        )
        return False, "excluded_by_metadata_mismatch", sample

    if parsed.is_special and subscription.season not in {None, 0}:
        sample.reason = "资源为番外、特典或剧场版，不属于当前季度"
        return False, "excluded_by_metadata_mismatch", sample

    if parsed.season_conflict:
        sample.reason = f"{parsed.season_conflict_reason or '资源季度与订阅季度不一致'}，已排除。"
        return False, "excluded_by_season_mismatch", sample

    if not fansub_matches(
        subscription.fansub,
        parsed.fansub,
        combined_search_result_text(result),
        site_fansub=result.mikan_group_name,
    ):
        site_text = (
            f"，站点分组 {result.mikan_group_name}（ID {result.mikan_group_id}）"
            if result.mikan_group_name and result.mikan_group_id
            else ""
        )
        sample.reason = f"字幕组不匹配：需要 {subscription.fansub or '-'}，标题解析到 {parsed.fansub or '未知'}{site_text}"
        return False, "excluded_by_fansub", sample

    try:
        include_matches = keyword_expression_matches(
            subscription.include_keywords,
            lambda term: term_in_result(term, result),
        )
    except KeywordExpressionError as exc:
        sample.reason = f"包含词规则无效：{exc}"
        return False, "excluded_by_include", sample
    try:
        exclude_matches = keyword_expression_matches(
            subscription.exclude_keywords,
            lambda term: term_in_result(term, result),
        )
    except KeywordExpressionError as exc:
        sample.reason = f"排除词规则无效：{exc}"
        return False, "excluded_by_exclude", sample

    def include_passes() -> bool:
        return not subscription.include_keywords or include_matches

    def exclude_passes() -> bool:
        return not exclude_matches

    if subscription.filter_order == "exclude_first":
        if not exclude_passes():
            sample.reason = "命中排除词"
            return False, "excluded_by_exclude", sample
        if not include_passes():
            sample.reason = "未命中包含词"
            return False, "excluded_by_include", sample
    else:
        if not include_passes():
            sample.reason = "未命中包含词"
            return False, "excluded_by_include", sample
        if not exclude_passes():
            sample.reason = "命中排除词"
            return False, "excluded_by_exclude", sample

    resolution_ok, resolution_reason = resolution_matches(
        subscription,
        parsed.resolution,
        combined_search_result_text(result),
    )
    if not resolution_ok:
        sample.reason = resolution_reason or "分辨率不匹配"
        return False, "excluded_by_resolution", sample

    size_matches, size_reason = subscription_size_matches(subscription, result)
    if not size_matches:
        sample.reason = size_reason or "视频体积不符合订阅规则"
        return False, "excluded_by_size", sample

    if subscription.regex_enabled and subscription.regex:
        try:
            texts = [value for _, value in search_result_text_fields(result)]
            texts.append(combined_search_result_text(result))
            if not any(re.search(subscription.regex, text, flags=re.I) for text in texts):
                sample.reason = "正则表达式未匹配资源标题或副标题"
                return False, "excluded_by_regex", sample
        except re.error as exc:
            sample.reason = f"正则表达式错误：{exc}"
            return False, "excluded_by_regex", sample

    episode_start, episode_end = parsed_episode_range(parsed.episode_start or parsed.episode, parsed.episode_end)
    is_collection = is_collection_parsed(parsed)
    covers_whole_season = is_collection and parsed.is_batch and episode_start is None and episode_end is None
    if covers_whole_season:
        parse_failed = False
    if is_collection and subscription.batch_resource_policy == "ignore":
        sample.reason = "资源为合集，当前合集策略为忽略"
        return False, "excluded_by_batch_policy", sample
    if subscription.episode is not None and not covers_whole_season and not range_contains(episode_start, episode_end, subscription.episode):
        parsed_text = parsed.display_episode_label or (f"{episode_start}-{episode_end}" if episode_start and episode_end else str(parsed.episode or "未知"))
        sample.reason = f"不是指定集数：需要 {subscription.episode}，解析到 {parsed_text}"
        return False, "excluded_by_episode_coverage", sample
    if not covers_whole_season and not subscription_episode_range_reaches_target(subscription, episode_end, logical=False):
        parsed_text = parsed.display_episode_label or (f"{episode_start}-{episode_end}" if episode_start and episode_end else str(parsed.episode or "未知"))
        sample.reason = f"早于起始集数：需要从 {subscription.episode_start} 开始，解析到 {parsed_text}"
        return False, "excluded_by_episode_coverage", sample
    episode_filter = parse_episode_filter(subscription.episode_filter)
    if episode_filter is not None:
        display_start = episode_start + subscription.episode_offset if episode_start is not None else None
        display_end = episode_end + subscription.episode_offset if episode_end is not None else None
        if not covers_whole_season and not range_overlaps(display_start, display_end, episode_filter):
            parsed_text = parsed.display_episode_label or (f"{display_start}-{display_end}" if display_start and display_end else str(display_start or "未知"))
            sample.reason = f"不在指定集数范围内：解析到 {parsed_text}"
            return False, "excluded_by_episode_coverage", sample

    if parse_failed:
        sample.reason = "番名已匹配，但集数未识别"
        return True, "parse_failed_count", sample if include_matched_sample else None
    if subscription.season is not None:
        sample.reason = "已匹配"
        return True, "season_matched_count", sample if include_matched_sample else None
    sample.reason = "已匹配"
    return True, None, sample if include_matched_sample else None


def matches_rule(subscription: Subscription, result: SearchResult) -> bool:
    matched, _, _ = analyze_match(subscription, result)
    return matched


def filter_results_by_subscription_size(
    subscription: Subscription,
    results: list[SearchResult],
) -> list[SearchResult]:
    return [
        result
        for result in results
        if subscription_size_matches(subscription, result)[0]
    ]


def match_results_with_diagnostics(
    store: Store,
    subscription: Subscription,
    results: list[SearchResult],
    episode_parse_rules: list[EpisodeParseRule] | None = None,
) -> tuple[list[SearchResult], MatchDiagnostics]:
    matched: list[SearchResult] = []
    diagnostics = MatchDiagnostics(total_fetched=len(results))
    excluded_samples: list[tuple[str, MatchDiagnosticSample]] = []
    subscription_bangumi_ids = _subscription_bangumi_ids(store, subscription)
    seen_result_keys: set[str] = set()

    def increment(reason_key: str | None) -> None:
        if reason_key and hasattr(diagnostics, reason_key):
            setattr(diagnostics, reason_key, getattr(diagnostics, reason_key) + 1)
        if reason_key in {"excluded_by_batch_policy", "excluded_by_episode_coverage"}:
            diagnostics.excluded_by_episode_filter += 1

    for result in results:
        result_key = subscription_result_dedupe_key(result)
        if result_key in seen_result_keys:
            diagnostics.duplicate_count += 1
            continue
        seen_result_keys.add(result_key)
        is_match, reason_key, sample = analyze_match(
            subscription,
            result,
            episode_parse_rules,
            subscription_bangumi_ids=subscription_bangumi_ids,
            include_matched_sample=True,
        )
        if is_match:
            matched.append(result)
            increment(reason_key)
            if sample and sample.title_match_source == "subtitle":
                diagnostics.matched_by_subtitle += 1
            if sample and sample.episode_parse_source == "subtitle":
                diagnostics.episode_parsed_from_subtitle += 1
            continue
        increment(reason_key)
        if sample:
            excluded_samples.append((reason_key or "unknown", sample))
    selected_indices: list[int] = []
    seen_reasons: set[str] = set()
    for index, (reason_key, _) in enumerate(excluded_samples):
        if reason_key in seen_reasons:
            continue
        seen_reasons.add(reason_key)
        selected_indices.append(index)
        if len(selected_indices) >= 12:
            break
    seen_strata: set[tuple[str, str]] = {
        (
            excluded_samples[index][0],
            excluded_samples[index][1].site_fansub_id
            or excluded_samples[index][1].site_fansub
            or excluded_samples[index][1].parsed_fansub
            or "unknown",
        )
        for index in selected_indices
    }
    for index, (reason_key, sample) in enumerate(excluded_samples):
        if len(selected_indices) >= 12:
            break
        group_key = sample.site_fansub_id or sample.site_fansub or sample.parsed_fansub or "unknown"
        stratum = (reason_key, group_key)
        if index in selected_indices or stratum in seen_strata:
            continue
        seen_strata.add(stratum)
        selected_indices.append(index)
    for index in range(len(excluded_samples)):
        if len(selected_indices) >= 12:
            break
        if index not in selected_indices:
            selected_indices.append(index)
    diagnostics.sample_excluded_items = [excluded_samples[index][1] for index in selected_indices]
    _, duplicate_items = dedupe_results(store, matched)
    diagnostics.matched_count = len(matched)
    diagnostics.duplicate_count += len(duplicate_items)
    return matched, diagnostics


def dedupe_results(store: Store, results: list[SearchResult]) -> tuple[list[SearchResult], list[SearchResult]]:
    fresh: list[SearchResult] = []
    skipped: list[SearchResult] = []
    for result in results:
        if store.history_exists(fingerprint_result(result)):
            skipped.append(result)
        else:
            fresh.append(result)
    return fresh, skipped


def should_auto_download(
    subscription: Subscription,
    result: SearchResult,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
) -> bool:
    if subscription.batch_resource_policy == "allow_auto_download":
        return True
    parsed = analyze_search_result(
        result,
        episode_parse_rules if episode_parse_rules is not None else subscription.episode_parse_rules,
        context_season_number=subscription.season,
    ).effective
    return not is_collection_parsed(parsed)


def record_processed(
    store: Store,
    result: SearchResult,
    *,
    subscription_id: int | None,
    status: str,
    qbittorrent_hash: str | None = None,
    downloader_type: str = "qbittorrent",
    remote_task_id: str | None = None,
    torrent_name: str | None = None,
    save_path: str | None = None,
) -> int:
    url = result.magnet_url or result.download_url
    return store.add_history(
        fingerprint=fingerprint_result(result),
        title=result.title,
        source=result.source,
        download_url=url,
        subscription_id=subscription_id,
        status=status,
        qbittorrent_hash=qbittorrent_hash or btih_hash_from_url(url),
        downloader_type=downloader_type,
        remote_task_id=remote_task_id,
        torrent_name=torrent_name,
        save_path=save_path,
    )


def build_refresh_response(
    store: Store,
    subscription: Subscription,
    results: list[SearchResult],
    *,
    auto_download: bool = False,
) -> RefreshResponse:
    matched, diagnostics = match_results_with_diagnostics(store, subscription, results)
    fresh, skipped = dedupe_results(store, matched)
    added: list[SearchResult] = []
    if auto_download:
        for result in fresh:
            if not should_auto_download(subscription, result):
                continue
            record_processed(store, result, subscription_id=subscription.id, status="queued")
            added.append(result)
    return RefreshResponse(
        subscription_id=subscription.id,
        matched=matched,
        added=added,
        skipped=skipped,
        diagnostics=diagnostics,
    )
