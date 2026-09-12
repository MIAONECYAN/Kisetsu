from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
from urllib.parse import quote_plus, urlparse

from app.models import SearchResult
from app.sites.base import BaseSiteAdapter, absolute_url, stable_result_id, strip_html


@dataclass
class MikanBangumiResourceGroup:
    id: str
    name: str
    resources: list[SearchResult] = field(default_factory=list)


class _MikanBangumiGroupParser(HTMLParser):
    def __init__(self, base_url: str, bangumi_id: str | None) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.bangumi_id = bangumi_id
        self.groups: list[MikanBangumiResourceGroup] = []
        self._groups_by_id: dict[str, MikanBangumiResourceGroup] = {}
        self._tag_stack: list[str] = []
        self._heading_depth = 0
        self._heading_id: str | None = None
        self._heading_direct_text: list[str] = []
        self._heading_link_text: list[str] = []
        self._capturing_heading_link = False
        self._active_group: MikanBangumiResourceGroup | None = None
        self._episode_table_depth = 0
        self._row: dict[str, object] | None = None
        self._capturing_title = False
        self._seen_episode_ids: set[str] = set()

    @staticmethod
    def _classes(attrs: dict[str, str | None]) -> set[str]:
        return {value for value in (attrs.get("class") or "").split() if value}

    @staticmethod
    def _clean_text(parts: list[str]) -> str:
        return re.sub(r"\s+", " ", " ".join(parts)).strip()

    def handle_starttag(self, tag: str, attrs_list: list[tuple[str, str | None]]) -> None:
        attrs = dict(attrs_list)
        classes = self._classes(attrs)
        self._tag_stack.append(tag)

        if tag == "div" and "subgroup-text" in classes and attrs.get("id"):
            self._heading_depth = 1
            self._heading_id = str(attrs["id"])
            self._heading_direct_text = []
            self._heading_link_text = []
            self._capturing_heading_link = False
            return
        if self._heading_depth:
            if tag == "div":
                self._heading_depth += 1
            href = attrs.get("href") or ""
            if tag == "a" and "/Home/PublishGroup/" in href:
                self._capturing_heading_link = True
                self._heading_link_text = []
            return

        if tag == "div" and "episode-table" in classes and self._active_group is not None:
            self._episode_table_depth = 1
            return
        if self._episode_table_depth and tag == "div":
            self._episode_table_depth += 1

        if self._episode_table_depth and tag == "tr":
            self._row = {"texts": [], "title_parts": []}
            self._capturing_title = False
            return
        if self._row is None:
            return

        data_magnet = attrs.get("data-magnet") or attrs.get("data-clipboard-text") or ""
        if data_magnet.startswith("magnet:?"):
            self._row["magnet_url"] = data_magnet

        href = attrs.get("href") or ""
        if tag == "a" and "magnet-link-wrap" in classes and "/Home/Episode/" in href:
            self._row["detail_url"] = absolute_url(self.base_url, href)
            self._capturing_title = True
        elif tag == "a" and re.search(r"/(?:Download|Torrent)/.*?\.torrent(?:$|\?)", href, flags=re.I):
            self._row["download_url"] = absolute_url(self.base_url, href)

    def handle_data(self, data: str) -> None:
        if self._heading_depth:
            if self._capturing_heading_link:
                self._heading_link_text.append(data)
            elif self._heading_depth == 1 and self._tag_stack and self._tag_stack[-1] == "div":
                self._heading_direct_text.append(data)
            return
        if self._row is None:
            return
        texts = self._row["texts"]
        assert isinstance(texts, list)
        texts.append(data)
        if self._capturing_title:
            title_parts = self._row["title_parts"]
            assert isinstance(title_parts, list)
            title_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if self._heading_depth:
            if tag == "a" and self._capturing_heading_link:
                self._capturing_heading_link = False
            if tag == "div":
                self._heading_depth -= 1
                if self._heading_depth == 0:
                    self._finish_heading()
            self._pop_tag(tag)
            return

        if self._row is not None and tag == "a":
            self._capturing_title = False
        if self._row is not None and tag == "tr":
            self._finish_row()
        if self._episode_table_depth and tag == "div":
            self._episode_table_depth -= 1
        self._pop_tag(tag)

    def _pop_tag(self, tag: str) -> None:
        if self._tag_stack and self._tag_stack[-1] == tag:
            self._tag_stack.pop()
            return
        for index in range(len(self._tag_stack) - 1, -1, -1):
            if self._tag_stack[index] == tag:
                del self._tag_stack[index:]
                return

    def _finish_heading(self) -> None:
        group_id = self._heading_id or ""
        name = self._clean_text(self._heading_link_text) or self._clean_text(self._heading_direct_text)
        if group_id:
            group = self._groups_by_id.get(group_id)
            if group is None:
                group = MikanBangumiResourceGroup(id=group_id, name=name or "未知字幕组")
                self._groups_by_id[group_id] = group
                self.groups.append(group)
            elif name and group.name == "未知字幕组":
                group.name = name
            self._active_group = group
        self._heading_id = None
        self._heading_direct_text = []
        self._heading_link_text = []

    def _finish_row(self) -> None:
        row = self._row or {}
        self._row = None
        self._capturing_title = False
        if self._active_group is None:
            return
        title_parts = row.get("title_parts")
        title = self._clean_text(title_parts if isinstance(title_parts, list) else [])
        detail_url = str(row.get("detail_url") or "")
        episode_match = re.search(r"/Home/Episode/([A-Fa-f0-9]{32,64})", detail_url, flags=re.I)
        if not title or not episode_match:
            return
        episode_id = episode_match.group(1)
        if episode_id in self._seen_episode_ids:
            return
        self._seen_episode_ids.add(episode_id)

        texts = row.get("texts")
        row_text = self._clean_text(texts if isinstance(texts, list) else [])
        size_match = re.search(r"(\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB))", row_text, flags=re.I)
        date_match = re.search(
            r"(\d{4}[-/]\d{2}[-/]\d{2}(?:\s+\d{1,2}:\d{2})?|\d{1,2}/\d{1,2}/\d{4}(?:\s+\d{1,2}:\d{2}\s*(?:AM|PM)?)?)",
            row_text,
            flags=re.I,
        )
        download_url = str(row.get("download_url") or "") or None
        magnet_url = str(row.get("magnet_url") or "") or None
        bangumi_url = f"{self.base_url}/Home/Bangumi/{self.bangumi_id}" if self.bangumi_id else None
        self._active_group.resources.append(
            SearchResult(
                id=stable_result_id("mikan", title, magnet_url or download_url, detail_url),
                title=title,
                published_at=date_match.group(1) if date_match else None,
                size=size_match.group(1) if size_match else None,
                download_url=download_url,
                magnet_url=magnet_url,
                source="mikan",
                detail_url=detail_url,
                source_url=detail_url,
                mikan_episode_id=episode_id,
                mikan_bangumi_id=self.bangumi_id,
                mikan_group_id=self._active_group.id,
                mikan_group_name=self._active_group.name,
                bangumi_url=bangumi_url,
                bangumi_id=self.bangumi_id,
            )
        )


class MikanAdapter(BaseSiteAdapter):
    id = "mikan"
    name = "蜜柑计划"
    display_name = "蜜柑计划 / Mikan"
    base_url = "https://mikanani.me"
    supports_pagination = True
    default_page_size = 30
    max_recommended_pages = 10

    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        results, _ = await self.search_page(keyword, page=1, page_size=limit)
        return results[:limit]

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        episode_id = self.episode_id_from_keyword(keyword)
        if episode_id:
            html = await self.fetch_text(f"{self.base_url}/Home/Episode/{episode_id}")
            result = self.parse_episode_html(html, f"{self.base_url}/Home/Episode/{episode_id}")
            return ([result], False) if result and page <= 1 else ([], False)
        bangumi_id = self.bangumi_id_from_keyword(keyword)
        if bangumi_id:
            html = await self.fetch_text(f"{self.base_url}/Home/Bangumi/{bangumi_id}")
            parsed_groups = self.parse_bangumi_groups(html, bangumi_id)
            group_id = self.bangumi_group_id_from_keyword(keyword)
            if group_id:
                groups = [group for group in parsed_groups if group.id == group_id]
                results = [resource for group in groups for resource in group.resources]
            elif parsed_groups:
                results = [resource for group in parsed_groups for resource in group.resources]
            else:
                results = self.parse_search_html(html)
            return (results, False) if page <= 1 else ([], False)
        url = f"{self.base_url}/Home/Search?searchstr={quote_plus(keyword)}&page={page}"
        html = await self.fetch_text(url)
        results = self.parse_search_html(html)
        has_more = self.has_next_page(html, page)
        return results, has_more

    async def parse_rss(self, rss_text: str) -> list[SearchResult]:
        try:
            return await super().parse_rss(rss_text)
        except ET.ParseError:
            return self.parse_bangumi_html(rss_text)

    def bangumi_id_from_keyword(self, keyword: str) -> str | None:
        value = keyword.strip()
        if not value:
            return None
        if value.isdigit():
            return value
        parsed = urlparse(value)
        path = parsed.path if parsed.scheme else value
        match = re.search(r"/Home/Bangumi/(\d+)", path, flags=re.I)
        return match.group(1) if match else None

    def bangumi_group_id_from_keyword(self, keyword: str) -> str | None:
        value = keyword.strip()
        if not value:
            return None
        parsed = urlparse(value)
        fragment = parsed.fragment.strip()
        return fragment if fragment.isdigit() else None

    def episode_id_from_keyword(self, keyword: str) -> str | None:
        value = keyword.strip()
        if not value:
            return None
        parsed = urlparse(value)
        path = parsed.path if parsed.scheme else value
        match = re.search(r"/Home/Episode/([A-Fa-f0-9]{32,64})", path, flags=re.I)
        if match:
            return match.group(1)
        if re.fullmatch(r"[A-Fa-f0-9]{40}", value):
            return value
        return None

    def total_episodes_from_html(self, html: str) -> int | None:
        text = strip_html(html)
        match = re.search(r"总集数[:：]\s*(\d+)", text)
        return int(match.group(1)) if match else None

    def has_next_page(self, html: str, page: int) -> bool:
        next_page = page + 1
        patterns = [
            rf"""href=['"][^'"]*?[?&]page={next_page}(?:&[^'"]*)?['"]""",
            rf"""href=['"][^'"]*?/page/{next_page}(?:\?[^'"]*)?['"]""",
            rf"""data-page=['"]{next_page}['"]""",
        ]
        return any(re.search(pattern, html, flags=re.I) for pattern in patterns)

    def parse_bangumi_html(self, html: str) -> list[SearchResult]:
        groups = self.parse_bangumi_groups(html)
        if groups:
            return [resource for group in groups for resource in group.resources]
        return self.parse_search_html(html)

    def parse_bangumi_groups(self, html: str, bangumi_id: str | None = None) -> list[MikanBangumiResourceGroup]:
        resolved_bangumi_id = bangumi_id
        if resolved_bangumi_id is None:
            match = re.search(r"/RSS/Bangumi\?bangumiId=(\d+)", html, flags=re.I)
            resolved_bangumi_id = match.group(1) if match else None
        parser = _MikanBangumiGroupParser(self.base_url, resolved_bangumi_id)
        parser.feed(html)
        parser.close()
        return [group for group in parser.groups if group.resources]

    def parse_episode_html(self, html: str, detail_url: str | None = None) -> SearchResult | None:
        title_match = re.search(r"<title>(.*?)</title>", html, flags=re.I | re.S)
        title = strip_html(unescape(title_match.group(1))) if title_match else ""
        title = re.sub(r"\s*-\s*Mikan Project\s*$", "", title, flags=re.I).strip()
        text = strip_html(html)
        if not title:
            title_line = re.search(r"(?:Top\s*)?(\[[^\]]+\].+?)(?:\s*\[\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB)\])", text, flags=re.I)
            title = title_line.group(1).strip() if title_line else ""
        if not title:
            return None

        download_match = re.search(r"""href=['"]([^'"]*?/Download/[^'"]+?\.torrent)['"]""", html, flags=re.I)
        magnet_match = re.search(r"""(magnet:\?xt=[^'"<>\s]+)""", html, flags=re.I)
        bangumi_match = re.search(r"""href=['"]([^'"]*?/Home/Bangumi/(?P<id>\d+)(?:#[^'"]*)?)['"]""", html, flags=re.I)
        episode_match = re.search(r"/Home/Episode/([A-Fa-f0-9]{32,64})", detail_url or "", flags=re.I)
        if not episode_match and download_match:
            episode_match = re.search(r"/Download/\d+/([A-Fa-f0-9]{32,64})\.torrent", download_match.group(1), flags=re.I)
        size_match = re.search(r"文件大小[:：]\s*(\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB))", text, flags=re.I)
        if not size_match:
            size_match = re.search(r"\[(\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB))\]", text, flags=re.I)
        published_match = re.search(r"发布日期[:：]\s*(.+?)(?:\s+文件大小[:：]|\s+下载种子|\s+磁力链接|\s+在线播放|\s+订阅番组)", text, flags=re.I)

        download_url = absolute_url(self.base_url, download_match.group(1)) if download_match else None
        bangumi_url = absolute_url(self.base_url, bangumi_match.group(1)) if bangumi_match else None
        magnet_url = unescape(magnet_match.group(1)) if magnet_match else None
        episode_id = episode_match.group(1) if episode_match else None
        return SearchResult(
            id=stable_result_id(self.id, title, magnet_url or download_url, detail_url),
            title=title,
            published_at=published_match.group(1).strip() if published_match else None,
            size=size_match.group(1) if size_match else None,
            download_url=download_url,
            magnet_url=magnet_url,
            source=self.id,
            detail_url=detail_url,
            source_url=detail_url,
            mikan_episode_id=episode_id,
            mikan_bangumi_id=bangumi_match.group("id") if bangumi_match else None,
            bangumi_url=bangumi_url,
            bangumi_id=bangumi_match.group("id") if bangumi_match else None,
        )

    def parse_search_html(self, html: str) -> list[SearchResult]:
        blocks = re.findall(r"<tr\b[^>]*>(.*?)</tr>|<div\b[^>]*class=['\"][^'\"]*js-search-results-row[^'\"]*['\"][^>]*>(.*?)</div>", html, flags=re.I | re.S)
        candidates = [a or b for a, b in blocks]
        if not candidates:
            candidates = re.findall(r"(<a[^>]+href=['\"][^'\"]*(?:Episode|Download|Torrent)[^'\"]*['\"][^>]*>.*?</a>(?:.*?(?:\d{4}[-/]\d{2}[-/]\d{2}|\d{1,2}/\d{1,2}/\d{4}))?)", html, flags=re.I | re.S)

        results: list[SearchResult] = []
        for block in candidates:
            link_match = re.search(r"""<a[^>]+href=['"]([^'"]+)['"][^>]*>(.*?)</a>""", block, flags=re.I | re.S)
            if not link_match:
                continue
            href = link_match.group(1)
            title = strip_html(link_match.group(2))
            if not title:
                continue
            magnet_match = re.search(r"""(?:href|data-clipboard-text)=['"](magnet:\?xt=[^'"]+)['"]""", block, flags=re.I)
            torrent_match = re.search(r"""href=['"]([^'"]*?(?:Download|Torrent)[^'"]*)['"]""", block, flags=re.I)
            detail_url = absolute_url(self.base_url, href)
            download_url = absolute_url(self.base_url, torrent_match.group(1)) if torrent_match else None
            magnet_url = magnet_match.group(1) if magnet_match else None
            text = strip_html(block)
            size_match = re.search(r"(\d+(?:\.\d+)?\s*(?:GB|GiB|MB|MiB))", text, flags=re.I)
            date_match = re.search(r"(\d{4}[-/]\d{2}[-/]\d{2}(?:\s+\d{2}:\d{2})?|\d{1,2}/\d{1,2}/\d{4}(?:\s+\d{1,2}:\d{2}\s*(?:AM|PM)?)?)", text, flags=re.I)
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
