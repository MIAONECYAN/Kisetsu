from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata
from collections.abc import Collection

from app.models import EpisodeParseRule, ParsedAnimeTitle, SearchResult
from app.services.season_rewrite import rewritten_season
from app.services.title_parser import KNOWN_FANSUB_TOKENS, parse_title

SEARCH_BUILTIN_FANSUB_NAMES = ("黒ネズミたち",)

_EPISODE_FIELDS = (
    "episode",
    "episode_number",
    "episode_start",
    "episode_end",
    "is_batch",
    "is_multi_episode",
    "resource_type",
    "display_episode_label",
    "parse_rule_name",
    "parse_reason",
    "parse_confidence",
    "parse_failure_reason",
    "part_number",
    "absolute_episode_number",
    "absolute_episode_start",
    "absolute_episode_end",
    "absolute_episode_start_sort",
    "absolute_episode_end_sort",
    "season_episode_start",
    "season_episode_end",
    "batch_title",
)

_SEASON_FIELDS = (
    "season",
    "season_number",
    "explicit_season_number",
    "inferred_season_number",
    "context_season_number",
    "effective_season_number",
    "season_source",
    "season_conflict",
    "season_conflict_reason",
)


@dataclass(frozen=True, slots=True)
class SearchResultAnalysis:
    title: ParsedAnimeTitle
    subtitle: ParsedAnimeTitle | None
    effective: ParsedAnimeTitle
    episode_source: str
    season_source: str
    fansub_source: str
    resolution_source: str
    subtitle_language_source: str
    version_source: str
    file_size_source: str
    conflicts: tuple[str, ...]


def _text_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"\s+", " ", normalized).strip()


def custom_leading_fansub(title: str, names: Collection[str]) -> str | None:
    match = re.match(r"^(?:\[([^\]]+)\]|【([^】]+)】)", title.strip())
    if match is None or not title.strip()[match.end():].strip():
        return None
    leading = _text_key(match.group(1) or match.group(2) or "")
    return next((name for name in names if _text_key(name) == leading), None)


def search_result_text_fields(result: SearchResult) -> tuple[tuple[str, str], ...]:
    fields: list[tuple[str, str]] = []
    seen: set[str] = set()
    for source, raw_value in (("title", result.title), ("subtitle", result.subtitle)):
        value = (raw_value or "").strip()
        key = _text_key(value) if value else ""
        if not key or key in seen:
            continue
        seen.add(key)
        fields.append((source, value))
    return tuple(fields)


def combined_search_result_text(result: SearchResult) -> str:
    return " ".join(value for _, value in search_result_text_fields(result))


def is_collection_parsed(parsed: ParsedAnimeTitle) -> bool:
    if parsed.is_batch or parsed.is_multi_episode:
        return True
    if parsed.resource_type in {"batch", "episode_range"}:
        return True
    return bool(
        parsed.episode_start is not None
        and parsed.episode_end is not None
        and parsed.episode_end > parsed.episode_start
    )


def apply_season_rewrite(
    parsed: ParsedAnimeTitle,
    season_rewrite: str | None,
    *,
    context_season_number: int | None = None,
) -> ParsedAnimeTitle:
    original = parsed.explicit_season_number
    target = rewritten_season(original, season_rewrite)
    if original is None or target == original:
        return parsed
    conflict = context_season_number is not None and target != context_season_number
    effective = context_season_number if context_season_number is not None else target
    return parsed.model_copy(update={
        "season": effective,
        "season_number": effective,
        "effective_season_number": effective,
        "season_conflict": conflict,
        "season_conflict_reason": (
            f"资源原本为 Season {original:02d}，改写为 Season {target:02d}，但订阅是 Season {context_season_number:02d}"
            if conflict else None
        ),
    })


def _episode_signature(parsed: ParsedAnimeTitle) -> tuple[int | None, int | None]:
    start = parsed.episode_start if parsed.episode_start is not None else parsed.episode
    end = parsed.episode_end if parsed.episode_end is not None else start
    return start, end


def _field_source(primary_value: object, subtitle_value: object) -> str:
    if primary_value not in (None, ""):
        return "title"
    if subtitle_value not in (None, ""):
        return "subtitle"
    return "unknown"


def analyze_search_result(
    result: SearchResult,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
    *,
    context_season_number: int | None = None,
    season_rewrite: str | None = None,
) -> SearchResultAnalysis:
    if result.source == "animegarden":
        season = result.parsed_season_number if result.parsed_season_number is not None else context_season_number
        season_conflict = (
            result.parsed_season_number is not None
            and context_season_number is not None
            and result.parsed_season_number != context_season_number
        )
        parsed = ParsedAnimeTitle(
            original_title=result.title,
            title=result.normalized_title or result.title,
            episode=result.parsed_episode,
            episode_start=result.parsed_episode_start,
            episode_end=result.parsed_episode_end,
            is_batch=result.parsed_is_batch,
            is_special=result.parsed_is_special,
            season=season,
            explicit_season_number=result.parsed_season_number,
            context_season_number=context_season_number,
            season_conflict=season_conflict,
            season_conflict_reason=(
                f"资源季度 S{result.parsed_season_number} 与订阅季度 S{context_season_number} 不一致"
                if season_conflict else None
            ),
            season_source="metadata" if result.parsed_season_number is not None else "subscription" if context_season_number is not None else "unknown",
            part_number=result.parsed_part_number,
            fansub=result.parsed_fansub,
            resolution=result.parsed_resolution,
            subtitle_language=result.parsed_subtitle_language,
            display_episode_label=result.parsed_display_episode_label,
            parse_reason=result.parsed_parse_reason,
            parse_failure_reason="Anime Garden 未提供集数元数据" if result.parsed_episode is None and not result.parsed_is_batch else None,
            confidence=1.0 if result.parsed_parse_reason else 0.0,
        )
        evidence = "site_metadata" if result.parsed_parse_reason else "unknown"
        return SearchResultAnalysis(
            title=parsed,
            subtitle=None,
            effective=apply_season_rewrite(parsed, season_rewrite, context_season_number=context_season_number),
            episode_source=evidence,
            season_source="site_metadata" if result.parsed_season_number is not None else "unknown",
            fansub_source="site_metadata" if result.parsed_fansub else "unknown",
            resolution_source="site_metadata" if result.parsed_resolution else "unknown",
            subtitle_language_source="site_metadata" if result.parsed_subtitle_language else "unknown",
            version_source="unknown",
            file_size_source="site_metadata" if result.size_bytes is not None else "unknown",
            conflicts=(),
        )
    rules = episode_parse_rules or []
    primary = parse_title(
        result.title,
        rules,
        context_season_number=context_season_number,
    )
    subtitle = (
        parse_title(
            result.subtitle,
            rules,
            context_season_number=context_season_number,
        )
        if result.subtitle and result.subtitle.strip()
        else None
    )

    episode_evidence = primary
    episode_source = "title"
    if primary.episode is None and subtitle is not None and subtitle.episode is not None:
        episode_evidence = subtitle
        episode_source = "subtitle"

    season_evidence = primary
    season_source = "title"
    if primary.explicit_season_number is None and subtitle is not None and subtitle.explicit_season_number is not None:
        season_evidence = subtitle
        season_source = "subtitle"

    updates = {
        field: getattr(episode_evidence, field)
        for field in _EPISODE_FIELDS
    }
    updates.update({field: getattr(season_evidence, field) for field in _SEASON_FIELDS})

    technical_sources: dict[str, str] = {}
    for field in ("fansub", "resolution", "subtitle_language", "version", "file_size"):
        primary_value = getattr(primary, field)
        subtitle_value = getattr(subtitle, field) if subtitle is not None else None
        updates[field] = primary_value if primary_value not in (None, "") else subtitle_value
        technical_sources[field] = _field_source(primary_value, subtitle_value)

    updates["is_final"] = primary.is_final or bool(subtitle and subtitle.is_final)
    updates["is_special"] = primary.is_special or bool(subtitle and subtitle.is_special)
    updates["confidence"] = max(primary.confidence, episode_evidence.confidence)
    updates["needs_confirmation"] = primary.needs_confirmation and episode_evidence.needs_confirmation
    if episode_source == "subtitle":
        updates["parse_reason"] = "副标题集数"

    conflicts: list[str] = []
    if subtitle is not None:
        primary_range = _episode_signature(primary)
        subtitle_range = _episode_signature(subtitle)
        if primary_range[0] is not None and subtitle_range[0] is not None and primary_range != subtitle_range:
            conflicts.append(
                "主标题与副标题集数范围冲突，采用主标题"
                if episode_source == "title"
                else "主标题未提供集数，采用副标题范围"
            )
        if (
            primary.explicit_season_number is not None
            and subtitle.explicit_season_number is not None
            and primary.explicit_season_number != subtitle.explicit_season_number
        ):
            conflicts.append("主标题与副标题季度冲突，采用主标题")
        if primary.resolution and subtitle.resolution and primary.resolution.casefold() != subtitle.resolution.casefold():
            conflicts.append("主标题与副标题分辨率冲突，采用主标题")

    effective = apply_season_rewrite(
        primary.model_copy(update=updates),
        season_rewrite,
        context_season_number=context_season_number,
    )
    return SearchResultAnalysis(
        title=primary,
        subtitle=subtitle,
        effective=effective,
        episode_source=episode_source,
        season_source=season_source,
        fansub_source=technical_sources["fansub"],
        resolution_source=technical_sources["resolution"],
        subtitle_language_source=technical_sources["subtitle_language"],
        version_source=technical_sources["version"],
        file_size_source=technical_sources["file_size"],
        conflicts=tuple(conflicts),
    )


def enrich_search_result(
    result: SearchResult,
    *,
    custom_fansubs: Collection[str] = (),
    disabled_fansubs: Collection[str] = (),
    generic_keywords_enabled: bool = True,
) -> SearchResult:
    analysis = analyze_search_result(result)
    parsed = analysis.effective
    disabled_keys = {_text_key(name) for name in disabled_fansubs}
    if result.source == "animegarden":
        fansub = result.parsed_fansub
        if fansub is not None and _text_key(fansub) in disabled_keys:
            fansub = None
        return result.model_copy(update={"parsed_fansub": fansub})
    parsed_name = parsed.fansub
    known_name = max(
        (name for name in KNOWN_FANSUB_TOKENS if parsed_name and _text_key(name) in _text_key(parsed_name)),
        key=len,
        default=None,
    )
    explicit_star = bool(parsed_name and any(
        value.lstrip().startswith(f"{parsed_name}★")
        for value in (result.title, result.subtitle or "")
    ))
    if known_name is not None and _text_key(known_name) in disabled_keys:
        parsed_name = None
    elif not generic_keywords_enabled and known_name is None and not explicit_star:
        parsed_name = None
    fansub = parsed_name or custom_leading_fansub(result.title, SEARCH_BUILTIN_FANSUB_NAMES) or custom_leading_fansub(result.title, custom_fansubs)
    if fansub is not None and _text_key(fansub) in disabled_keys:
        fansub = None
    fallback_episode = None
    if parsed.episode is None and result.description:
        match = re.search(r"(?:第\s*)?(\d{1,4})\s*[集话話]", result.description)
        if match:
            fallback_episode = int(match.group(1))
    episode = parsed.episode if parsed.episode is not None else fallback_episode
    episode_start = parsed.episode_start if parsed.episode_start is not None else fallback_episode
    display_episode_label = parsed.display_episode_label
    parse_reason = parsed.parse_reason
    if parsed.episode is None and fallback_episode is not None:
        display_episode_label = f"第 {fallback_episode} 集"
        parse_reason = "简介集数"
    return result.model_copy(
        update={
            "parsed_fansub": fansub,
            "parsed_episode": episode,
            "parsed_episode_start": episode_start,
            "parsed_episode_end": parsed.episode_end,
            "parsed_resolution": parsed.resolution,
            "parsed_subtitle_language": parsed.subtitle_language,
            "normalized_title": analysis.title.title,
            "parsed_is_batch": parsed.is_batch,
            "parsed_is_multi_episode": parsed.is_multi_episode,
            "parsed_is_special": parsed.is_special,
            "parsed_resource_type": parsed.resource_type,
            "parsed_season_number": parsed.season_number,
            "parsed_part_number": parsed.part_number,
            "parsed_absolute_episode_number": parsed.absolute_episode_number,
            "parsed_absolute_episode_start": parsed.absolute_episode_start,
            "parsed_absolute_episode_end": parsed.absolute_episode_end,
            "parsed_absolute_episode_start_sort": parsed.absolute_episode_start_sort,
            "parsed_absolute_episode_end_sort": parsed.absolute_episode_end_sort,
            "parsed_season_episode_start": parsed.season_episode_start,
            "parsed_season_episode_end": parsed.season_episode_end,
            "parsed_display_episode_label": display_episode_label,
            "parsed_parse_reason": parse_reason,
        }
    )
