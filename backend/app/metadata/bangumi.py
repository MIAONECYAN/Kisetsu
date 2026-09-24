from __future__ import annotations

from typing import Any

import httpx

from app.metadata.base import BaseMetadataAdapter
from app.models import MetadataCandidate
from app.settings import bangumi_user_agent


def _positive_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float) and value.is_integer():
        parsed = int(value)
        return parsed if parsed > 0 else None
    if isinstance(value, str):
        try:
            parsed = int(value.strip())
        except ValueError:
            return None
        return parsed if parsed > 0 else None
    return None


def _infobox_episode_count(item: dict[str, Any]) -> int | None:
    for entry in item.get("infobox") or []:
        if not isinstance(entry, dict) or str(entry.get("key", "")).strip() != "话数":
            continue
        value = entry.get("value")
        if isinstance(value, list):
            value = next((part.get("v") for part in value if isinstance(part, dict) and part.get("v")), None)
        count = _positive_int(value)
        if count is not None:
            return count
    return None


def _chapter_number(chapter: dict[str, Any]) -> int | None:
    for key in ("sort", "ep", "episode_number", "number"):
        number = _positive_int(chapter.get(key))
        if number is not None:
            return number
    return None


def _chapter_type(chapter: dict[str, Any]) -> bool | None:
    if chapter.get("is_sp") is True or chapter.get("special") is True:
        return True
    for key in ("type", "episode_type", "kind"):
        value = chapter.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value != 0 if 0 <= value <= 6 else None
        normalized = str(value or "").strip().casefold()
        if normalized in {"sp", "special"}:
            return True
        if normalized in {"regular", "main", "normal"}:
            return False
        if normalized.isdigit():
            parsed = int(normalized)
            return parsed != 0 if 0 <= parsed <= 6 else None
    return None


def total_episodes_from_subject(item: dict[str, Any]) -> int | None:
    """Return a reliable Bangumi total without interpreting chapter titles."""
    for key in ("eps", "total_episodes", "eps_count"):
        count = _positive_int(item.get(key))
        if count is not None:
            return count
    infobox_count = _infobox_episode_count(item)
    if infobox_count is not None:
        return infobox_count

    chapters = item.get("episodes")
    if chapters is None:
        chapters = item.get("chapters")
    if isinstance(chapters, dict):
        chapters = chapters.get("data")
    if not isinstance(chapters, list) or not chapters:
        return None

    episode_numbers: set[int] = set()
    for chapter in chapters:
        if not isinstance(chapter, dict):
            return None
        special = _chapter_type(chapter)
        if special is None:
            return None
        if special:
            continue
        number = _chapter_number(chapter)
        if number is None:
            return None
        episode_numbers.add(number)
    return len(episode_numbers) or None


class BangumiAdapter(BaseMetadataAdapter):
    source = "bangumi"
    endpoint = "https://api.bgm.tv/v0/search/subjects"

    async def search(self, query: str, year: int | None = None, media_type: str = "anime") -> list[MetadataCandidate]:
        payload: dict[str, Any] = {
            "keyword": query,
            "sort": "match",
            "filter": {"type": [2]},
        }
        if year:
            payload["filter"]["air_date"] = [f">={year}-01-01", f"<={year}-12-31"]
        headers = {
            "User-Agent": bangumi_user_agent(),
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=15, headers=headers) as client:
            response = await client.post(self.endpoint, json=payload)
            response.raise_for_status()
            data = response.json()
        return [self.normalize_subject(item) for item in data.get("data", [])]

    def _episode_titles_from_raw(self, item: dict[str, Any]) -> dict[str, str]:
        existing = item.get("episode_titles")
        if isinstance(existing, dict):
            return {str(key): str(value) for key, value in existing.items() if value}
        titles: dict[str, str] = {}
        episodes = item.get("episodes")
        if not isinstance(episodes, list):
            return titles
        for episode in episodes:
            if not isinstance(episode, dict):
                continue
            number = episode.get("sort") or episode.get("ep") or episode.get("episode_number")
            title = episode.get("name_cn") or episode.get("name")
            if number and title:
                titles[str(number)] = str(title)
        return titles

    def normalize_subject(self, item: dict[str, Any]) -> MetadataCandidate:
        infobox = item.get("infobox") or []
        aliases: list[str] = []
        air_date = item.get("date")
        for entry in infobox:
            key = str(entry.get("key", ""))
            value = entry.get("value")
            if key in {"别名", "中文名"}:
                if isinstance(value, list):
                    aliases.extend(str(v.get("v", "")) for v in value if v.get("v"))
                elif value:
                    aliases.append(str(value))
            if key in {"放送开始", "上映年度"} and value:
                air_date = str(value)
        tags = []
        for tag in item.get("tags", []):
            name = tag.get("name")
            if not name:
                continue
            count = tag.get("count")
            tags.append(f"{name} {count}" if count is not None else str(name))
        rating = item.get("rating", {}).get("score") if isinstance(item.get("rating"), dict) else None
        return MetadataCandidate(
            source="bangumi",
            external_id=str(item.get("id")),
            title=item.get("name_cn") or item.get("name") or "未命名条目",
            original_title=item.get("name"),
            chinese_title=item.get("name_cn") or None,
            aliases=aliases,
            summary=item.get("summary") or None,
            poster_url=(item.get("images") or {}).get("large") or (item.get("images") or {}).get("common"),
            air_date=air_date,
            total_episodes=total_episodes_from_subject(item),
            episode_titles=self._episode_titles_from_raw(item),
            rating=rating,
            tags=tags,
            raw=item,
        )
