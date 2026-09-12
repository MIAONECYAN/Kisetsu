from __future__ import annotations

import re

from app.models import SearchResult
from app.sites.base import (
    BaseSiteAdapter,
    SiteAdapterError,
    bytes_to_size,
    clean_optional,
    pt_free_remaining,
    pt_metadata_from_dict,
    root_domain,
    stable_result_id,
    torrent_filename,
)


HDDOLBY_PROMOTION_FACTORS: dict[int, tuple[float, float, str]] = {
    2: (0.0, 1.0, "FREE"),
    3: (1.0, 2.0, "2X"),
    4: (1.0, 2.0, "2X"),
    5: (0.5, 1.0, "50%"),
    6: (1.0, 2.0, "2X"),
    7: (0.3, 1.0, "30%"),
}


class HDDolbyAdapter(BaseSiteAdapter):
    supports_brush = True
    id = "hddolby"
    name = "HD DOLBY"
    display_name = "HD DOLBY"
    base_url = "https://www.hddolby.com"
    primary_url = "https://www.hddolby.com"
    fallback_base_urls: list[str] = []
    supports_pagination = True
    default_page_size = 100
    max_recommended_pages = 5
    auth_mode = "api_key"
    auth_fields = ["api_key", "authorization"]
    rss_default_path = "getrss.php"
    rss_default_params = {
        "inclbookmarked": 0,
        "itemsmalldescr": 1,
        "showrows": 50,
        "search_mode": 1,
        "exp": 180,
    }
    category_ids = list(range(401, 451))

    async def test_connection(self) -> tuple[bool, str, int | None]:
        if not getattr(self, "api_key", None):
            return False, "HD DOLBY 需要 API Key，请先在站点设置中填写。", None
        response = await self.request("GET", f"{self.api_base_url}/api/v1/user/data", raise_for_status=False)
        if response.status_code != 200:
            return False, f"HD DOLBY 连接失败：HTTP {response.status_code}。", response.status_code
        payload = response.json()
        if payload.get("status") == 0:
            return True, "HD DOLBY 连接成功。", response.status_code
        return False, payload.get("message") or "HD DOLBY API Key 无效或已过期。", response.status_code

    async def account_stats(self) -> tuple[int, int, float | None]:
        if not getattr(self, "api_key", None):
            raise SiteAdapterError("HD DOLBY 需要 API Key，请先在站点设置中填写。")
        response = await self.request("GET", f"{self.api_base_url}/api/v1/user/data", raise_for_status=False)
        if response.status_code in {401, 403}:
            raise SiteAdapterError("HD DOLBY 认证失败，请检查 API Key。")
        if response.status_code != 200:
            raise SiteAdapterError(f"HD DOLBY 账户信息获取失败：HTTP {response.status_code}。")
        return self.parse_account_stats(response.json())

    @staticmethod
    def parse_account_stats(payload: dict) -> tuple[int, int, float | None]:
        rows = payload.get("data") if isinstance(payload, dict) and payload.get("status") == 0 else None
        if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
            raise SiteAdapterError("HD DOLBY 账户信息缺少流量数据。")
        try:
            uploaded = int(rows[0].get("uploaded") or 0)
            downloaded = int(rows[0].get("downloaded") or 0)
        except (TypeError, ValueError) as exc:
            raise SiteAdapterError("HD DOLBY 账户流量数据格式异常。") from exc
        return uploaded, downloaded, uploaded / downloaded if downloaded else None

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        if not getattr(self, "api_key", None):
            raise SiteAdapterError("HD DOLBY 需要 API Key，请先在站点设置中填写。")
        page_size = min(max(1, page_size), self.default_page_size)
        payload = {
            "keyword": keyword.strip(),
            "page_number": max(0, page - 1),
            "page_size": page_size,
            "categories": self.category_ids,
            "visible": 1,
        }
        response = await self.request(
            "POST",
            f"{self.api_base_url}/api/v1/torrent/search",
            headers={"Content-Type": "application/json", "Referer": self.base_url},
            json=payload,
        )
        body = response.json()
        if body.get("error"):
            raise SiteAdapterError(body["error"].get("message") or "HD DOLBY 搜索失败。")
        rows = body.get("data") or []
        results = [self.result_from_item(item) for item in rows if isinstance(item, dict)]
        return results, len(results) >= page_size

    @property
    def api_base_url(self) -> str:
        return f"https://api.{root_domain(self.base_url)}"

    def result_from_item(self, item: dict) -> SearchResult:
        torrent_id = str(item.get("id") or "")
        downhash = str(item.get("downhash") or "")
        title = item.get("name") or "未命名资源"
        metadata = pt_metadata_from_dict(item, site_id=self.id)
        promotion = self.promotion_metadata(item, fallback=metadata)
        detail_url = f"{self.base_url.rstrip('/')}/details.php?id={torrent_id}&hit=1" if torrent_id else self.base_url
        download_url = f"{self.base_url.rstrip('/')}/download.php?id={torrent_id}&downhash={downhash}" if torrent_id and downhash else None
        return SearchResult(
            id=stable_result_id(self.id, title, download_url, detail_url),
            title=title,
            subtitle=metadata.get("subtitle") if isinstance(metadata.get("subtitle"), str) else None,
            published_at=item.get("added"),
            size=bytes_to_size(item.get("size")),
            size_bytes=metadata.get("size_bytes") if isinstance(metadata.get("size_bytes"), int) else None,
            category=metadata.get("category") if isinstance(metadata.get("category"), str) else None,
            language=metadata.get("language") if isinstance(metadata.get("language"), str) else None,
            is_free=promotion["is_free"],
            discount_label=promotion["discount_label"],
            free_until=promotion["free_until"],
            free_remaining=promotion["free_remaining"],
            seeders=metadata.get("seeders") if isinstance(metadata.get("seeders"), int) else None,
            leechers=metadata.get("leechers") if isinstance(metadata.get("leechers"), int) else None,
            downloads=metadata.get("downloads") if isinstance(metadata.get("downloads"), int) else None,
            download_factor=promotion["download_factor"],
            upload_factor=promotion["upload_factor"],
            hit_and_run=metadata.get("hit_and_run") if isinstance(metadata.get("hit_and_run"), bool) else None,
            download_url=download_url,
            magnet_url=None,
            source=self.id,
            detail_url=detail_url,
            source_url=f"hddolby:{torrent_id}" if torrent_id else None,
        )

    @staticmethod
    def promotion_metadata(item: dict, *, fallback: dict[str, object | None]) -> dict[str, object | None]:
        raw_promotion_type = item.get("promotion_time_type")
        try:
            promotion_type = int(raw_promotion_type)
        except (TypeError, ValueError):
            promotion_type = None
        mapped = HDDOLBY_PROMOTION_FACTORS.get(promotion_type)
        if mapped is None:
            if raw_promotion_type in (None, ""):
                return {
                    "is_free": fallback.get("is_free"),
                    "discount_label": fallback.get("discount_label"),
                    "download_factor": fallback.get("download_factor"),
                    "upload_factor": fallback.get("upload_factor"),
                    "free_until": fallback.get("free_until"),
                    "free_remaining": fallback.get("free_remaining"),
                }
            return {
                "is_free": None,
                "discount_label": None,
                "download_factor": None,
                "upload_factor": None,
                "free_until": None,
                "free_remaining": None,
            }
        download_factor, upload_factor, label = mapped
        until = clean_optional(item.get("promotion_until"))
        if until and until.startswith("0000-00-00"):
            until = None
        return {
            "is_free": download_factor < 1,
            "discount_label": label,
            "download_factor": download_factor,
            "upload_factor": upload_factor,
            "free_until": until,
            "free_remaining": pt_free_remaining(until),
        }

    async def enrich_rss_preview_results(self, results: list[SearchResult], *, limit: int = 20) -> list[SearchResult]:
        candidates = results[:limit]
        if not candidates or all(
            result.subtitle
            and result.seeders is not None
            and result.leechers is not None
            and result.downloads is not None
            for result in candidates
        ):
            return results
        try:
            browse_results, _ = await self.search_page("", page=1, page_size=self.default_page_size)
        except Exception:
            return results
        metadata_by_id = {
            torrent_id: item
            for item in browse_results
            if (torrent_id := self.torrent_id_from_result(item))
        }
        enriched: list[SearchResult] = []
        for index, result in enumerate(results):
            if index >= limit:
                enriched.append(result)
                continue
            metadata = metadata_by_id.get(self.torrent_id_from_result(result) or "")
            if metadata is None:
                enriched.append(result)
                continue
            enriched.append(
                result.model_copy(
                    update={
                        "subtitle": result.subtitle or metadata.subtitle,
                        "category": result.category or metadata.category,
                        "language": result.language or metadata.language,
                        "is_free": metadata.is_free if metadata.is_free is not None else result.is_free,
                        "discount_label": metadata.discount_label or result.discount_label,
                        "free_until": metadata.free_until or result.free_until,
                        "free_remaining": metadata.free_remaining or result.free_remaining,
                        "seeders": metadata.seeders if metadata.seeders is not None else result.seeders,
                        "leechers": metadata.leechers if metadata.leechers is not None else result.leechers,
                        "downloads": metadata.downloads if metadata.downloads is not None else result.downloads,
                    }
                )
            )
        return enriched

    @staticmethod
    def torrent_id_from_result(result: SearchResult) -> str | None:
        for value in (result.source_url, result.detail_url, result.download_url):
            if not value:
                continue
            match = re.search(r"(?:hddolby:|[?&]id=)(\d+)", value, flags=re.I)
            if match:
                return match.group(1)
        return None

    async def download_torrent(self, result: SearchResult) -> tuple[bytes, str]:
        if not result.download_url:
            raise SiteAdapterError("HD DOLBY 下载失败：资源没有 downhash。")
        response = await self.request(
            "GET",
            result.download_url,
            headers={"Accept": "application/x-bittorrent,*/*", "Referer": result.detail_url or self.base_url},
        )
        return response.content, torrent_filename(result)
