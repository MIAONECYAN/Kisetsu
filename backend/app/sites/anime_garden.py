from __future__ import annotations

from typing import Any
from urllib.parse import quote

from app.models import SearchResult
from app.sites.base import (
    BaseSiteAdapter,
    SiteAdapterError,
    bytes_to_size,
    clean_optional,
    coerce_int,
    stable_result_id,
)


class AnimeGardenAdapter(BaseSiteAdapter):
    """Adapter for Anime Garden's public resource API."""

    id = "animegarden"
    name = "Anime Garden"
    display_name = "Anime Garden"
    base_url = "https://api.animes.garden"
    primary_url = "https://api.animes.garden"
    supports_pagination = True
    default_page_size = 100
    max_recommended_pages = 10
    rss_default_path = "feed.xml"

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(
        self,
        keyword: str,
        page: int = 1,
        page_size: int = 30,
    ) -> tuple[list[SearchResult], bool]:
        normalized_keyword = keyword.strip()
        if not normalized_keyword:
            return [], False
        page = max(1, page)
        page_size = min(max(1, page_size), 1000)
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/resources",
            headers={"Accept": "application/json"},
            params={
                "page": page,
                "pageSize": page_size,
                "tracker": "true",
                "metadata": "true",
                "search": normalized_keyword,
            },
        )
        try:
            payload = response.json()
        except ValueError as exc:
            raise SiteAdapterError("Anime Garden 搜索响应不是有效 JSON，请稍后重试。") from exc
        resources, complete = self.parse_resources_response(payload)
        return [self.result_from_item(item) for item in resources], not complete

    @staticmethod
    def parse_resources_response(payload: Any) -> tuple[list[dict[str, Any]], bool]:
        if not isinstance(payload, dict):
            raise SiteAdapterError("Anime Garden 搜索响应格式异常，请稍后重试。")
        if payload.get("ok") is False:
            raise SiteAdapterError("Anime Garden 搜索失败，请稍后重试。")
        status = str(payload.get("status") or "OK").upper()
        if status not in {"OK", "SUCCESS"}:
            raise SiteAdapterError(str(payload.get("message") or "Anime Garden 搜索失败，请稍后重试。"))
        resources = payload.get("resources")
        pagination = payload.get("pagination")
        if not isinstance(resources, list) or not isinstance(pagination, dict):
            raise SiteAdapterError("Anime Garden 搜索响应缺少资源或分页信息，请稍后重试。")
        if any(not isinstance(item, dict) for item in resources):
            raise SiteAdapterError("Anime Garden 搜索响应包含无效资源，请稍后重试。")
        complete = pagination.get("complete")
        if not isinstance(complete, bool):
            raise SiteAdapterError("Anime Garden 搜索响应中的分页状态无效，请稍后重试。")
        if not resources and not complete:
            raise SiteAdapterError("Anime Garden 搜索返回空页但仍声明有后续结果，请稍后重试。")
        return resources, complete

    @classmethod
    def result_from_item(cls, item: dict[str, Any]) -> SearchResult:
        title = clean_optional(item.get("title")) or "未命名资源"
        source_url = clean_optional(item.get("href"))
        provider = clean_optional(item.get("provider"))
        provider_id = clean_optional(item.get("providerId"))
        detail_url = (
            f"https://animes.garden/detail/{quote(provider, safe='')}/{quote(provider_id, safe='')}"
            if provider and provider_id and provider not in {".", ".."} and provider_id not in {".", ".."}
            else None
        )
        magnet_url = clean_optional(item.get("magnet"))
        fansub = item.get("fansub")
        fansub_name = clean_optional(fansub.get("name")) if isinstance(fansub, dict) else None
        subject_id = item.get("subjectId")
        bangumi_id = str(subject_id) if subject_id not in (None, "") else None
        metadata = item.get("metadata")
        parsed = metadata.get("anipar") if isinstance(metadata, dict) else None
        parsed = parsed if isinstance(parsed, dict) else {}
        parsed_fansub_data = parsed.get("fansub")
        parsed_fansub_name = clean_optional(parsed_fansub_data.get("name")) if isinstance(parsed_fansub_data, dict) else None
        episode = parsed.get("episode") if isinstance(parsed.get("episode"), dict) else {}
        episodes_range = parsed.get("episodesRange") if isinstance(parsed.get("episodesRange"), dict) else {}
        file_info = parsed.get("file") if isinstance(parsed.get("file"), dict) else {}
        video = file_info.get("video") if isinstance(file_info.get("video"), dict) else {}
        subtitle = parsed.get("subtitle") if isinstance(parsed.get("subtitle"), dict) else {}
        season = parsed.get("season") if isinstance(parsed.get("season"), dict) else {}
        resource_type = clean_optional(parsed.get("type") or item.get("type"))
        episode_number = coerce_int(episode.get("number"))
        episode_start = coerce_int(episodes_range.get("from"))
        episode_end = coerce_int(episodes_range.get("to"))
        if episode_start is None:
            episode_start = episode_number
        if episode_end is None:
            episode_end = episode_number
        is_range = bool(episodes_range) and episode_end is not None and episode_start is not None and episode_end > episode_start
        is_collection = resource_type in {"合集", "collection", "batch"} or is_range
        display_episode = None
        if is_range and episode_start is not None and episode_end is not None:
            display_episode = f"第 {episode_start}-{episode_end} 集"
        elif episode_number is not None:
            display_episode = f"第 {episode_number} 集"
        subtitle_languages = subtitle.get("languages")
        if isinstance(subtitle_languages, list):
            parsed_subtitle_language = " / ".join(str(value).strip() for value in subtitle_languages if str(value).strip()) or None
        else:
            parsed_subtitle_language = clean_optional(subtitle_languages)
        size_bytes = coerce_int(item.get("size"))
        return SearchResult(
            id=stable_result_id(cls.id, title, magnet_url, detail_url or source_url),
            title=title,
            published_at=clean_optional(item.get("createdAt")),
            size=bytes_to_size(item.get("size")),
            size_bytes=size_bytes,
            category=clean_optional(item.get("type")),
            magnet_url=magnet_url,
            source=cls.id,
            detail_url=detail_url,
            source_url=source_url,
            bangumi_id=bangumi_id,
            normalized_title=clean_optional(parsed.get("title")),
            parsed_fansub=fansub_name or parsed_fansub_name,
            parsed_episode=episode_number if episode_number is not None else episode_start if is_range else None,
            parsed_episode_start=episode_start,
            parsed_episode_end=episode_end,
            parsed_resolution=clean_optional(video.get("resolution")),
            parsed_subtitle_language=parsed_subtitle_language,
            parsed_is_batch=is_collection,
            parsed_is_multi_episode=is_range,
            parsed_is_special=resource_type in {"OVA", "OAD", "SP", "special"},
            parsed_resource_type=resource_type,
            parsed_season_number=coerce_int(season.get("number")),
            parsed_part_number=coerce_int((parsed.get("part") or {}).get("number")) if isinstance(parsed.get("part"), dict) else None,
            parsed_display_episode_label=display_episode,
            parsed_parse_reason="Anime Garden 结构化元数据" if parsed else None,
        )
