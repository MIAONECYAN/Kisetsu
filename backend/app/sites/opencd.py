from __future__ import annotations

from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
import re
from urllib.parse import parse_qs, urlparse

from app.models import SearchResult
from app.sites.base import (
    BaseSiteAdapter,
    SiteAdapterError,
    absolute_url,
    clean_optional,
    coerce_int,
    coerce_size_bytes,
    stable_result_id,
    strip_html,
    torrent_filename,
)


_DETAIL_ID_RE = re.compile(r"(?:^|/)(?:plugin_)?details\.php\?[^#]*\bid=(\d+)", flags=re.I)
_DOWNLOAD_ID_RE = re.compile(r"(?:^|/)download\.php\?[^#]*\bid=(\d+)", flags=re.I)
_SIZE_RE = re.compile(r"\d+(?:\.\d+)?\s*(?:KiB|MiB|GiB|TiB|KB|MB|GB|TB)", flags=re.I)
_DATETIME_RE = re.compile(r"\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?")


@dataclass
class _OpenCDCell:
    text_parts: list[str] = field(default_factory=list)
    descriptors: list[str] = field(default_factory=list)

    @property
    def text(self) -> str:
        return re.sub(r"\s+", " ", " ".join(self.text_parts)).strip()


@dataclass
class _OpenCDRow:
    cells: list[_OpenCDCell] = field(default_factory=list)
    title_parts: list[str] = field(default_factory=list)
    subtitle_parts: list[str] = field(default_factory=list)
    detail_href: str | None = None
    download_href: str | None = None
    torrent_id: str | None = None
    title_cell_index: int | None = None

    @property
    def title(self) -> str | None:
        return clean_optional(" ".join(self.title_parts))

    @property
    def subtitle(self) -> str | None:
        return clean_optional(" ".join(self.subtitle_parts))


class _OpenCDTableParser(HTMLParser):
    """Parse OpenCD torrent rows while tolerating nested title markup."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._rows: list[_OpenCDRow] = []
        self.resource_rows: list[_OpenCDRow] = []
        self._torrentname_table_depth = 0
        self._title_link_depth = 0
        self._subtitle_font_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key.lower(): value for key, value in attrs}
        if tag == "tr":
            self._rows.append(_OpenCDRow())
            return
        if tag == "table" and "torrentname" in (attributes.get("class") or "").casefold().split():
            self._torrentname_table_depth += 1
        if tag == "td" and self._rows:
            self._rows[-1].cells.append(_OpenCDCell())
        descriptors = [
            attributes.get("alt"),
            attributes.get("title"),
            attributes.get("class"),
            attributes.get("onmouseover"),
            attributes.get("src"),
        ]
        for row in self._rows:
            if row.cells:
                row.cells[-1].descriptors.extend(value.strip() for value in descriptors if value and value.strip())
        if tag == "a" and self._rows:
            href = (attributes.get("href") or "").strip()
            detail_match = _DETAIL_ID_RE.search(href)
            download_match = _DOWNLOAD_ID_RE.search(href)
            if detail_match and self._torrentname_table_depth:
                self._title_link_depth += 1
                for row in self._rows:
                    row.detail_href = href
                    row.torrent_id = detail_match.group(1)
                    if row.cells:
                        row.title_cell_index = len(row.cells) - 1
                    title_attr = clean_optional(attributes.get("title"))
                    if title_attr:
                        row.title_parts = [title_attr]
            if download_match:
                for row in self._rows:
                    row.download_href = href
                    row.torrent_id = row.torrent_id or download_match.group(1)
        if tag == "font" and self._rows and any(row.detail_href for row in self._rows):
            color = (attributes.get("color") or "").casefold()
            css_class = (attributes.get("class") or "").casefold()
            style = (attributes.get("style") or "").casefold()
            if color in {"#888", "#888888", "#999", "#999999", "gray", "grey"} or "gray" in css_class or "grey" in css_class or "#888" in style or "#999" in style:
                self._subtitle_font_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._title_link_depth:
            self._title_link_depth -= 1
        if tag == "font" and self._subtitle_font_depth:
            self._subtitle_font_depth -= 1
        if tag == "table" and self._torrentname_table_depth:
            self._torrentname_table_depth -= 1
        if tag != "tr" or not self._rows:
            return
        row = self._rows.pop()
        if row.title and row.torrent_id and len(row.cells) >= 10:
            self.resource_rows.append(row)

    def handle_data(self, data: str) -> None:
        value = data.strip()
        if not value:
            return
        for row in self._rows:
            if row.cells:
                row.cells[-1].text_parts.append(value)
            if self._title_link_depth and row.detail_href and not row.title_parts:
                row.title_parts.append(value)
            if self._subtitle_font_depth and row.detail_href:
                row.subtitle_parts.append(value)


class _OpenCDDownloadParser(HTMLParser):
    def __init__(self, torrent_id: str | None = None) -> None:
        super().__init__(convert_charrefs=True)
        self.torrent_id = torrent_id
        self.download_href: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a" or self.download_href:
            return
        href = dict(attrs).get("href") or ""
        match = _DOWNLOAD_ID_RE.search(href)
        if match and (not self.torrent_id or match.group(1) == self.torrent_id):
            self.download_href = href


class OpenCDAdapter(BaseSiteAdapter):
    supports_brush = True
    id = "opencd"
    name = "OpenCD"
    display_name = "OpenCD"
    base_url = "https://open.cd"
    primary_url = "https://open.cd"
    fallback_base_urls: list[str] = []
    supports_pagination = True
    default_page_size = 50
    max_recommended_pages = 5
    auth_mode = "cookie"
    auth_fields = ["cookie", "authorization", "user_agent"]

    _PROMOTIONS = (
        ("pro_free2up", "2X FREE", 0.0, 2.0),
        ("pro_50pctdown2up", "2X 50%", 0.5, 2.0),
        ("pro_free", "FREE", 0.0, 1.0),
        ("pro_2up", "2X", 1.0, 2.0),
        ("pro_50pctdown", "50%", 0.5, 1.0),
        ("pro_30pctdown", "30%", 0.3, 1.0),
    )

    async def test_connection(self) -> tuple[bool, str, int | None]:
        if not getattr(self, "cookie", None):
            return False, "OpenCD 需要 Cookie，请先在站点设置中填写。", None
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/index.php",
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            raise_for_status=False,
        )
        if response.status_code != 200:
            return False, f"OpenCD 连接失败：HTTP {response.status_code}。", response.status_code
        if self.is_logged_in(response.text):
            return True, "OpenCD 连接成功。", response.status_code
        return False, "OpenCD Cookie 无效、已过期，或站点要求验证码登录。", response.status_code

    async def account_stats(self) -> tuple[int, int, float | None]:
        if not getattr(self, "cookie", None):
            raise SiteAdapterError("OpenCD 需要 Cookie，请先在站点设置中填写。")
        index_response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/index.php",
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            raise_for_status=False,
        )
        if index_response.status_code != 200 or not self.is_logged_in(index_response.text):
            raise SiteAdapterError("OpenCD Cookie 无效、已过期，或站点要求验证码登录。")
        user_id = self.parse_user_id(index_response.text)
        if not user_id:
            raise SiteAdapterError("OpenCD 首页缺少稳定用户 ID，无法读取账户统计。")
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/userdetails.php?id={user_id}",
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            raise_for_status=False,
        )
        if response.status_code != 200 or self.is_login_page(response.text):
            raise SiteAdapterError("OpenCD 账户信息获取失败，Cookie 可能已过期。")
        return self.parse_account_stats_html(response.text)

    @staticmethod
    def parse_user_id(html: str) -> str | None:
        match = re.search(r"userdetails\.php\?[^\"'<>]*\bid=(\d+)", unescape(html), flags=re.I)
        return match.group(1) if match else None

    @staticmethod
    def parse_account_stats_html(html: str) -> tuple[int, int, float | None]:
        prepared = strip_html(unescape(html))
        upload_match = re.search(r"上[傳传](?:量)?\s*[:：]?[^\d]{0,120}([\d,.]+\s*[KMGTPI]*B)", prepared, flags=re.I)
        download_match = re.search(r"下[載载](?:量)?\s*[:：]?[^\d]{0,120}([\d,.]+\s*[KMGTPI]*B)", prepared, flags=re.I)
        if not upload_match or not download_match:
            raise SiteAdapterError("OpenCD 账户页面缺少上传或下载数据。")
        uploaded = coerce_size_bytes(upload_match.group(1))
        downloaded = coerce_size_bytes(download_match.group(1))
        if uploaded is None or downloaded is None:
            raise SiteAdapterError("OpenCD 账户流量数据格式异常。")
        ratio_match = re.search(r"分享率\s*[:：]?[^\d]{0,80}([\d,.]+)", prepared, flags=re.I)
        ratio = float(ratio_match.group(1).replace(",", "")) if ratio_match else (uploaded / downloaded if downloaded else None)
        return uploaded, downloaded, ratio

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        page = max(1, page)
        page_size = max(1, min(page_size, 100))
        window_start = (page - 1) * page_size
        window_end = window_start + page_size
        server_page_size = self.default_page_size
        first_server_page = window_start // server_page_size
        last_server_page = (window_end - 1) // server_page_size
        window: list[SearchResult] = []
        available_end = first_server_page * server_page_size
        last_page_has_more = False

        for server_page in range(first_server_page, last_server_page + 1):
            page_results, page_has_more = await self._fetch_search_page(keyword, server_page=server_page)
            page_start = server_page * server_page_size
            local_start = max(0, window_start - page_start)
            local_end = min(len(page_results), window_end - page_start)
            if local_start < local_end:
                window.extend(page_results[local_start:local_end])
            available_end = max(available_end, page_start + len(page_results))
            last_page_has_more = page_has_more
            if not page_has_more:
                break

        has_more = available_end > window_end or last_page_has_more
        return window, has_more

    async def _fetch_search_page(self, keyword: str, *, server_page: int) -> tuple[list[SearchResult], bool]:
        if not getattr(self, "cookie", None):
            raise SiteAdapterError("OpenCD 需要 Cookie，请先在站点设置中填写。")
        params: dict[str, str | int] = {
            "incldead": 1,
            "spstate": 0,
            "search_area": 0,
            "search_mode": 0,
            "page": max(0, server_page),
        }
        if keyword.strip():
            params["search"] = keyword.strip()
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/torrents.php",
            params=params,
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        )
        if self.is_login_page(response.text):
            raise SiteAdapterError("OpenCD Cookie 无效、已过期，或站点要求验证码登录。")
        results = self.parse_search_html(response.text)
        if not results and not self.is_valid_empty_page(response.text):
            raise SiteAdapterError("OpenCD 种子列表结构已变化，未找到可识别的资源表格。")
        has_more = self.has_next_page(response.text, server_page + 1) or len(results) >= self.default_page_size
        return results, has_more

    async def preview_rss_resources(
        self,
        *,
        keyword: str | None = None,
        category: str | None = None,
        page: int = 1,
        page_size: int = 25,
    ) -> dict[str, object] | None:
        effective_page = max(1, page)
        effective_page_size = max(1, min(page_size, 100))
        source_results, has_more = await self.search_page(
            keyword or "",
            page=effective_page,
            page_size=effective_page_size,
        )
        results = source_results
        if category:
            wanted = category.strip().casefold()
            results = [
                result
                for result in source_results
                if wanted == (result.category or "").strip().casefold()
                or wanted in (result.category or "").strip().casefold()
            ]
        next_hint = " · 还有下一页" if has_more else ""
        return {
            "results": results,
            "source_results": source_results,
            "count": len(results),
            "page": effective_page,
            "page_size": effective_page_size,
            "total_pages": effective_page + (1 if has_more else 0),
            "has_previous": effective_page > 1,
            "has_next": has_more,
            "stop_reason": "authenticated_resource_preview",
            "message": f"本页读取到 {len(results)} 条资源 · 第 {effective_page} 页{next_hint}",
        }

    def parse_search_html(self, html: str) -> list[SearchResult]:
        parser = _OpenCDTableParser()
        parser.feed(html)
        results: list[SearchResult] = []
        for row in parser.resource_rows:
            if not row.title or not row.detail_href or not row.torrent_id or len(row.cells) < 10:
                continue
            title = strip_html(row.title)
            if not title:
                continue
            detail_url = absolute_url(self.base_url, row.detail_href)
            download_url = absolute_url(self.base_url, row.download_href or f"download.php?id={row.torrent_id}")
            title_cell_index = row.title_cell_index
            if title_cell_index is None or not 0 <= title_cell_index < len(row.cells):
                continue
            title_descriptors = " ".join(row.cells[title_cell_index].descriptors)
            promotion_label, download_factor, upload_factor = self.promotion(title_descriptors)
            promotion_until = self.promotion_until(title_descriptors) if promotion_label else None
            category = next((value for value in row.cells[0].descriptors if value and not value.startswith(("cat", "https", "/"))), None)
            published = next(
                (match.group(0) for value in [*row.cells[5].descriptors, row.cells[5].text] for match in [_DATETIME_RE.search(value)] if match),
                None,
            )
            size_match = _SIZE_RE.search(row.cells[6].text)
            subtitle = clean_optional(row.subtitle)
            if subtitle and subtitle.casefold() == title.casefold():
                subtitle = None
            combined_descriptors = f"{title_descriptors} {' '.join(cell.text for cell in row.cells)}"
            results.append(
                SearchResult(
                    id=stable_result_id(self.id, title, download_url, detail_url),
                    title=title,
                    subtitle=subtitle,
                    published_at=published,
                    size=size_match.group(0) if size_match else None,
                    size_bytes=coerce_size_bytes(size_match.group(0)) if size_match else None,
                    category=category,
                    is_free=download_factor == 0.0 if download_factor is not None else None,
                    discount_label=promotion_label,
                    free_until=promotion_until,
                    seeders=coerce_int(row.cells[7].text),
                    leechers=coerce_int(row.cells[8].text),
                    downloads=coerce_int(row.cells[9].text),
                    download_factor=download_factor,
                    upload_factor=upload_factor,
                    hit_and_run=True if re.search(r"hitandrun|hit_run\.gif|\bH\s*&\s*R\b", combined_descriptors, flags=re.I) else None,
                    is_pinned=True if re.search(r"(?:^|\s)sticky(?:\s|$)|置頂|置顶", combined_descriptors, flags=re.I) else False,
                    is_downloaded=True if re.search(r"progressarea|torrent-progress|downloaded", combined_descriptors, flags=re.I) else False,
                    download_url=download_url,
                    source=self.id,
                    detail_url=detail_url,
                    source_url=f"opencd:{row.torrent_id}",
                )
            )
        return results

    @classmethod
    def promotion(cls, value: str) -> tuple[str | None, float | None, float | None]:
        folded = value.casefold()
        for marker, label, download_factor, upload_factor in cls._PROMOTIONS:
            if marker in folded:
                return label, download_factor, upload_factor
        return None, None, None

    @staticmethod
    def promotion_until(value: str) -> str | None:
        matches = _DATETIME_RE.findall(unescape(value))
        return matches[-1] if matches else None

    @staticmethod
    def has_next_page(html: str, page: int) -> bool:
        for href in re.findall(r"""href=['\"]([^'\"]+)['\"]""", unescape(html), flags=re.I):
            parsed = urlparse(href)
            if not parsed.path.lower().endswith("torrents.php"):
                continue
            if str(page) in parse_qs(parsed.query).get("page", []):
                return True
        return False

    @staticmethod
    def is_login_page(html: str) -> bool:
        compact = html.casefold()
        return bool(
            re.search(r"<input[^>]+type=['\"]password['\"]", compact)
            or re.search(r"<form[^>]+(?:login\.php|name=['\"]login)", compact)
            or ("login.php" in compact and ("captcha" in compact or "验证码" in compact or "驗證碼" in compact))
        )

    @classmethod
    def is_logged_in(cls, html: str) -> bool:
        if cls.is_login_page(html):
            return False
        compact = html.casefold()
        return any(marker in compact for marker in ["logout.php", "userdetails.php", "mybonus.php", "messages.php", "usercp.php"])

    @staticmethod
    def is_valid_empty_page(html: str) -> bool:
        compact = html.casefold()
        return (
            "table" in compact and ("torrents" in compact or "torrentname" in compact)
        ) or any(
            marker in compact
            for marker in ["沒有種子", "没有种子", "沒有任何", "没有任何", "no torrents"]
        )

    @staticmethod
    def torrent_id_from_result(result: SearchResult) -> str | None:
        for value in (result.source_url, result.detail_url, result.download_url):
            if not value:
                continue
            match = re.search(r"(?:opencd:|(?:plugin_details|details|download)\.php\?[^#]*\bid=)(\d+)", value, flags=re.I)
            if match:
                return match.group(1)
        return None

    async def download_torrent(self, result: SearchResult) -> tuple[bytes, str]:
        torrent_id = self.torrent_id_from_result(result)
        download_url = result.download_url
        if result.detail_url:
            detail_response = await self.request(
                "GET",
                result.detail_url,
                headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            )
            if self.is_login_page(detail_response.text):
                raise SiteAdapterError("OpenCD Cookie 无效、已过期，或站点要求验证码登录。")
            parser = _OpenCDDownloadParser(torrent_id)
            parser.feed(detail_response.text)
            if parser.download_href:
                download_url = absolute_url(self.base_url, parser.download_href)
            elif not download_url:
                raise SiteAdapterError("OpenCD 详情页缺少种子下载链接，页面结构可能已变化。")
        if not download_url:
            raise SiteAdapterError("OpenCD 下载失败：资源没有下载链接。")
        response = await self.request(
            "GET",
            download_url,
            headers={"Accept": "application/x-bittorrent,*/*", "Referer": result.detail_url or self.base_url},
        )
        content_type = (response.headers.get("content-type") or "").casefold()
        content = response.content
        if "text/html" in content_type or not content.startswith(b"d") or b"4:info" not in content[:1_048_576]:
            raise SiteAdapterError("OpenCD 未返回有效的 .torrent 文件，Cookie 可能已过期或下载权限不足。")
        return content, torrent_filename(result)
