from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from html import unescape
from urllib.parse import quote_plus

from app.models import SearchResult
from app.sites.base import BaseSiteAdapter, absolute_url, first_text, stable_result_id, strip_html


NYAA_NS = "{https://nyaa.si/xmlns/nyaa}"


class NyaaAdapter(BaseSiteAdapter):
    id = "nyaa"
    name = "Nyaa"
    display_name = "Nyaa"
    base_url = "https://nyaa.si"
    supports_pagination = True
    default_page_size = 75
    max_recommended_pages = 10

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        url = f"{self.base_url}/?q={quote_plus(keyword)}&c=1_0&f=0&p={page}"
        html = await self.fetch_text(url)
        results = self.parse_search_html(html)
        has_more = self.has_next_page(html, page)
        return results, has_more

    def has_next_page(self, html: str, page: int) -> bool:
        next_page = page + 1
        return bool(re.search(rf"""href=['"][^'"]*?[?&]p={next_page}(?:&[^'"]*)?['"]""", html, flags=re.I))

    def parse_search_html(self, html: str) -> list[SearchResult]:
        rows = re.findall(r"<tr\b[^>]*>(.*?)</tr>", html, flags=re.I | re.S)
        results: list[SearchResult] = []
        for row in rows:
            if "/view/" not in row:
                continue
            title_match = re.search(
                r"""<a[^>]+href=['"]([^'"]*?/view/\d+)['"][^>]*(?:title=['"]([^'"]+)['"])?[^>]*>(.*?)</a>""",
                row,
                flags=re.I | re.S,
            )
            if not title_match:
                continue
            detail_url = absolute_url(self.base_url, title_match.group(1))
            title = strip_html(title_match.group(2) or title_match.group(3))
            download_match = re.search(r"""href=['"]([^'"]*?/download/\d+\.torrent)['"]""", row, flags=re.I)
            magnet_match = re.search(r"""href=['"](magnet:\?xt=[^'"]+)['"]""", row, flags=re.I)
            size_match = re.search(r"""<td[^>]*class=['"][^'"]*text-center[^'"]*['"][^>]*>\s*([^<]*?(?:GiB|MiB|GB|MB))\s*</td>""", row, flags=re.I)
            timestamp_match = re.search(r"""data-timestamp=['"](\d+)['"][^>]*>([^<]+)</td>""", row, flags=re.I)
            date_match = re.search(r"(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})", strip_html(row))
            download_url = absolute_url(self.base_url, download_match.group(1)) if download_match else None
            magnet_url = unescape(magnet_match.group(1)) if magnet_match else None
            published = timestamp_match.group(2).strip() if timestamp_match else (date_match.group(1) if date_match else None)
            url = magnet_url or download_url or detail_url
            results.append(
                SearchResult(
                    id=stable_result_id(self.id, title, url, detail_url),
                    title=title,
                    published_at=published,
                    size=size_match.group(1).strip() if size_match else None,
                    download_url=download_url,
                    magnet_url=magnet_url,
                    source=self.id,
                    detail_url=detail_url,
                )
            )
        return results

    def parse_search_rss(self, rss_text: str) -> list[SearchResult]:
        root = ET.fromstring(rss_text)
        results: list[SearchResult] = []
        for item in root.findall(".//item"):
            title = first_text(item, ["title"]) or "未命名资源"
            detail_url = first_text(item, ["link", "guid"])
            magnet_url = first_text(item, [f"{NYAA_NS}infoHash"])
            if magnet_url:
                magnet_url = f"magnet:?xt=urn:btih:{magnet_url}"
            download_url = first_text(item, [f"{NYAA_NS}torrent"])
            published = first_text(item, ["pubDate"])
            size = first_text(item, [f"{NYAA_NS}size"])
            url = magnet_url or download_url or detail_url
            results.append(
                SearchResult(
                    id=stable_result_id(self.id, title, url, detail_url),
                    title=title,
                    published_at=published,
                    size=size,
                    download_url=download_url,
                    magnet_url=magnet_url,
                    source=self.id,
                    detail_url=detail_url,
                )
            )
        return results
