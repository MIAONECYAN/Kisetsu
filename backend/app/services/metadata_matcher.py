from __future__ import annotations

import asyncio
import re
from difflib import SequenceMatcher

from app.metadata import BangumiAdapter, TMDBAdapter, describe_metadata_error
from app.models import MetadataCandidate, MetadataSearchRequest, MetadataSearchResponse, PlexSeasonMapping
from app.services.title_parser import parse_title


def candidate_key(candidate: MetadataCandidate) -> str:
    if candidate.source == "tmdb" and candidate.media_type == "movie":
        return f"tmdb:movie:{candidate.external_id}"
    return f"{candidate.source}:{candidate.external_id}"


def normalized(value: str | None) -> str:
    if not value:
        return ""
    return re.sub(r"\s+", " ", re.sub(r"[\W_]+", " ", value.lower())).strip()


def year_from_date(value: str | None) -> int | None:
    if not value:
        return None
    match = re.match(r"(\d{4})", value)
    return int(match.group(1)) if match else None


def similarity(left: str, right: str) -> float:
    left_norm = normalized(left)
    right_norm = normalized(right)
    if not left_norm or not right_norm:
        return 0.0
    if left_norm == right_norm:
        return 1.0
    if left_norm in right_norm or right_norm in left_norm:
        return 0.85
    return SequenceMatcher(None, left_norm, right_norm).ratio()


def score_candidate(candidate: MetadataCandidate, query: str, year: int | None) -> MetadataCandidate:
    names = [candidate.title, candidate.original_title or "", candidate.chinese_title or "", *candidate.aliases]
    best_name_score = max(similarity(query, name) for name in names)
    score = best_name_score
    reasons: list[str] = []
    if best_name_score >= 0.95:
        reasons.append("标题高度匹配")
    elif best_name_score >= 0.78:
        reasons.append("标题相似")
    elif best_name_score >= 0.55:
        reasons.append("标题部分匹配")

    if candidate.source == "bangumi":
        score += 0.12
        reasons.append("Bangumi 作为番剧主数据源")
    if candidate.source == "tmdb":
        score += 0.04
        reasons.append("TMDB 可辅助 Plex 命名")

    candidate_year = year_from_date(candidate.air_date)
    if year and candidate_year == year:
        score += 0.12
        reasons.append("年份匹配")
    elif year and candidate_year and candidate_year != year:
        score -= 0.08
        reasons.append("年份不同")

    if candidate.total_episodes:
        score += 0.03
        reasons.append("包含集数信息")
    if candidate.external_ids:
        score += 0.03
        reasons.append("包含外部 ID")
    if candidate.rating:
        score += min(candidate.rating / 100, 0.05)

    candidate.match_score = round(max(0.0, min(score, 1.0)), 3)
    candidate.match_reason = reasons
    return candidate


def sort_candidates(candidates: list[MetadataCandidate]) -> list[MetadataCandidate]:
    return sorted(
        candidates,
        key=lambda item: (
            item.match_score or 0,
            1 if item.source == "bangumi" else 0,
            item.rating or 0,
        ),
        reverse=True,
    )


def suggest_mapping(candidate: MetadataCandidate | None) -> PlexSeasonMapping | None:
    if candidate is None:
        return None
    year = year_from_date(candidate.air_date)
    return PlexSeasonMapping(
        subject_key=candidate_key(candidate),
        show_name=candidate.title,
        show_year=year,
        season_number=candidate.season_number or 1,
        episode_offset=0,
    )


def merge_summary(candidates: list[MetadataCandidate], recommended: MetadataCandidate | None) -> str | None:
    if recommended is None:
        return None
    sources = {candidate.source for candidate in candidates}
    if "bangumi" in sources and "tmdb" in sources:
        return "建议以 Bangumi 作为番剧身份来源；TMDB 候选可补充 Plex 命名、季、集数和外部 ID 信息。"
    if recommended.source == "bangumi":
        return "建议将 Bangumi 候选作为主要番剧元数据绑定。"
    return "TMDB 候选可用于 Plex 命名和季信息，请人工确认后再绑定。"


async def search_metadata(request: MetadataSearchRequest) -> MetadataSearchResponse:
    candidates: list[MetadataCandidate] = []
    warnings: list[str] = []
    tasks = []
    if "bangumi" in request.sources and request.media_type != "movie":
        tasks.append(("bangumi", BangumiAdapter().search(request.query, request.year, request.media_type)))
    elif "bangumi" in request.sources:
        warnings.append("电影类型请使用 TMDB 搜索；Bangumi 搜索未按电影类型筛选。")
    if "tmdb" in request.sources:
        tasks.append(("tmdb", TMDBAdapter().search(request.query, request.year, request.media_type)))

    results = await asyncio.gather(*(task for _, task in tasks), return_exceptions=True)
    for (source, _), result in zip(tasks, results, strict=False):
        if isinstance(result, Exception):
            warnings.append(f"{source}: {describe_metadata_error(result)}")
        else:
            candidates.extend(result)
    candidates = sort_candidates([score_candidate(candidate, request.query, request.year) for candidate in candidates])
    recommended = candidates[0] if candidates else None
    return MetadataSearchResponse(
        candidates=candidates,
        warnings=warnings,
        recommended_candidate_id=candidate_key(recommended) if recommended else None,
        suggested_mapping=suggest_mapping(recommended),
        merge_summary=merge_summary(candidates, recommended),
    )


async def match_metadata_title(
    title: str, year: int | None = None, *, media_type: str = "anime"
) -> MetadataSearchResponse:
    parsed = parse_title(title)
    query = parsed.title or title
    response = await search_metadata(MetadataSearchRequest(query=query, year=year, media_type=media_type))
    response.parsed_title = parsed
    return response
