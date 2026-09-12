from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Iterable
from urllib.parse import quote, unquote, urlsplit
from xml.etree import ElementTree

import httpx

from app.playlists.models import (
    PlexEpisode,
    PlexLibrary,
    PlexPlaylistDetail,
    PlexPlaylistItem,
    PlexPlaylistSummary,
    PlexSeason,
    PlexShow,
    PlexShowHierarchy,
)


class PlexError(RuntimeError):
    pass


MAX_ARTWORK_BYTES = 12 * 1024 * 1024
SUPPORTED_ARTWORK_TYPES = {"image/jpeg", "image/png", "image/webp"}
SUPPORTED_ARTWORK_PATH_PREFIXES = ("/playlists/", "/library/metadata/")


def _int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def _timestamp(value: str | None) -> datetime | None:
    number = _int(value)
    return datetime.fromtimestamp(number, timezone.utc) if number is not None else None


def _xml(content: bytes) -> ElementTree.Element:
    try:
        return ElementTree.fromstring(content)
    except ElementTree.ParseError as exc:
        raise PlexError("Plex Server 返回了无法识别的数据。") from exc


def _guids(element: ElementTree.Element) -> list[str]:
    values = [child.attrib.get("id", "").strip() for child in element.findall("Guid")]
    direct = element.attrib.get("guid", "").strip()
    if direct:
        values.append(direct)
    return list(dict.fromkeys(value for value in values if value))


def _parse_shows(
    root: ElementTree.Element,
    library_id: str,
    library_title: str | None,
) -> list[PlexShow]:
    result: list[PlexShow] = []
    for element in root:
        if element.attrib.get("type") != "show":
            continue
        rating_key = element.attrib.get("ratingKey", "").strip()
        title = element.attrib.get("title", "").strip()
        if not rating_key or not title:
            continue
        result.append(
            PlexShow(
                rating_key=rating_key,
                title=title,
                original_title=element.attrib.get("originalTitle") or None,
                year=_int(element.attrib.get("year")),
                library_id=library_id,
                library_title=library_title,
                guids=_guids(element),
                season_count=_int(element.attrib.get("childCount")),
            )
        )
    return result


def _parse_playlists(root: ElementTree.Element) -> list[PlexPlaylistSummary]:
    result: list[PlexPlaylistSummary] = []
    for element in root:
        if element.tag != "Playlist" or element.attrib.get("playlistType", "video") != "video":
            continue
        key = element.attrib.get("ratingKey", "").strip()
        title = element.attrib.get("title", "").strip()
        if key and title:
            artwork_path = (
                element.attrib.get("thumb", "").strip()
                or element.attrib.get("composite", "").strip()
            )
            result.append(
                PlexPlaylistSummary(
                    rating_key=key,
                    title=title,
                    item_count=_int(element.attrib.get("leafCount")) or 0,
                    duration_ms=_int(element.attrib.get("duration")),
                    updated_at=_timestamp(element.attrib.get("updatedAt")),
                    artwork_path=artwork_path or None,
                )
            )
    return sorted(
        result,
        key=lambda item: item.updated_at or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )


def _parse_playlist_items(root: ElementTree.Element) -> list[PlexPlaylistItem]:
    items: list[PlexPlaylistItem] = []
    for element in root:
        key = element.attrib.get("ratingKey", "").strip()
        if not key:
            continue
        items.append(
            PlexPlaylistItem(
                rating_key=key,
                title=element.attrib.get("title", "").strip() or "未命名剧集",
                show_title=element.attrib.get("grandparentTitle") or None,
                season_number=_int(element.attrib.get("parentIndex")),
                episode_number=_int(element.attrib.get("index")),
                duration_ms=_int(element.attrib.get("duration")),
                artwork_path=(
                    element.attrib.get("grandparentThumb", "").strip()
                    or element.attrib.get("parentThumb", "").strip()
                    or None
                ),
            )
        )
    return items


class PlexClient:
    def __init__(
        self,
        server_url: str,
        token: str,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.server_url = server_url.rstrip("/")
        self.token = token
        self.transport = transport

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/xml",
            "X-Plex-Token": self.token,
            "X-Plex-Client-Identifier": "kisetsu-playlists",
            "X-Plex-Product": "Kisetsu",
        }

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str | int] | None = None,
    ) -> ElementTree.Element:
        try:
            async with httpx.AsyncClient(
                base_url=self.server_url,
                timeout=15,
                headers=self._headers(),
                follow_redirects=False,
                trust_env=False,
                transport=self.transport,
            ) as client:
                response = await client.request(method, path, params=params)
            if response.status_code in {401, 403}:
                raise PlexError("Plex Server 拒绝访问，请检查 Token。")
            if response.status_code == 404:
                raise PlexError("Plex 中对应的媒体项目已不存在。")
            response.raise_for_status()
            return await asyncio.to_thread(_xml, response.content)
        except PlexError:
            raise
        except httpx.TimeoutException as exc:
            raise PlexError("连接 Plex Server 超时。") from exc
        except httpx.HTTPError as exc:
            raise PlexError("无法连接 Plex Server，请检查地址和服务状态。") from exc

    async def artwork(self, path: str) -> tuple[bytes, str]:
        cleaned = path.strip()
        parsed = urlsplit(cleaned)
        decoded_path = unquote(parsed.path)
        segments = [segment for segment in decoded_path.split("/") if segment]
        if (
            parsed.scheme
            or parsed.netloc
            or parsed.fragment
            or parsed.query
            or not decoded_path.startswith(SUPPORTED_ARTWORK_PATH_PREFIXES)
            or any(segment in {".", ".."} for segment in segments)
        ):
            raise PlexError("Plex 播放列表封面路径无效。")
        try:
            async with httpx.AsyncClient(
                base_url=self.server_url,
                timeout=15,
                headers={**self._headers(), "Accept": "image/jpeg,image/png,image/webp"},
                follow_redirects=False,
                trust_env=False,
                transport=self.transport,
            ) as client:
                async with client.stream("GET", cleaned) as response:
                    if response.status_code in {401, 403}:
                        raise PlexError("Plex Server 拒绝访问，请检查 Token。")
                    if response.status_code == 404:
                        raise PlexError("Plex 播放列表封面已不存在。")
                    response.raise_for_status()
                    content_type = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
                    if content_type not in SUPPORTED_ARTWORK_TYPES:
                        raise PlexError("Plex Server 返回的播放列表封面格式不受支持。")
                    content_length = _int(response.headers.get("content-length"))
                    if content_length is not None and content_length > MAX_ARTWORK_BYTES:
                        raise PlexError("Plex 播放列表封面超过缓存大小上限。")
                    content = bytearray()
                    async for chunk in response.aiter_bytes():
                        if len(content) + len(chunk) > MAX_ARTWORK_BYTES:
                            raise PlexError("Plex 播放列表封面超过缓存大小上限。")
                        content.extend(chunk)
                    return bytes(content), content_type
        except PlexError:
            raise
        except httpx.TimeoutException as exc:
            raise PlexError("读取 Plex 播放列表封面超时。") from exc
        except httpx.HTTPError as exc:
            raise PlexError("无法读取 Plex 播放列表封面。") from exc

    async def identity(self) -> tuple[str, str | None]:
        root = await self._request("GET", "/identity")
        machine_id = root.attrib.get("machineIdentifier", "").strip()
        if not machine_id:
            raise PlexError("Plex Server 未返回稳定服务器标识。")
        return machine_id, root.attrib.get("version")

    async def libraries(self) -> list[PlexLibrary]:
        root = await self._request("GET", "/library/sections")
        result: list[PlexLibrary] = []
        for element in root:
            key = element.attrib.get("key", "").strip()
            title = element.attrib.get("title", "").strip()
            media_type = element.attrib.get("type", "").strip()
            if key and title:
                result.append(PlexLibrary(id=key, title=title, type=media_type))
        return result

    async def shows(self, library_id: str, library_title: str | None = None) -> list[PlexShow]:
        root = await self._request(
            "GET",
            f"/library/sections/{quote(library_id, safe='')}/all",
            params={"type": 2, "includeGuids": 1},
        )
        return await asyncio.to_thread(_parse_shows, root, library_id, library_title)

    async def hierarchy(self, show: PlexShow) -> PlexShowHierarchy:
        root = await self._request("GET", f"/library/metadata/{quote(show.rating_key, safe='')}/children")
        seasons: list[PlexSeason] = []
        for element in root:
            if element.attrib.get("type") != "season":
                continue
            rating_key = element.attrib.get("ratingKey", "").strip()
            season_number = _int(element.attrib.get("index"))
            if not rating_key or season_number is None:
                continue
            episode_root = await self._request(
                "GET",
                f"/library/metadata/{quote(rating_key, safe='')}/children",
            )
            episodes: list[PlexEpisode] = []
            for episode in episode_root:
                if episode.attrib.get("type") != "episode":
                    continue
                episode_key = episode.attrib.get("ratingKey", "").strip()
                episode_number = _int(episode.attrib.get("index"))
                if not episode_key or episode_number is None:
                    continue
                episodes.append(
                    PlexEpisode(
                        rating_key=episode_key,
                        title=episode.attrib.get("title", "").strip() or f"第 {episode_number} 集",
                        season_number=season_number,
                        episode_number=episode_number,
                        duration_ms=_int(episode.attrib.get("duration")),
                        playable=episode.attrib.get("deletedAt") is None,
                    )
                )
            episodes.sort(key=lambda item: item.episode_number)
            seasons.append(
                PlexSeason(
                    rating_key=rating_key,
                    title=element.attrib.get("title", "").strip() or f"第 {season_number} 季",
                    season_number=season_number,
                    episodes=episodes,
                )
            )
        seasons.sort(key=lambda item: item.season_number)
        return PlexShowHierarchy(show=show, seasons=seasons)

    async def episodes(self, rating_keys: Iterable[str]) -> dict[str, PlexEpisode]:
        keys = list(dict.fromkeys(str(key).strip() for key in rating_keys if str(key).strip()))
        result: dict[str, PlexEpisode] = {}
        for offset in range(0, len(keys), 100):
            batch = keys[offset:offset + 100]
            encoded = ",".join(quote(key, safe="") for key in batch)
            root = await self._request("GET", f"/library/metadata/{encoded}")
            for element in root:
                if element.attrib.get("type") != "episode":
                    continue
                rating_key = element.attrib.get("ratingKey", "").strip()
                season_number = _int(element.attrib.get("parentIndex"))
                episode_number = _int(element.attrib.get("index"))
                if not rating_key or season_number is None or episode_number is None:
                    continue
                result[rating_key] = PlexEpisode(
                    rating_key=rating_key,
                    title=element.attrib.get("title", "").strip() or f"第 {episode_number} 集",
                    season_number=season_number,
                    episode_number=episode_number,
                    duration_ms=_int(element.attrib.get("duration")),
                    playable=element.attrib.get("deletedAt") is None,
                )
        return result

    async def playlists(self) -> list[PlexPlaylistSummary]:
        root = await self._request("GET", "/playlists", params={"playlistType": "video"})
        return await asyncio.to_thread(_parse_playlists, root)

    async def playlist_detail(self, summary: PlexPlaylistSummary) -> PlexPlaylistDetail:
        root = await self._request("GET", f"/playlists/{quote(summary.rating_key, safe='')}/items")
        items = await asyncio.to_thread(_parse_playlist_items, root)
        return PlexPlaylistDetail(playlist=summary.model_copy(update={"item_count": len(items)}), items=items)

    async def create_playlist(
        self,
        *,
        title: str,
        machine_identifier: str,
        rating_keys: Iterable[str],
    ) -> PlexPlaylistSummary:
        keys = list(dict.fromkeys(str(key).strip() for key in rating_keys if str(key).strip()))
        if not keys:
            raise PlexError("播放列表没有可创建的剧集。")
        uri = (
            f"server://{machine_identifier}/com.plexapp.plugins.library/"
            f"library/metadata/{','.join(keys)}"
        )
        root = await self._request(
            "POST",
            "/playlists",
            params={"type": "video", "title": title, "smart": 0, "uri": uri},
        )
        element = next((value for value in root if value.tag == "Playlist"), None)
        if element is None:
            raise PlexError("Plex 未确认播放列表创建结果。")
        return PlexPlaylistSummary(
            rating_key=element.attrib.get("ratingKey", "").strip(),
            title=element.attrib.get("title", "").strip() or title,
            item_count=_int(element.attrib.get("leafCount")) or len(keys),
            duration_ms=_int(element.attrib.get("duration")),
            updated_at=_timestamp(element.attrib.get("updatedAt")),
            artwork_path=(
                element.attrib.get("thumb", "").strip()
                or element.attrib.get("composite", "").strip()
                or None
            ),
        )
