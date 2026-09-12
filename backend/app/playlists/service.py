from __future__ import annotations

import asyncio
import hashlib
import json
import os
import secrets
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

from app.db.store import Store
from app.playlists.bangumi_data import CACHE_ROOT, BangumiDataError, BangumiDataService
from app.playlists.matcher import build_match_index, decide_match, search_shows
from app.playlists.models import (
    DEFAULT_BANGUMI_DATA_CDN,
    PairingRequest,
    PlaylistCreatePreviewItem,
    PlaylistCreatePreviewRequest,
    PlaylistCreatePreviewResponse,
    PlaylistCreateRequest,
    PlaylistCreateResponse,
    PlaylistQuarterItem,
    PlaylistQuarterOption,
    PlaylistQuarterResponse,
    PlaylistSettingsResponse,
    PlaylistSettingsUpdate,
    PlexConnectionResponse,
    PlexPairing,
    PlexPlaylistDetail,
    PlexPlaylistSummary,
    PlexShow,
    PlexShowHierarchy,
)
from app.playlists.plex_client import PlexClient, PlexError
from app.services.mikan_project import fetch_bangumi_subject
from app.settings import bangumi_user_agent, mask_secret


SETTINGS_KEY = "playlist_settings"
POSTER_ROOT = CACHE_ROOT / "posters"
PLEX_PLAYLIST_POSTER_ROOT = CACHE_ROOT / "plex-playlist-posters"
PLEX_PLAYLIST_ITEM_POSTER_ROOT = CACHE_ROOT / "plex-playlist-item-posters"
SUBJECT_ROOT = CACHE_ROOT / "subjects"
PREVIEW_TTL = timedelta(minutes=10)


class PlaylistServiceError(RuntimeError):
    def __init__(self, message: str, *, status_code: int = 422):
        super().__init__(message)
        self.status_code = status_code


def _subject_aliases(subject: dict[str, Any]) -> list[str]:
    values: list[str] = []
    for key in ("name", "name_cn"):
        value = subject.get(key)
        if isinstance(value, str) and value.strip():
            values.append(value.strip())
    for entry in subject.get("infobox") or []:
        if not isinstance(entry, dict) or str(entry.get("key") or "").strip() not in {"别名", "中文名"}:
            continue
        value = entry.get("value")
        if isinstance(value, list):
            for item in value:
                candidate = item.get("v") if isinstance(item, dict) else item
                if candidate and str(candidate).strip():
                    values.append(str(candidate).strip())
        elif value and str(value).strip():
            values.append(str(value).strip())
    return list(dict.fromkeys(values))


class PlaylistService:
    def __init__(
        self,
        store: Store,
        *,
        data_service: BangumiDataService | None = None,
        plex_factory: Callable[[str, str], PlexClient] | None = None,
    ):
        self.store = store
        self.data_service = data_service or BangumiDataService()
        self.plex_factory = plex_factory or (lambda url, token: PlexClient(url, token))
        self._shows_cache: dict[tuple[str, str], tuple[datetime, list[PlexShow]]] = {}
        self._hierarchy_cache: dict[tuple[str, str], tuple[datetime, PlexShowHierarchy]] = {}
        self._previews: dict[str, dict[str, Any]] = {}
        self._poster_locks: dict[str, asyncio.Lock] = {}
        self._playlist_artwork_sources: dict[str, tuple[str, str]] = {}
        self._playlist_poster_locks: dict[str, asyncio.Lock] = {}
        self._playlist_item_artwork_sources: dict[tuple[str, str], tuple[str, str]] = {}
        self._playlist_item_poster_locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._quarter_tasks: dict[tuple[Any, ...], asyncio.Task[PlaylistQuarterResponse]] = {}
        self._quarter_task_lock = asyncio.Lock()
        self._quarter_match_semaphore = asyncio.Semaphore(1)

    def _settings(self) -> dict[str, Any]:
        value = self.store.get_runtime_config(SETTINGS_KEY) or {}
        return {
            "server_url": str(value.get("server_url") or ""),
            "token": str(value.get("token") or ""),
            "library_id": str(value.get("library_id") or "") or None,
            "library_title": str(value.get("library_title") or "") or None,
            "machine_identifier": str(value.get("machine_identifier") or "") or None,
            "cdn_url": str(value.get("cdn_url") or DEFAULT_BANGUMI_DATA_CDN),
        }

    def settings(self) -> PlaylistSettingsResponse:
        value = self._settings()
        return PlaylistSettingsResponse(
            server_url=value["server_url"],
            token_configured=bool(value["token"]),
            token_masked=mask_secret(value["token"]),
            library_id=value["library_id"],
            library_title=value["library_title"],
            cdn_url=value["cdn_url"],
        )

    def update_settings(self, payload: PlaylistSettingsUpdate) -> PlaylistSettingsResponse:
        current = self._settings()
        token = "" if payload.clear_token else (payload.token if payload.token is not None else current["token"])
        changed_server = payload.server_url != current["server_url"]
        changed_library = payload.library_id != current["library_id"]
        saved = {
            "server_url": payload.server_url,
            "token": token,
            "library_id": payload.library_id,
            "library_title": None if changed_library else current["library_title"],
            "machine_identifier": None if changed_server else current["machine_identifier"],
            "cdn_url": payload.cdn_url,
        }
        self.store.set_runtime_config(SETTINGS_KEY, saved)
        self._shows_cache.clear()
        self._hierarchy_cache.clear()
        return self.settings()

    def _client(self) -> PlexClient:
        return self._client_for_settings(self._settings())

    def _client_for_settings(self, settings: dict[str, Any]) -> PlexClient:
        if not settings["server_url"] or not settings["token"]:
            raise PlaylistServiceError("请先在设置中填写 Plex Server 地址和 Token。", status_code=409)
        return self.plex_factory(settings["server_url"], settings["token"])

    async def test_connection(self) -> PlexConnectionResponse:
        client = self._client()
        try:
            machine_identifier, version = await client.identity()
            libraries = await client.libraries()
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        settings = self._settings()
        if settings["machine_identifier"] and settings["machine_identifier"] != machine_identifier:
            self._shows_cache.clear()
            self._hierarchy_cache.clear()
        selected = next((item for item in libraries if item.id == settings["library_id"]), None)
        settings["machine_identifier"] = machine_identifier
        settings["library_title"] = selected.title if selected else None
        self.store.set_runtime_config(SETTINGS_KEY, settings)
        return PlexConnectionResponse(
            ok=True,
            message="Plex Server 连接正常。",
            version=version,
            machine_identifier=machine_identifier,
            libraries=libraries,
        )

    async def quarter_options(self, *, force: bool = False) -> list[PlaylistQuarterOption]:
        settings = self._settings()
        loaded = await self.data_service.load(settings["cdn_url"], force=force)
        return await asyncio.to_thread(self.data_service.quarter_options, loaded)

    async def quarter(self, year: int, month: int, *, force: bool = False) -> PlaylistQuarterResponse:
        settings = self._settings()
        task_key = (
            year,
            month,
            force,
            settings["server_url"],
            hashlib.sha256(settings["token"].encode("utf-8")).digest()[:8],
            settings["library_id"],
            settings["cdn_url"],
        )
        async with self._quarter_task_lock:
            task = self._quarter_tasks.get(task_key)
            if task is None:
                task = asyncio.create_task(self._load_quarter(year, month, force=force, settings=settings))
                self._quarter_tasks[task_key] = task

                def remove_finished(completed: asyncio.Task[PlaylistQuarterResponse]) -> None:
                    if self._quarter_tasks.get(task_key) is completed:
                        self._quarter_tasks.pop(task_key, None)

                task.add_done_callback(remove_finished)
        return await asyncio.shield(task)

    async def _load_quarter(
        self,
        year: int,
        month: int,
        *,
        force: bool,
        settings: dict[str, Any],
    ) -> PlaylistQuarterResponse:
        loaded = await self.data_service.load(settings["cdn_url"], force=force)
        response = await asyncio.to_thread(self._quarter_response, loaded, year, month)
        if not settings["server_url"] or not settings["token"] or not settings["library_id"]:
            return response
        try:
            shows, machine_id = await self._shows(settings=settings)
        except PlaylistServiceError as exc:
            return response.model_copy(update={
                "warning": "；".join(value for value in [response.warning, str(exc)] if value),
            })
        async with self._quarter_match_semaphore:
            pairing_values = await asyncio.to_thread(
                self.store.list_playlist_pairings,
                machine_id,
                settings["library_id"],
            )
            pairing_rows = {row["item_key"]: row for row in pairing_values}
            return await asyncio.to_thread(
                self._resolve_quarter_items,
                response,
                shows,
                machine_id,
                settings["library_id"],
                pairing_rows,
            )

    def _quarter_response(
        self,
        loaded: Any,
        year: int,
        month: int,
    ) -> PlaylistQuarterResponse:
        return self._merge_cached_subject_aliases(self.data_service.quarter(loaded, year, month))

    def _resolve_quarter_items(
        self,
        response: PlaylistQuarterResponse,
        shows: list[PlexShow],
        machine_id: str,
        library_id: str,
        pairing_rows: dict[str, dict[str, Any]],
    ) -> PlaylistQuarterResponse:
        show_index = {show.rating_key: show for show in shows}
        match_index = build_match_index(shows)
        resolved: list[PlaylistQuarterItem] = []
        pending_pairings: list[dict[str, Any]] = []
        for item in response.items:
            row = pairing_rows.get(item.key)
            if row:
                if row["source"] == "dismissed":
                    resolved.append(item.model_copy(update={
                        "match_state": "unmatched",
                        "match_reason": "已取消配对，等待手动配对或重新自动匹配。",
                    }))
                    continue
                show = show_index.get(row["plex_rating_key"])
                if show:
                    pairing = PlexPairing(
                        item_key=item.key,
                        plex_rating_key=show.rating_key,
                        title=show.title,
                        year=show.year,
                        source=row["source"],
                        score=float(row["score"]),
                        reason=row["reason"],
                        updated_at=row["updated_at"],
                    )
                    resolved.append(item.model_copy(update={"pairing": pairing, "match_state": "matched", "match_reason": pairing.reason}))
                    continue
                resolved.append(item.model_copy(update={"match_state": "stale", "match_reason": "此前配对的 Plex 节目已不存在。"}))
                continue
            decision = decide_match(item, match_index)
            if decision.pairing:
                pairing = decision.pairing
                pending_pairings.append({
                    "item_key": item.key,
                    "machine_id": machine_id,
                    "library_id": library_id,
                    "plex_rating_key": pairing.plex_rating_key,
                    "source": pairing.source,
                    "score": pairing.score,
                    "reason": pairing.reason,
                    "data": {"title": pairing.title, "year": pairing.year},
                })
                resolved.append(item.model_copy(update={"pairing": pairing, "match_state": "matched", "match_reason": pairing.reason}))
            else:
                resolved.append(item.model_copy(update={"match_state": decision.state, "match_reason": decision.reason}))
        self.store.upsert_playlist_pairings(pending_pairings)
        return response.model_copy(update={"items": resolved})

    async def _shows(
        self,
        *,
        force: bool = False,
        settings: dict[str, Any] | None = None,
    ) -> tuple[list[PlexShow], str]:
        settings = settings or self._settings()
        library_id = settings["library_id"]
        if not library_id:
            raise PlaylistServiceError("请先选择 Plex 动画媒体库。", status_code=409)
        client = self._client_for_settings(settings)
        saved_machine_id = settings["machine_identifier"]
        cached = self._shows_cache.get((saved_machine_id, library_id)) if saved_machine_id else None
        if not force and cached and datetime.now(timezone.utc) - cached[0] < timedelta(minutes=5):
            return cached[1], saved_machine_id
        try:
            machine_id, _ = await client.identity()
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        if saved_machine_id != machine_id:
            self._shows_cache.clear()
            self._hierarchy_cache.clear()
            settings["machine_identifier"] = machine_id
            self.store.set_runtime_config(SETTINGS_KEY, settings)
        key = (machine_id, library_id)
        try:
            shows = await client.shows(library_id, settings["library_title"])
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        self._shows_cache[key] = (datetime.now(timezone.utc), shows)
        return shows, machine_id

    async def search_plex(self, query: str) -> list[PlexShow]:
        shows, _ = await self._shows()
        return search_shows(shows, query)

    async def pair(self, payload: PairingRequest) -> PlexPairing:
        shows, machine_id = await self._shows()
        settings = self._settings()
        show = next((value for value in shows if value.rating_key == payload.plex_rating_key), None)
        if not show:
            raise PlaylistServiceError("所选 Plex 节目已不存在。", status_code=404)
        pairing = PlexPairing(
            item_key=payload.item_key,
            plex_rating_key=show.rating_key,
            title=show.title,
            year=show.year,
            source="manual",
            score=1,
            reason="用户手动确认",
        )
        self.store.upsert_playlist_pairing(
            item_key=payload.item_key,
            machine_id=machine_id,
            library_id=settings["library_id"],
            plex_rating_key=show.rating_key,
            source="manual",
            score=1,
            reason=pairing.reason,
            data={"title": show.title, "year": show.year},
        )
        return pairing

    async def unpair(self, item_key: str) -> bool:
        _, machine_id = await self._shows()
        library_id = self._settings()["library_id"]
        self.store.upsert_playlist_pairing(
            item_key=item_key,
            machine_id=machine_id,
            library_id=library_id,
            plex_rating_key="",
            source="dismissed",
            score=0,
            reason="用户取消配对",
            data={},
        )
        return True

    async def rematch(self, item_key: str) -> bool:
        _, machine_id = await self._shows()
        library_id = self._settings()["library_id"]
        return self.store.delete_playlist_pairing(item_key, machine_id, library_id)

    async def hierarchy(self, rating_key: str) -> PlexShowHierarchy:
        shows, machine_id = await self._shows()
        show = next((value for value in shows if value.rating_key == rating_key), None)
        if not show:
            raise PlaylistServiceError("Plex 节目已不存在。", status_code=404)
        cache_key = (machine_id, rating_key)
        cached = self._hierarchy_cache.get(cache_key)
        if cached and datetime.now(timezone.utc) - cached[0] < timedelta(minutes=10):
            return cached[1]
        try:
            hierarchy = await self._client().hierarchy(show)
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        self._hierarchy_cache[cache_key] = (datetime.now(timezone.utc), hierarchy)
        return hierarchy

    async def playlists(self) -> list[PlexPlaylistSummary]:
        try:
            values = await self._client().playlists()
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        active_keys = {value.rating_key for value in values}
        self._playlist_artwork_sources = {
            key: source
            for key, source in self._playlist_artwork_sources.items()
            if key in active_keys
        }
        result: list[PlexPlaylistSummary] = []
        for value in values:
            artwork_path = value.artwork_path
            if not artwork_path:
                self._playlist_artwork_sources.pop(value.rating_key, None)
                result.append(value.model_copy(update={"poster_url": None}))
                continue
            version = (
                str(int(value.updated_at.timestamp()))
                if value.updated_at
                else hashlib.sha256(artwork_path.encode("utf-8")).hexdigest()[:12]
            )
            self._playlist_artwork_sources[value.rating_key] = (artwork_path, version)
            result.append(value.model_copy(update={
                "poster_url": (
                    f"/api/playlists/existing/{quote(value.rating_key, safe='')}/poster?v={version}"
                )
            }))
        return result

    async def playlist_detail(self, rating_key: str) -> PlexPlaylistDetail:
        summary = next((value for value in await self.playlists() if value.rating_key == rating_key), None)
        if not summary:
            raise PlaylistServiceError("播放列表已不存在。", status_code=404)
        try:
            detail = await self._client().playlist_detail(summary)
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        playlist_key = summary.rating_key
        active_item_keys = {item.rating_key for item in detail.items}
        self._playlist_item_artwork_sources = {
            key: source
            for key, source in self._playlist_item_artwork_sources.items()
            if key[0] != playlist_key or key[1] in active_item_keys
        }
        resolved_items = []
        for item in detail.items:
            artwork_path = item.artwork_path
            if not artwork_path:
                resolved_items.append(item.model_copy(update={"poster_url": None}))
                continue
            version = hashlib.sha256(artwork_path.encode("utf-8")).hexdigest()[:12]
            key = (playlist_key, item.rating_key)
            self._playlist_item_artwork_sources[key] = (artwork_path, version)
            resolved_items.append(item.model_copy(update={
                "poster_url": (
                    f"/api/playlists/existing/{quote(playlist_key, safe='')}"
                    f"/items/{quote(item.rating_key, safe='')}/poster?v={version}"
                )
            }))
        return detail.model_copy(update={"items": resolved_items})

    async def playlist_poster(self, rating_key: str) -> Path | None:
        cleaned = rating_key.strip()
        if not cleaned or len(cleaned) > 256:
            raise PlaylistServiceError("Plex 播放列表标识无效。", status_code=400)
        source = self._playlist_artwork_sources.get(cleaned)
        if not source:
            await self.playlists()
            source = self._playlist_artwork_sources.get(cleaned)
        if not source:
            return None
        artwork_path, version = source

        source_digest = hashlib.sha256(f"{artwork_path}\0{version}".encode("utf-8")).hexdigest()[:24]
        directory = PLEX_PLAYLIST_POSTER_ROOT / hashlib.sha256(cleaned.encode("utf-8")).hexdigest()[:24]

        def cached() -> Path | None:
            if not directory.is_dir():
                return None
            return next((
                path for path in directory.iterdir()
                if path.is_file()
                and path.stem == source_digest
                and path.suffix.lower() in {".jpg", ".png", ".webp"}
            ), None)

        existing = cached()
        if existing:
            return existing
        lock = self._playlist_poster_locks.setdefault(cleaned, asyncio.Lock())
        async with lock:
            existing = cached()
            if existing:
                return existing
            try:
                content, content_type = await self._client().artwork(artwork_path)
            except PlexError as exc:
                raise PlaylistServiceError(str(exc), status_code=502) from exc
            suffix = {
                "image/png": ".png",
                "image/webp": ".webp",
            }.get(content_type, ".jpg")
            target = directory / f"{source_digest}{suffix}"
            self._atomic(target, content)
            for stale in directory.iterdir():
                if stale != target and stale.is_file():
                    stale.unlink(missing_ok=True)
            return target

    async def playlist_item_poster(self, playlist_rating_key: str, item_rating_key: str) -> Path | None:
        playlist_key = playlist_rating_key.strip()
        item_key = item_rating_key.strip()
        if (
            not playlist_key
            or not item_key
            or len(playlist_key) > 256
            or len(item_key) > 256
            or "/" in playlist_key
            or "/" in item_key
        ):
            raise PlaylistServiceError("Plex 播放列表视频标识无效。", status_code=400)
        source_key = (playlist_key, item_key)
        source = self._playlist_item_artwork_sources.get(source_key)
        if not source:
            await self.playlist_detail(playlist_key)
            source = self._playlist_item_artwork_sources.get(source_key)
        if not source:
            return None
        artwork_path, version = source
        source_digest = hashlib.sha256(f"{artwork_path}\0{version}".encode("utf-8")).hexdigest()[:24]
        # Episodes from the same show share grandparentThumb; cache that poster once.
        directory = PLEX_PLAYLIST_ITEM_POSTER_ROOT / source_digest

        def cached() -> Path | None:
            if not directory.is_dir():
                return None
            return next((
                path for path in directory.iterdir()
                if path.is_file()
                and path.stem == source_digest
                and path.suffix.lower() in {".jpg", ".png", ".webp"}
            ), None)

        existing = cached()
        if existing:
            return existing
        lock = self._playlist_item_poster_locks.setdefault(("artwork", source_digest), asyncio.Lock())
        async with lock:
            existing = cached()
            if existing:
                return existing
            try:
                content, content_type = await self._client().artwork(artwork_path)
            except PlexError as exc:
                raise PlaylistServiceError(str(exc), status_code=502) from exc
            suffix = {"image/png": ".png", "image/webp": ".webp"}.get(content_type, ".jpg")
            target = directory / f"{source_digest}{suffix}"
            self._atomic(target, content)
            for stale in directory.iterdir():
                if stale != target and stale.is_file():
                    stale.unlink(missing_ok=True)
            return target

    async def preview(self, payload: PlaylistCreatePreviewRequest) -> PlaylistCreatePreviewResponse:
        quarter = await self.quarter(payload.year, payload.month)
        items = {item.key: item for item in quarter.items}
        preview_items: list[PlaylistCreatePreviewItem] = []
        warnings: list[str] = []
        seen_episodes: set[str] = set()
        for selection in payload.selections:
            anime = items.get(selection.item_key)
            if not anime:
                reason = "所选番组已不在当前季度数据中。"
                warnings.append(f"{selection.item_key} {reason}")
                preview_items.append(PlaylistCreatePreviewItem(
                    item_key=selection.item_key,
                    anime_title=selection.item_key,
                    valid=False,
                    reason=reason,
                ))
                continue
            if not anime.pairing:
                reason = "尚未有效配对 Plex 节目。"
                warnings.append(f"{anime.title} {reason}")
                preview_items.append(PlaylistCreatePreviewItem(
                    item_key=anime.key,
                    anime_title=anime.title,
                    valid=False,
                    reason=reason,
                ))
                continue
            hierarchy = await self.hierarchy(anime.pairing.plex_rating_key)
            episode = next(
                (
                    episode
                    for season in hierarchy.seasons
                    for episode in season.episodes
                    if episode.rating_key == selection.episode_rating_key
                ),
                None,
            )
            if not episode or not episode.playable:
                reason = "所选剧集不存在或不可播放。"
                warnings.append(f"{anime.title} {reason}")
                preview_items.append(PlaylistCreatePreviewItem(
                    item_key=anime.key,
                    anime_title=anime.title,
                    plex_show_title=hierarchy.show.title,
                    episode_rating_key=selection.episode_rating_key,
                    valid=False,
                    reason=reason,
                ))
                continue
            duplicate = episode.rating_key in seen_episodes
            seen_episodes.add(episode.rating_key)
            preview_items.append(
                PlaylistCreatePreviewItem(
                    item_key=anime.key,
                    anime_title=anime.title,
                    plex_show_title=hierarchy.show.title,
                    episode_rating_key=episode.rating_key,
                    season_number=episode.season_number,
                    episode_number=episode.episode_number,
                    episode_title=episode.title,
                    duplicate=duplicate,
                    valid=not duplicate,
                    reason="重复剧集已去重" if duplicate else None,
                )
            )
        unique_keys = [item.episode_rating_key for item in preview_items if item.valid and item.episode_rating_key]
        existing = await self.playlists()
        if any(value.title.casefold() == payload.title.casefold() for value in existing):
            warnings.append("Plex 中已存在同名播放列表，请修改名称。")
        can_create = bool(unique_keys) and not warnings
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc) + PREVIEW_TTL
        self._cleanup_previews()
        self._previews[token] = {
            "expires_at": expires_at,
            "title": payload.title,
            "rating_keys": unique_keys,
            "can_create": can_create,
        }
        return PlaylistCreatePreviewResponse(
            confirmation_token=token,
            expires_at=expires_at,
            title=payload.title,
            selected_count=len(payload.selections),
            episode_count=len(unique_keys),
            items=preview_items,
            warnings=warnings,
            can_create=can_create,
        )

    async def create(self, payload: PlaylistCreateRequest) -> PlaylistCreateResponse:
        if not payload.confirm:
            raise PlaylistServiceError("创建播放列表前需要明确确认。")
        self._cleanup_previews()
        preview = self._previews.pop(payload.confirmation_token, None)
        if not preview or preview["expires_at"] <= datetime.now(timezone.utc):
            raise PlaylistServiceError("创建预览已过期，请重新预览。", status_code=409)
        if not preview["can_create"]:
            raise PlaylistServiceError("预览中仍有未解决的问题，不能创建。", status_code=409)
        if any(value.title.casefold() == preview["title"].casefold() for value in await self.playlists()):
            raise PlaylistServiceError("Plex 中已存在同名播放列表，请重新预览并修改名称。", status_code=409)
        settings = self._settings()
        client = self._client()
        try:
            machine_id, _ = await client.identity()
            if settings["machine_identifier"] and settings["machine_identifier"] != machine_id:
                settings["machine_identifier"] = machine_id
                self.store.set_runtime_config(SETTINGS_KEY, settings)
                self._shows_cache.clear()
                self._hierarchy_cache.clear()
                raise PlaylistServiceError("Plex Server 身份已变化，请刷新配对并重新预览。", status_code=409)
            if not settings["machine_identifier"]:
                settings["machine_identifier"] = machine_id
                self.store.set_runtime_config(SETTINGS_KEY, settings)
            current_episodes = await client.episodes(preview["rating_keys"])
            missing = [key for key in preview["rating_keys"] if key not in current_episodes or not current_episodes[key].playable]
            if missing:
                raise PlaylistServiceError("预览中的剧集已不存在或不可播放，请重新预览。", status_code=409)
            playlist = await client.create_playlist(
                title=preview["title"],
                machine_identifier=machine_id,
                rating_keys=preview["rating_keys"],
            )
        except PlaylistServiceError:
            raise
        except PlexError as exc:
            raise PlaylistServiceError(str(exc), status_code=502) from exc
        return PlaylistCreateResponse(ok=True, message="播放列表已创建。", playlist=playlist)

    def _cleanup_previews(self) -> None:
        now = datetime.now(timezone.utc)
        self._previews = {
            key: value for key, value in self._previews.items()
            if value["expires_at"] > now
        }

    async def warm_posters(self, year: int, month: int) -> None:
        quarter = await self.quarter(year, month)
        semaphore = asyncio.Semaphore(4)

        async def warm(item: PlaylistQuarterItem) -> None:
            if not item.bangumi_id:
                return
            async with semaphore:
                try:
                    await self.cache_poster(item.key, item.bangumi_id)
                except Exception:
                    return

        await asyncio.gather(*(warm(item) for item in quarter.items))

    def cached_poster(self, item_key: str) -> Path | None:
        directory = POSTER_ROOT / hashlib.sha256(item_key.encode("utf-8")).hexdigest()[:24]
        if not directory.is_dir():
            return None
        return next((path for path in sorted(directory.iterdir()) if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}), None)

    async def poster(self, item_key: str) -> Path | None:
        cached = self.cached_poster(item_key)
        if cached:
            return cached
        # A stable Bangumi key carries the subject ID and avoids title guessing.
        if not item_key.startswith("bangumi:"):
            return None
        return await self.cache_poster(item_key, item_key.split(":", 1)[1])

    async def cache_poster(self, item_key: str, bangumi_id: str) -> Path | None:
        if not bangumi_id.isdigit() or item_key != f"bangumi:{bangumi_id}":
            raise PlaylistServiceError("Bangumi 条目标识无效。", status_code=400)
        cached = self.cached_poster(item_key)
        if cached:
            return cached
        lock = self._poster_locks.setdefault(item_key, asyncio.Lock())
        async with lock:
            cached = self.cached_poster(item_key)
            if cached:
                return cached
            subject_path = SUBJECT_ROOT / f"{bangumi_id}.json"
            subject: dict[str, Any]
            try:
                subject = json.loads(subject_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                subject = await fetch_bangumi_subject(bangumi_id)
                self._atomic(subject_path, json.dumps(subject, ensure_ascii=False).encode("utf-8"))
            images = subject.get("images") or {}
            image_url = images.get("large") or images.get("common") or images.get("medium")
            if not isinstance(image_url, str) or not image_url.startswith(("http://", "https://")):
                return None
            async with httpx.AsyncClient(
                timeout=15,
                follow_redirects=True,
                headers={"User-Agent": bangumi_user_agent()},
            ) as client:
                response = await client.get(image_url)
            response.raise_for_status()
            if len(response.content) > 8 * 1024 * 1024:
                raise PlaylistServiceError("Bangumi 海报超过缓存大小上限。")
            content_type = response.headers.get("content-type", "").lower()
            suffix = ".png" if "png" in content_type else ".webp" if "webp" in content_type else ".jpg"
            target = POSTER_ROOT / hashlib.sha256(item_key.encode("utf-8")).hexdigest()[:24] / f"poster{suffix}"
            self._atomic(target, response.content)
            return target

    def _merge_cached_subject_aliases(self, response: PlaylistQuarterResponse) -> PlaylistQuarterResponse:
        enriched: list[PlaylistQuarterItem] = []
        for item in response.items:
            if not item.bangumi_id or not item.bangumi_id.isdigit():
                enriched.append(item)
                continue
            subject_path = SUBJECT_ROOT / f"{item.bangumi_id}.json"
            try:
                subject = json.loads(subject_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                enriched.append(item)
                continue
            aliases = list(dict.fromkeys([*item.aliases, *_subject_aliases(subject)]))
            enriched.append(item.model_copy(update={"aliases": aliases}))
        return response.model_copy(update={"items": enriched})

    @staticmethod
    def _atomic(path: Path, content: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_bytes(content)
        temporary.replace(path)
