from __future__ import annotations

import re
from urllib.parse import quote_plus

from app.models import SearchResult
from app.sites.base import BaseSiteAdapter, SiteRateLimitError, absolute_url, stable_result_id, strip_html


class DmhyAdapter(BaseSiteAdapter):
    id = "dmhy"
    name = "動漫花園"
    display_name = "动漫花园 / DMHY"
    base_url = "https://share.dmhy.org"
    fallback_base_urls = ["http://share.dmhy.org", "https://dmhy.org"]
    supports_pagination = True
    default_page_size = 80
    max_recommended_pages = 10

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        last_error: Exception | None = None
        for base_url in [self.base_url, *self.fallback_base_urls]:
            path = "/topics/list" if page <= 1 else f"/topics/list/page/{page}"
            url = f"{base_url}{path}?keyword={quote_plus(keyword)}"
            try:
                html = await self.fetch_text(url)
                if self.is_access_limited_html(html):
                    await self.backoff_after_access_limit(url, "DMHY 返回回首页保护页")
                    html = await self.fetch_text(url)
                    if self.is_access_limited_html(html):
                        raise SiteRateLimitError("DMHY 返回访问限制页面，可能请求过快；请稍后重试，Kisetsu 会自动放慢请求速度。")
            except Exception as exc:
                if isinstance(exc, SiteRateLimitError):
                    raise
                last_error = exc
                continue
            results = self.parse_search_html(html, base_url=base_url)
            has_more = self.has_next_page(html, page)
            return results, has_more
        if last_error is not None:
            raise last_error
        return [], False

    def is_access_limited_html(self, html: str) -> bool:
        compact = re.sub(r"\s+", " ", html).lower()
        has_home_refresh = bool(re.search(r"""http-equiv=["']refresh["'][^>]+content=["']\s*5\s*;\s*url=/["']""", compact, flags=re.I))
        return has_home_refresh and "magnet:" not in compact and "/topics/view/" not in compact

    def has_next_page(self, html: str, page: int) -> bool:
        next_page = page + 1
        return bool(
            re.search(
                rf"""href=['"][^'"]*?/topics/list/page/{next_page}(?:\?[^'"]*)?['"]""",
                html,
                flags=re.I,
            )
        )

    def parse_search_html(self, html: str, base_url: str | None = None) -> list[SearchResult]:
        base_url = base_url or self.base_url
        rows = re.findall(r"<tr\b[^>]*>(.*?)</tr>", html, flags=re.I | re.S)
        results: list[SearchResult] = []
        for row in rows:
            if "magnet:" not in row and "/topics/view/" not in row:
                continue
            title_match = re.search(r"""<a[^>]+href=['"]([^'"]*?/topics/view/[^'"]+)['"][^>]*>(.*?)</a>""", row, flags=re.I | re.S)
            if not title_match:
                continue
            detail_url = absolute_url(base_url, title_match.group(1))
            title = strip_html(title_match.group(2))
            magnet_match = re.search(r"""href=['"](magnet:\?xt=[^'"]+)['"]""", row, flags=re.I)
            torrent_match = re.search(r"""href=['"]([^'"]*?\.torrent[^'"]*)['"]""", row, flags=re.I)
            date_match = re.search(r"(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2})", strip_html(row))
            size_match = re.search(r"(\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB))", strip_html(row), flags=re.I)
            download_url = absolute_url(base_url, torrent_match.group(1)) if torrent_match else None
            magnet_url = magnet_match.group(1) if magnet_match else None
            results.append(
                SearchResult(
                    id=stable_result_id(self.id, title, magnet_url or download_url, detail_url),
                    title=title,
                    published_at=date_match.group(1) if date_match else None,
                    size=size_match.group(1) if size_match else None,
                    download_url=download_url,
                    magnet_url=magnet_url,
                    source=self.id,
                    detail_url=detail_url,
                )
            )
        return results
