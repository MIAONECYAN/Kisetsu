from __future__ import annotations

from typing import Any

import httpx

from app.metadata.base import BaseMetadataAdapter, MetadataAdapterError
from app.models import MetadataCandidate, TMDBSeasonOption
from app.settings import tmdb_api_key


class TMDBAdapter(BaseMetadataAdapter):
    source = "tmdb"
    base_url = "https://api.themoviedb.org/3"
    image_base_url = "https://image.tmdb.org/t/p/w500"

    async def search(self, query: str, year: int | None = None, media_type: str = "anime") -> list[MetadataCandidate]:
        resource_type = "movie" if media_type == "movie" else "tv"
        api_key = tmdb_api_key()
        if not api_key:
            raise MetadataAdapterError("TMDB_API_KEY 未配置，已跳过 TMDB 搜索")
        params: dict[str, Any] = {
            "api_key": api_key,
            "query": query,
            "include_adult": "false",
            "language": "zh-CN",
        }
        if year:
            params["year" if resource_type == "movie" else "first_air_date_year"] = year
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(f"{self.base_url}/search/{resource_type}", params=params)
            response.raise_for_status()
            data = response.json()
            details = await self.fetch_details(client, data.get("results", [])[:5], api_key, resource_type)
        return [
            self.normalize_title(details.get(str(item.get("id"))) or item, resource_type)
            for item in data.get("results", [])
        ]

    async def fetch_details(
        self,
        client: httpx.AsyncClient,
        results: list[dict[str, Any]],
        api_key: str,
        media_type: str = "tv",
    ) -> dict[str, dict[str, Any]]:
        details: dict[str, dict[str, Any]] = {}
        for item in results:
            item_id = item.get("id")
            if not item_id:
                continue
            response = await client.get(
                f"{self.base_url}/{media_type}/{item_id}",
                params={
                    "api_key": api_key,
                    "language": "zh-CN",
                    "append_to_response": "external_ids",
                },
            )
            if response.status_code >= 400:
                continue
            detail = response.json()
            merged = dict(item)
            merged.update(detail)
            details[str(item_id)] = merged
        return details

    async def seasons(self, series_id: int) -> list[TMDBSeasonOption]:
        detail = await self._series_detail(series_id)
        return [
            TMDBSeasonOption(
                season_number=season["season_number"],
                name=season.get("name") or f"第 {season['season_number']} 季",
                episode_count=season.get("episode_count"),
            )
            for season in detail.get("seasons", [])
            if isinstance(season.get("season_number"), int) and season["season_number"] > 0
        ]

    async def season_candidate(self, series_id: int, season_number: int) -> MetadataCandidate:
        if season_number <= 0:
            raise ValueError("该剧集没有所选季度")
        detail = await self._series_detail(series_id)
        if not any(season.get("season_number") == season_number for season in detail.get("seasons", [])):
            raise ValueError("该剧集没有所选季度")
        api_key = tmdb_api_key()
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(
                f"{self.base_url}/tv/{series_id}/season/{season_number}",
                params={"api_key": api_key, "language": "zh-CN"},
            )
            response.raise_for_status()
            season = response.json()
        episodes = season.get("episodes") or []
        summary = next(item for item in detail["seasons"] if item.get("season_number") == season_number)
        count = summary.get("episode_count") or season.get("episode_count") or len([
            episode for episode in episodes
            if isinstance(episode.get("episode_number"), int) and episode["episode_number"] > 0
        ]) or None
        candidate = self.normalize_title(detail)
        return candidate.model_copy(update={
            "season_number": season_number,
            "episode_count": count,
            "total_episodes": count,
            "episode_titles": self._episode_titles_from_season(season),
        })

    async def _series_detail(self, series_id: int) -> dict[str, Any]:
        api_key = tmdb_api_key()
        if not api_key:
            raise MetadataAdapterError("TMDB_API_KEY 未配置")
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(
                f"{self.base_url}/tv/{series_id}",
                params={"api_key": api_key, "language": "zh-CN", "append_to_response": "external_ids"},
            )
            response.raise_for_status()
            return response.json()

    def _episode_titles_from_season(self, item: dict[str, Any]) -> dict[str, str]:
        titles: dict[str, str] = {}
        for episode in item.get("episodes", []):
            number = episode.get("episode_number")
            title = str(episode.get("name") or "").strip()
            if number and title:
                titles[str(number)] = title
        return titles

    def normalize_title(self, item: dict[str, Any], media_type: str = "tv") -> MetadataCandidate:
        is_movie = media_type == "movie"
        title_key = "title" if is_movie else "name"
        original_title_key = "original_title" if is_movie else "original_name"
        poster_path = item.get("poster_path")
        backdrop_path = item.get("backdrop_path")
        external_ids = {
            key: str(value)
            for key, value in (item.get("external_ids") or {}).items()
            if value
        }
        return MetadataCandidate(
            source="tmdb",
            external_id=str(item.get("id")),
            media_type=media_type,
            title=item.get(title_key) or item.get(original_title_key) or "未命名条目",
            original_title=item.get(original_title_key),
            summary=item.get("overview") or None,
            poster_url=f"{self.image_base_url}{poster_path}" if poster_path else None,
            backdrop_url=f"{self.image_base_url}{backdrop_path}" if backdrop_path else None,
            air_date=item.get("release_date" if is_movie else "first_air_date") or None,
            total_episodes=None,
            episode_titles={},
            rating=item.get("vote_average"),
            season_number=None,
            episode_count=None,
            external_ids=external_ids,
            raw=item,
        )
