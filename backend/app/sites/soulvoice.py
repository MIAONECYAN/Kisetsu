from __future__ import annotations

from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
import re
from urllib.parse import parse_qs, quote_plus, urlparse

from app.models import SearchResult
from app.sites.base import BaseSiteAdapter, SiteAdapterError, absolute_url, clean_optional, stable_result_id, strip_html, torrent_filename, coerce_int, coerce_size_bytes, pt_metadata_from_text


_DETAIL_ID_RE = re.compile(r"(?:^|/)details\.php\?id=(\d+)", flags=re.I)
_DOWNLOAD_ID_RE = re.compile(r"(?:^|/)download\.php\?id=(\d+)", flags=re.I)
_SIZE_RE = re.compile(r"\d+(?:\.\d+)?\s*(?:KiB|MiB|GiB|TiB|KB|MB|GB|TB)", flags=re.I)
_PUBLISHED_RE = re.compile(r"\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}")


@dataclass
class _SoulVoiceCell:
    text_parts: list[str] = field(default_factory=list)
    descriptors: list[str] = field(default_factory=list)

    @property
    def text(self) -> str:
        return re.sub(r"\s+", " ", " ".join(self.text_parts)).strip()


@dataclass
class _SoulVoiceRow:
    cells: list[_SoulVoiceCell] = field(default_factory=list)
    title: str | None = None
    detail_href: str | None = None
    download_href: str | None = None
    torrent_id: str | None = None
    subtitle_parts: list[str] = field(default_factory=list)

    @property
    def subtitle(self) -> str | None:
        return clean_optional(" ".join(self.subtitle_parts))


class _SoulVoiceTableParser(HTMLParser):
    """Parse SoulVoice's nested NexusPHP rows without truncating outer cells."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._rows: list[_SoulVoiceRow] = []
        self.resource_rows: list[_SoulVoiceRow] = []
        self._td_depth = 0
        self._span_depth = 0
        self._subtitle_td_depth: int | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key.lower(): value for key, value in attrs}
        if tag == "tr":
            self._rows.append(_SoulVoiceRow())
            return
        if tag == "td" and self._rows:
            self._td_depth += 1
            self._rows[-1].cells.append(_SoulVoiceCell())
        if tag == "span":
            self._span_depth += 1
        if tag == "br" and any(row.title for row in self._rows):
            self._subtitle_td_depth = self._td_depth
        descriptors = [attributes.get("alt"), attributes.get("title")]
        for row in self._rows:
            if row.cells:
                row.cells[-1].descriptors.extend(value.strip() for value in descriptors if value and value.strip())
        if tag != "a" or not self._rows:
            return
        href = (attributes.get("href") or "").strip()
        detail_match = _DETAIL_ID_RE.search(href)
        download_match = _DOWNLOAD_ID_RE.search(href)
        if detail_match and attributes.get("title"):
            for row in self._rows:
                row.title = attributes["title"].strip()
                row.detail_href = href
                row.torrent_id = detail_match.group(1)
        if download_match:
            for row in self._rows:
                row.download_href = href
                row.torrent_id = row.torrent_id or download_match.group(1)

    def handle_endtag(self, tag: str) -> None:
        if tag == "span":
            self._span_depth = max(0, self._span_depth - 1)
        if tag == "td":
            if self._subtitle_td_depth == self._td_depth:
                self._subtitle_td_depth = None
            self._td_depth = max(0, self._td_depth - 1)
        if tag != "tr" or not self._rows:
            return
        row = self._rows.pop()
        if row.title and row.torrent_id and len(row.cells) >= 9:
            self.resource_rows.append(row)

    def handle_data(self, data: str) -> None:
        if not data.strip():
            return
        for row in self._rows:
            if row.cells:
                row.cells[-1].text_parts.append(data)
                if self._subtitle_td_depth is not None and self._span_depth == 0 and row.title:
                    row.subtitle_parts.append(data)


class SoulVoiceAdapter(BaseSiteAdapter):
    supports_brush = True
    id = "soulvoice"
    name = "SoulVoice"
    display_name = "SoulVoice"
    base_url = "https://pt.soulvoice.club"
    primary_url = "https://pt.soulvoice.club"
    fallback_base_urls: list[str] = []
    supports_pagination = True
    default_page_size = 50
    max_recommended_pages = 5
    auth_mode = "cookie"
    auth_fields = ["cookie", "authorization", "user_agent"]
    rss_default_path = "getrss.php"
    rss_default_params = {
        "inclbookmarked": 0,
        "itemsmalldescr": 1,
        "showrows": 50,
        "search_mode": 1,
    }

    async def test_connection(self) -> tuple[bool, str, int | None]:
        if not getattr(self, "cookie", None):
            return False, "SoulVoice 需要 Cookie，请先在站点设置中填写。", None
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/index.php",
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            raise_for_status=False,
        )
        if response.status_code != 200:
            return False, f"SoulVoice 连接失败：HTTP {response.status_code}。", response.status_code
        if self.is_logged_in(response.text):
            return True, "SoulVoice 连接成功。", response.status_code
        return False, "SoulVoice Cookie 无效或已过期。", response.status_code

    async def account_stats(self) -> tuple[int, int, float | None]:
        if not getattr(self, "cookie", None):
            raise SiteAdapterError("SoulVoice 需要 Cookie，请先在站点设置中填写。")
        response = await self.request(
            "GET",
            f"{self.base_url.rstrip('/')}/index.php",
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            raise_for_status=False,
        )
        if response.status_code != 200:
            raise SiteAdapterError(f"SoulVoice 账户信息获取失败：HTTP {response.status_code}。")
        if not self.is_logged_in(response.text):
            raise SiteAdapterError("SoulVoice Cookie 无效或已过期。")
        return self.parse_account_stats_html(response.text)

    @staticmethod
    def parse_account_stats_html(html: str) -> tuple[int, int, float | None]:
        prepared = unescape(html)
        upload_match = re.search(
            r"[^总]上[传傳]量?[:：_<>/a-zA-Z\-=\"'\s#;]+([\d,.\s]+[KMGTPI]*B)",
            prepared,
            flags=re.I,
        )
        download_match = re.search(
            r"[^总子影力]下[载載]量?[:：_<>/a-zA-Z\-=\"'\s#;]+([\d,.\s]+[KMGTPI]*B)",
            prepared,
            flags=re.I,
        )
        if not upload_match or not download_match:
            raise SiteAdapterError("SoulVoice 账户页面缺少上传或下载数据。")
        uploaded = coerce_size_bytes(upload_match.group(1).strip())
        downloaded = coerce_size_bytes(download_match.group(1).strip())
        if uploaded is None or downloaded is None:
            raise SiteAdapterError("SoulVoice 账户流量数据格式异常。")
        ratio_match = re.search(r"分享率[:：_<>/a-zA-Z\-=\"'\s#;]+([\d,.]+)", prepared)
        ratio = float(ratio_match.group(1).replace(",", "")) if ratio_match else (uploaded / downloaded if downloaded else None)
        return uploaded, downloaded, ratio

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        if not getattr(self, "cookie", None):
            raise SiteAdapterError("SoulVoice 需要 Cookie，请先在站点设置中填写。")
        page = max(1, page)
        params = f"search={quote_plus(keyword.strip())}&search_area=0&search_mode=0&page={page - 1}"
        url = f"{self.base_url.rstrip('/')}/torrents.php?{params}"
        response = await self.request(
            "GET",
            url,
            headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        )
        results = self.parse_search_html(response.text)
        has_more = self.has_next_page(response.text, page) or len(results) >= self.default_page_size
        return results, has_more

    def parse_search_html(self, html: str) -> list[SearchResult]:
        parser = _SoulVoiceTableParser()
        parser.feed(html)
        results: list[SearchResult] = []
        for row in parser.resource_rows:
            if not row.title or not row.detail_href or len(row.cells) < 9:
                continue
            title = strip_html(row.title)
            if not title:
                continue
            detail_url = absolute_url(self.base_url, row.detail_href)
            download_url = absolute_url(self.base_url, row.download_href)
            category = next((value for value in row.cells[0].descriptors if value and value not in {"poster"}), None)
            published = next(
                (match.group(0) for value in row.cells[3].descriptors for match in [_PUBLISHED_RE.search(value)] if match),
                None,
            )
            size_match = _SIZE_RE.search(row.cells[4].text)
            title_cell_text = row.cells[1].text
            metadata = pt_metadata_from_text(title_cell_text)
            subtitle = self.normalize_subtitle(row.subtitle, title)
            free_remaining_match = re.search(r"剩余时间[：:]?\s*([^\s]+)", title_cell_text, flags=re.I)
            descriptor_text = " ".join(value for cell in row.cells for value in cell.descriptors)
            promotion_label = self.promotion_label(descriptor_text, title_cell_text)
            results.append(
                SearchResult(
                    id=stable_result_id(self.id, title, download_url, detail_url),
                    title=title,
                    subtitle=subtitle,
                    published_at=published,
                    size=size_match.group(0) if size_match else None,
                    size_bytes=coerce_size_bytes(size_match.group(0)) if size_match else None,
                    category=category,
                    language=metadata.get("language") if isinstance(metadata.get("language"), str) else None,
                    is_free=True if promotion_label else None,
                    discount_label=promotion_label,
                    free_remaining=free_remaining_match.group(1) if free_remaining_match else None,
                    seeders=coerce_int(row.cells[5].text),
                    leechers=coerce_int(row.cells[6].text),
                    downloads=coerce_int(row.cells[7].text),
                    hit_and_run=True,
                    download_url=download_url,
                    magnet_url=None,
                    source=self.id,
                    detail_url=detail_url,
                    source_url=f"soulvoice:{row.torrent_id}" if row.torrent_id else None,
                )
            )
        return results

    async def parse_rss(self, rss_text: str) -> list[SearchResult]:
        results = await super().parse_rss(rss_text)
        normalized: list[SearchResult] = []
        for result in results:
            title, subtitle = self.split_rss_title(result.title)
            normalized.append(
                result.model_copy(
                    update={
                        "title": title,
                        "subtitle": self.normalize_subtitle(subtitle, title),
                        "description": None,
                        "hit_and_run": True,
                    }
                )
            )
        return normalized

    @staticmethod
    def normalize_subtitle(value: str | None, title: str) -> str | None:
        subtitle = clean_optional(value)
        if not subtitle:
            return None
        return None if subtitle.casefold() == clean_optional(title).casefold() else subtitle

    @staticmethod
    def split_rss_title(value: str) -> tuple[str, str | None]:
        title = clean_optional(value) or "未命名资源"
        depth = 0
        suffix_start: int | None = None
        for index, character in enumerate(title):
            if character == "[":
                if depth == 0:
                    suffix_start = index
                depth += 1
            elif character == "]" and depth > 0:
                depth -= 1
                if depth == 0 and index != len(title) - 1:
                    suffix_start = None
        if depth == 0 and suffix_start is not None and title.endswith("]"):
            base = clean_optional(title[:suffix_start])
            subtitle = clean_optional(title[suffix_start + 1 : -1])
            if base:
                return base, subtitle
        return title, None

    @staticmethod
    def promotion_label(descriptor_text: str, visible_text: str) -> str | None:
        combined = f"{descriptor_text} {visible_text}"
        if re.search(r"\bFree\b|免费|限免", combined, flags=re.I):
            return "FREE"
        for value in ("50%", "30%"):
            if re.search(rf"(?<!\d){re.escape(value)}(?!\d)", descriptor_text):
                return value
        return None

    async def enrich_rss_preview_results(self, results: list[SearchResult], *, limit: int = 20) -> list[SearchResult]:
        candidates = results[:limit]
        if not candidates or all(
            result.seeders is not None and result.leechers is not None and result.downloads is not None
            for result in candidates
        ):
            return results
        try:
            response = await self.request(
                "GET",
                f"{self.base_url.rstrip('/')}/torrents.php",
                headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
            )
            browse_results = self.parse_search_html(response.text)
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
            torrent_id = self.torrent_id_from_result(result)
            metadata = metadata_by_id.get(torrent_id or "")
            if metadata is None:
                enriched.append(result)
                continue
            enriched.append(
                result.model_copy(
                    update={
                        "subtitle": result.subtitle or metadata.subtitle,
                        "description": None,
                        "category": result.category or metadata.category,
                        "language": result.language or metadata.language,
                        "is_free": metadata.is_free if metadata.is_free is not None else result.is_free,
                        "discount_label": metadata.discount_label or result.discount_label,
                        "free_remaining": metadata.free_remaining or result.free_remaining,
                        "seeders": metadata.seeders if metadata.seeders is not None else result.seeders,
                        "leechers": metadata.leechers if metadata.leechers is not None else result.leechers,
                        "downloads": metadata.downloads if metadata.downloads is not None else result.downloads,
                    }
                )
            )
        return enriched

    def torrent_id_from_result(self, result: SearchResult) -> str | None:
        for value in (result.source_url, result.detail_url, result.download_url):
            if not value:
                continue
            match = re.search(r"(?:soulvoice:|(?:details|download)\.php\?id=)(\d+)", value, flags=re.I)
            if match:
                return match.group(1)
        return None

    def has_next_page(self, html: str, page: int) -> bool:
        for href in re.findall(r"""href=['"]([^'"]+)['"]""", unescape(html), flags=re.I):
            parsed = urlparse(href)
            if not parsed.path.lower().endswith("torrents.php"):
                continue
            if str(page) in parse_qs(parsed.query).get("page", []):
                return True
        return False

    def is_logged_in(self, html: str) -> bool:
        compact = html.lower()
        if re.search(r"""<input[^>]+type=['"]password['"]""", compact):
            return False
        return any(marker in compact for marker in ["logout", "userdetails.php", "mybonus", "messages.php", "usercp.php"])

    async def download_torrent(self, result: SearchResult) -> tuple[bytes, str]:
        if not result.download_url:
            raise SiteAdapterError("SoulVoice 下载失败：资源没有下载链接。")
        response = await self.request(
            "GET",
            result.download_url,
            headers={"Accept": "application/x-bittorrent,*/*", "Referer": result.detail_url or self.base_url},
        )
        return response.content, torrent_filename(result)
