from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata

from app.models import EpisodeParseRule, ParsedAnimeTitle, SearchResult
from app.services.title_parser import parse_title

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
) -> SearchResultAnalysis:
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

    effective = primary.model_copy(update=updates)
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


def enrich_search_result(result: SearchResult) -> SearchResult:
    analysis = analyze_search_result(result)
    parsed = analysis.effective
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
            "parsed_fansub": parsed.fansub,
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
