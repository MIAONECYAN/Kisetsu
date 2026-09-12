from __future__ import annotations

import re
from typing import Protocol

from app.brush.models import BrushCandidate, BrushCandidatePage, BrushCapabilities
from app.models import SearchResult
from app.sites import get_site_adapter


def size_bytes(value: str | None) -> int | None:
    if not value:
        return None
    match = re.search(r"([\d,.]+)\s*(B|KB|KIB|MB|MIB|GB|GIB|TB|TIB)", value, flags=re.I)
    if not match:
        return None
    number = float(match.group(1).replace(",", ""))
    unit = match.group(2).upper()
    powers = {"B": 0, "KB": 1, "KIB": 1, "MB": 2, "MIB": 2, "GB": 3, "GIB": 3, "TB": 4, "TIB": 4}
    return int(number * (1024 ** powers[unit]))


def resource_id(result: SearchResult) -> str | None:
    if result.source_url:
        prefix = f"{result.source}:"
        if result.source_url.startswith(prefix):
            value = result.source_url[len(prefix):].strip()
            if value:
                return value
    for value in (result.detail_url, result.download_url):
        if not value:
            continue
        match = re.search(r"(?:[?&](?:id|torrent_id)=|/torrent/)(\d+)", value, flags=re.I)
        if match:
            return match.group(1)
    return result.id or None


class BrushSiteAdapter(Protocol):
    site_id: str

    def capabilities(self) -> BrushCapabilities: ...

    async def list_candidates(self, *, page: int, page_size: int) -> BrushCandidatePage: ...

    async def resolve_candidate(self, candidate: BrushCandidate) -> BrushCandidate: ...

    async def download_torrent(self, candidate: BrushCandidate) -> tuple[bytes, str]: ...

    async def account_stats(self) -> tuple[int, int, float | None]: ...


class SearchBackedBrushAdapter:
    site_id = ""
    supports_double_upload = False

    def __init__(self, site_settings: dict | None = None):
        self.adapter = get_site_adapter(self.site_id, site_settings)

    def capabilities(self) -> BrushCapabilities:
        missing: list[str] = []
        if not self.supports_double_upload:
            missing.append("upload_factor")
        return BrushCapabilities(
            site_id=self.site_id,
            supports_promotion=True,
            supports_double_upload=self.supports_double_upload,
            supports_seeders=True,
            supports_pagination=True,
            missing_fields=missing,
        )

    async def list_candidates(self, *, page: int, page_size: int) -> BrushCandidatePage:
        results, has_more = await self.adapter.search_page("", page=max(1, page), page_size=page_size)
        candidates = [self._candidate(result, page=max(1, page)) for result in results]
        return BrushCandidatePage(
            site_id=self.site_id,
            site_name=self.adapter.info().display_name or self.adapter.name,
            page=max(1, page),
            has_more=has_more,
            capabilities=self.capabilities(),
            candidates=candidates,
        )

    def _candidate(self, result: SearchResult, *, page: int) -> BrushCandidate:
        stable_id = resource_id(result)
        exact_size = getattr(result, "size_bytes", None) or size_bytes(result.size)
        download_factor = getattr(result, "download_factor", None)
        upload_factor = getattr(result, "upload_factor", None)
        label = result.discount_label
        if download_factor is None and label and label.upper() == "FREE":
            download_factor = 0
        unavailable: list[str] = []
        if not stable_id:
            unavailable.append("缺少稳定资源 ID")
        if exact_size is None:
            unavailable.append("缺少精确体积")
        if not (result.download_url or result.magnet_url):
            unavailable.append("缺少下载入口")
        return BrushCandidate(
            site_id=self.site_id,
            site_name=self.adapter.info().display_name or self.adapter.name,
            resource_id=stable_id or result.id,
            title=result.title,
            subtitle=result.subtitle,
            size_bytes=exact_size,
            published_at=result.published_at,
            seeders=result.seeders,
            leechers=result.leechers,
            completed=result.downloads,
            download_factor=download_factor,
            upload_factor=upload_factor,
            promotion_label=label,
            promotion_until=result.free_until,
            page=page,
            downloadable=not unavailable,
            unavailable_reason="、".join(unavailable) if unavailable else None,
            download_url=result.download_url or result.magnet_url,
            detail_url=result.detail_url,
            source_result=result.model_dump(mode="json"),
        )

    async def download_torrent(self, candidate: BrushCandidate) -> tuple[bytes, str]:
        return await self.adapter.download_torrent(SearchResult(**candidate.source_result))

    async def account_stats(self) -> tuple[int, int, float | None]:
        return await self.adapter.account_stats()

    async def resolve_candidate(self, candidate: BrushCandidate) -> BrushCandidate:
        return candidate


class MTeamBrushAdapter(SearchBackedBrushAdapter):
    site_id = "mteam"
    supports_double_upload = True


class HDDolbyBrushAdapter(SearchBackedBrushAdapter):
    site_id = "hddolby"
    supports_double_upload = True


class SoulVoiceBrushAdapter(SearchBackedBrushAdapter):
    site_id = "soulvoice"
    supports_double_upload = False


class OpenCDBrushAdapter(SearchBackedBrushAdapter):
    site_id = "opencd"
    supports_double_upload = True


BRUSH_SITE_REGISTRY: dict[str, type[SearchBackedBrushAdapter]] = {
    "mteam": MTeamBrushAdapter,
    "hddolby": HDDolbyBrushAdapter,
    "soulvoice": SoulVoiceBrushAdapter,
    "opencd": OpenCDBrushAdapter,
}


def get_brush_site_adapter(site_id: str, site_settings: dict | None = None) -> BrushSiteAdapter:
    adapter_type = BRUSH_SITE_REGISTRY.get(site_id)
    if adapter_type is None:
        raise ValueError(f"站点 {site_id} 尚未实现刷流协议。")
    return adapter_type(site_settings)


def brush_site_capabilities(site_settings: dict | None = None) -> list[BrushCapabilities]:
    return [adapter(site_settings).capabilities() for adapter in BRUSH_SITE_REGISTRY.values()]
