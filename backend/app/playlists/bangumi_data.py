from __future__ import annotations

import asyncio
import hashlib
import json
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

from app.playlists.models import (
    PlaylistQuarterItem,
    PlaylistQuarterOption,
    PlaylistQuarterResponse,
    PlaylistSiteLink,
)
from app.settings import DATA_DIR


MAX_DATA_BYTES = 12 * 1024 * 1024
MAX_ITEMS = 50_000
CACHE_TTL = timedelta(hours=24)
STALE_RETRY_TTL = timedelta(minutes=5)
CACHE_ROOT = DATA_DIR / "cache" / "playlists"
NORMALIZED_CACHE_VERSION = 1


class BangumiDataError(RuntimeError):
    pass


@dataclass(slots=True)
class LoadedBangumiData:
    payload: dict[str, Any]
    cached_at: datetime
    source_version: str | None
    stale: bool = False
    warning: str | None = None
    source_url: str | None = None
    content_digest: str | None = None


def parse_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        result = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if result.tzinfo is None:
        result = result.replace(tzinfo=timezone.utc)
    return result.astimezone(timezone.utc)


def quarter_month(month: int) -> int:
    if month <= 3:
        return 1
    if month <= 6:
        return 4
    if month <= 9:
        return 7
    return 10


def stable_item_key(item: dict[str, Any]) -> str:
    for site in item.get("sites") or []:
        if isinstance(site, dict) and site.get("site") == "bangumi" and str(site.get("id") or "").isdigit():
            return f"bangumi:{site['id']}"
    basis = "|".join(
        str(item.get(key) or "").strip()
        for key in ("title", "begin", "officialSite")
    )
    return "source:" + hashlib.sha256(basis.encode("utf-8")).hexdigest()[:24]


def _translated_titles(item: dict[str, Any]) -> tuple[str, list[str]]:
    original = str(item.get("title") or "").strip()
    translations = item.get("titleTranslate") or {}
    if not isinstance(translations, dict):
        translations = {}
    hans = [str(value).strip() for value in translations.get("zh-Hans") or [] if str(value).strip()]
    aliases: list[str] = []
    for values in translations.values():
        if isinstance(values, list):
            aliases.extend(str(value).strip() for value in values if str(value).strip())
    aliases = list(dict.fromkeys([original, *aliases]))
    return (hans[0] if hans else original), aliases


def _external_ids(item: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in item.get("sites") or []:
        if not isinstance(value, dict):
            continue
        site = str(value.get("site") or "").strip()
        identifier = str(value.get("id") or "").strip()
        if site and identifier:
            result[site.lower()] = identifier
    return result


def _links(item: dict[str, Any], site_meta: dict[str, Any]) -> list[PlaylistSiteLink]:
    result: list[PlaylistSiteLink] = []
    official = str(item.get("officialSite") or "").strip()
    if official.startswith(("http://", "https://")):
        result.append(PlaylistSiteLink(site="official", title="官方网站", kind="info", url=official))
    for value in item.get("sites") or []:
        if not isinstance(value, dict):
            continue
        site = str(value.get("site") or "").strip()
        identifier = str(value.get("id") or "").strip()
        meta = site_meta.get(site)
        if not site or not identifier or not isinstance(meta, dict):
            continue
        kind = meta.get("type")
        template = str(meta.get("urlTemplate") or "").strip()
        if kind not in {"info", "onair", "resource"} or "{{id}}" not in template:
            continue
        url = template.replace("{{id}}", quote(identifier, safe="/:@"))
        if not url.startswith(("http://", "https://")):
            continue
        result.append(
            PlaylistSiteLink(
                site=site,
                title=str(meta.get("title") or site),
                kind=kind,
                url=url,
            )
        )
    unique: dict[tuple[str, str], PlaylistSiteLink] = {}
    for link in result:
        unique[(link.kind, link.url)] = link
    return list(unique.values())


def validate_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise BangumiDataError("bangumi-data 根节点不是对象。")
    site_meta = payload.get("siteMeta")
    items = payload.get("items")
    if not isinstance(site_meta, dict) or not isinstance(items, list):
        raise BangumiDataError("bangumi-data 缺少 siteMeta 或 items。")
    if len(items) > MAX_ITEMS:
        raise BangumiDataError("bangumi-data 条目数量超过安全上限。")
    valid = 0
    for item in items:
        if isinstance(item, dict) and isinstance(item.get("title"), str) and parse_datetime(item.get("begin")):
            valid += 1
    if items and valid < max(1, len(items) // 2):
        raise BangumiDataError("bangumi-data 中有效条目比例异常。")
    return payload


class BangumiDataService:
    def __init__(
        self,
        cache_root: Path | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.cache_root = cache_root or CACHE_ROOT
        self.data_path = self.cache_root / "bangumi-data.json"
        self.metadata_path = self.cache_root / "bangumi-data.meta.json"
        self.transport = transport
        self._load_lock = asyncio.Lock()
        self._memory_loaded: LoadedBangumiData | None = None
        self._stale_retry_after: datetime | None = None

    async def load(self, cdn_url: str, *, force: bool = False) -> LoadedBangumiData:
        async with self._load_lock:
            return await self._load_locked(cdn_url, force=force)

    async def _load_locked(self, cdn_url: str, *, force: bool) -> LoadedBangumiData:
        memory = self._memory_loaded
        now = datetime.now(timezone.utc)
        if (
            not force
            and memory is not None
            and memory.source_url == cdn_url
            and (
                now - memory.cached_at < CACHE_TTL
                or (
                    memory.stale
                    and self._stale_retry_after is not None
                    and now < self._stale_retry_after
                )
            )
        ):
            return memory

        metadata, cached, cached_at, cached_digest = await asyncio.to_thread(self._cache_state)
        same_url = metadata.get("url") == cdn_url if metadata else False
        if not force and cached is not None and same_url and cached_at and datetime.now(timezone.utc) - cached_at < CACHE_TTL:
            loaded = LoadedBangumiData(
                cached,
                cached_at,
                metadata.get("version"),
                source_url=cdn_url,
                content_digest=cached_digest,
            )
            self._memory_loaded = loaded
            self._stale_retry_after = None
            return loaded

        headers: dict[str, str] = {"User-Agent": "Kisetsu/0.1", "Accept": "application/json"}
        if cached is not None and same_url:
            if metadata.get("etag"):
                headers["If-None-Match"] = str(metadata["etag"])
            if metadata.get("last_modified"):
                headers["If-Modified-Since"] = str(metadata["last_modified"])
        try:
            async with httpx.AsyncClient(
                timeout=20,
                follow_redirects=True,
                headers=headers,
                transport=self.transport,
            ) as client:
                response = await client.get(cdn_url)
            if response.status_code == 304 and cached is not None:
                now = datetime.now(timezone.utc)
                metadata["cached_at"] = now.isoformat()
                metadata["content_digest"] = cached_digest
                await asyncio.to_thread(self._atomic_json, self.metadata_path, metadata)
                loaded = LoadedBangumiData(
                    cached,
                    now,
                    metadata.get("version"),
                    source_url=cdn_url,
                    content_digest=cached_digest,
                )
                self._memory_loaded = loaded
                self._stale_retry_after = None
                return loaded
            response.raise_for_status()
            content_length = response.headers.get("content-length")
            if content_length and int(content_length) > MAX_DATA_BYTES:
                raise BangumiDataError("bangumi-data 响应超过 12 MB 安全上限。")
            if len(response.content) > MAX_DATA_BYTES:
                raise BangumiDataError("bangumi-data 响应超过 12 MB 安全上限。")
            payload = await asyncio.to_thread(self._decode_payload, response.content)
            now = datetime.now(timezone.utc)
            content_digest = hashlib.sha256(response.content).hexdigest()
            metadata = {
                "url": cdn_url,
                "cached_at": now.isoformat(),
                "etag": response.headers.get("etag"),
                "last_modified": response.headers.get("last-modified"),
                "version": response.headers.get("x-unpkg-version"),
                "content_digest": content_digest,
            }
            await asyncio.to_thread(self._persist_cache, response.content, metadata)
            loaded = LoadedBangumiData(
                payload,
                now,
                metadata.get("version"),
                source_url=cdn_url,
                content_digest=content_digest,
            )
            self._memory_loaded = loaded
            self._stale_retry_after = None
            return loaded
        except Exception as exc:
            if cached is not None and same_url and cached_at:
                loaded = LoadedBangumiData(
                    cached,
                    cached_at,
                    metadata.get("version"),
                    stale=True,
                    warning=f"CDN 暂时不可用，正在使用 {cached_at.astimezone().strftime('%Y-%m-%d %H:%M')} 的缓存。",
                    source_url=cdn_url,
                    content_digest=cached_digest,
                )
                self._memory_loaded = loaded
                self._stale_retry_after = datetime.now(timezone.utc) + STALE_RETRY_TTL
                return loaded
            if isinstance(exc, BangumiDataError):
                raise
            raise BangumiDataError("无法读取 bangumi-data，且没有可用缓存。") from exc

    def _cache_state(
        self,
    ) -> tuple[dict[str, Any], dict[str, Any] | None, datetime | None, str | None]:
        metadata = self._metadata()
        cached = self._cached_payload()
        cached_at = parse_datetime(metadata.get("cached_at")) if metadata else None
        cached_digest = str(metadata.get("content_digest") or "") or self._cached_content_digest(cached)
        return metadata, cached, cached_at, cached_digest

    @staticmethod
    def _decode_payload(content: bytes) -> dict[str, Any]:
        try:
            return validate_payload(json.loads(content))
        except (ValueError, json.JSONDecodeError) as exc:
            raise BangumiDataError("bangumi-data 返回的 JSON 无效。") from exc

    def _persist_cache(self, content: bytes, metadata: dict[str, Any]) -> None:
        self._atomic_bytes(self.data_path, content)
        self._atomic_json(self.metadata_path, metadata)

    def quarter_options(self, loaded: LoadedBangumiData) -> list[PlaylistQuarterOption]:
        counts: dict[tuple[int, int], int] = {}
        seen: set[tuple[int, int, str]] = set()
        for raw in loaded.payload.get("items") or []:
            if not isinstance(raw, dict):
                continue
            begin = parse_datetime(raw.get("begin"))
            key = stable_item_key(raw)
            if not begin:
                continue
            quarter = (begin.year, quarter_month(begin.month))
            scoped_key = (quarter[0], quarter[1], key)
            if scoped_key in seen:
                continue
            seen.add(scoped_key)
            counts[quarter] = counts.get(quarter, 0) + 1
        return [
            PlaylistQuarterOption(year=year, month=month, count=count)
            for (year, month), count in sorted(counts.items(), reverse=True)
        ]

    def quarter(self, loaded: LoadedBangumiData, year: int, month: int) -> PlaylistQuarterResponse:
        if month not in {1, 4, 7, 10}:
            raise BangumiDataError("季度月份只能是 1、4、7 或 10。")
        cached = self._normalized_quarter(loaded, year, month)
        if cached is not None:
            return cached.model_copy(update={
                "cached_at": loaded.cached_at,
                "source_version": loaded.source_version,
                "stale": loaded.stale,
                "warning": loaded.warning,
            })
        site_meta = loaded.payload.get("siteMeta") or {}
        items: list[PlaylistQuarterItem] = []
        seen: set[str] = set()
        for raw in loaded.payload.get("items") or []:
            if not isinstance(raw, dict):
                continue
            begin = parse_datetime(raw.get("begin"))
            key = stable_item_key(raw)
            if not begin or begin.year != year or quarter_month(begin.month) != month or key in seen:
                continue
            seen.add(key)
            title, aliases = _translated_titles(raw)
            external_ids = _external_ids(raw)
            bangumi_id = external_ids.get("bangumi")
            if not bangumi_id or not bangumi_id.isdigit():
                bangumi_id = None
            items.append(
                PlaylistQuarterItem(
                    key=key,
                    title=title,
                    original_title=str(raw.get("title") or "").strip(),
                    aliases=aliases,
                    media_type=str(raw.get("type") or "unknown"),
                    begin=begin,
                    broadcast=str(raw.get("broadcast") or "").strip() or None,
                    bangumi_id=bangumi_id,
                    external_ids=external_ids,
                    links=_links(raw, site_meta),
                    poster_url=f"/api/playlists/posters/{quote(key, safe='')}" if bangumi_id else None,
                )
            )
        items.sort(key=lambda item: (item.begin, item.title.casefold()))
        response = PlaylistQuarterResponse(
            year=year,
            month=month,
            title=f"{year} 年 {month} 月番组",
            items=items,
            cached_at=loaded.cached_at,
            source_version=loaded.source_version,
            stale=loaded.stale,
            warning=loaded.warning,
        )
        self._atomic_json(self._normalized_path(loaded, year, month), response.model_dump(mode="json"))
        return response

    def _normalized_quarter(
        self,
        loaded: LoadedBangumiData,
        year: int,
        month: int,
    ) -> PlaylistQuarterResponse | None:
        try:
            payload = json.loads(self._normalized_path(loaded, year, month).read_text(encoding="utf-8"))
            return PlaylistQuarterResponse.model_validate(payload)
        except (OSError, ValueError):
            return None

    def _normalized_path(self, loaded: LoadedBangumiData, year: int, month: int) -> Path:
        content_digest = loaded.content_digest or self._payload_digest(loaded.payload)
        basis = f"{NORMALIZED_CACHE_VERSION}\0{loaded.source_url or ''}\0{content_digest}"
        source_key = hashlib.sha256(basis.encode("utf-8")).hexdigest()[:24]
        return self.cache_root / "normalized" / source_key / f"{year}-{month:02d}.json"

    @staticmethod
    def _payload_digest(payload: dict[str, Any]) -> str:
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def _cached_content_digest(self, payload: dict[str, Any] | None) -> str | None:
        if payload is None:
            return None
        try:
            return hashlib.sha256(self.data_path.read_bytes()).hexdigest()
        except OSError:
            return self._payload_digest(payload)

    def _cached_payload(self) -> dict[str, Any] | None:
        try:
            return validate_payload(json.loads(self.data_path.read_text(encoding="utf-8")))
        except (OSError, ValueError, BangumiDataError):
            return None

    def _metadata(self) -> dict[str, Any]:
        try:
            value = json.loads(self.metadata_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def _atomic_json(self, path: Path, value: dict[str, Any]) -> None:
        self._atomic_bytes(path, json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8"))

    def _atomic_bytes(self, path: Path, value: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_bytes(value)
        temporary.replace(path)
