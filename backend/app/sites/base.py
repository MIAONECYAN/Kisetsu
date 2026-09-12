from __future__ import annotations

import hashlib
import re
import xml.etree.ElementTree as ET
from abc import ABC, abstractmethod
from html import unescape
from collections.abc import Iterable
from datetime import datetime, timezone
from urllib.parse import urlencode, urljoin, urlparse

import httpx

from app.models import SearchResult, SiteInfo, SiteSettingsUpdate
from app.settings import mask_secret, mask_url_secret
from app.sites.rate_limiter import RateLimitedHttpClient, SiteRateLimitPolicy, rate_limit_policy_for_site, site_rate_limiter


PROTECTED_SITE_HEADERS = {"authorization", "cookie", "x-api-key", "user-agent"}
MTEAM_CATEGORY_LABELS = {
    "401": "Movie(電影)/SD",
    "402": "Movie(電影)/HD",
    "403": "Movie(電影)/DVDiSo",
    "404": "Movie(電影)/Blu-Ray",
    "405": "Anime(動畫)",
    "406": "TV Series(影劇/綜藝)/SD",
    "407": "TV Series(影劇/綜藝)/HD",
    "408": "紀錄教育",
    "409": "Music(音樂)",
    "410": "Sport(體育)",
    "419": "Movie(電影)/Remux",
    "420": "Movie(電影)/UHD",
    "421": "Movie(電影)/WEB-DL",
    "435": "TV Series(影劇/綜藝)/DVDiSo",
    "438": "TV Series(影劇/綜藝)/BD",
    "439": "Movie(電影)/Blu-Ray",
}
MTEAM_CATEGORY_ALIASES = {
    "动画": "Anime(動畫)",
    "動畫": "Anime(動畫)",
    "Movie/SD": "Movie(電影)/SD",
    "Movie/HD": "Movie(電影)/HD",
    "Movie/DVDISO": "Movie(電影)/DVDiSo",
    "Movie/DVDiSo": "Movie(電影)/DVDiSo",
    "Movie/Blu-ray": "Movie(電影)/Blu-Ray",
    "Movie/Blu-Ray": "Movie(電影)/Blu-Ray",
    "Movie/Remux": "Movie(電影)/Remux",
    "Anime": "Anime(動畫)",
    "TV Series/SD": "TV Series(影劇/綜藝)/SD",
    "TV Series/HD": "TV Series(影劇/綜藝)/HD",
    "TV Series/DVDISO": "TV Series(影劇/綜藝)/DVDiSo",
    "TV Series/DVDiSo": "TV Series(影劇/綜藝)/DVDiSo",
    "TV Series/BD": "TV Series(影劇/綜藝)/BD",
    "Documentary": "紀錄教育",
    "Music": "Music(音樂)",
    "Sport": "Sport(體育)",
}
MTEAM_RSS_CATEGORIES = [
    "Movie(電影)/SD",
    "Movie(電影)/HD",
    "Movie(電影)/DVDiSo",
    "Movie(電影)/Blu-Ray",
    "Movie(電影)/Remux",
    "Anime(動畫)",
    "紀錄教育",
    "TV Series(影劇/綜藝)/SD",
    "TV Series(影劇/綜藝)/HD",
    "TV Series(影劇/綜藝)/DVDiSo",
    "TV Series(影劇/綜藝)/BD",
    "AV(有碼)/HD Censored",
]
SITE_CATEGORY_LABELS = {
    "mteam": MTEAM_CATEGORY_LABELS,
}
SITE_CATEGORY_ALIASES = {
    "mteam": MTEAM_CATEGORY_ALIASES,
}
SITE_RSS_CATEGORIES = {
    "mteam": MTEAM_RSS_CATEGORIES,
}


class SiteAdapterError(RuntimeError):
    pass


class SiteRateLimitError(SiteAdapterError):
    pass


def describe_site_error(exc: BaseException) -> str:
    if isinstance(exc, SiteAdapterError):
        return str(exc) or "站点适配器返回错误"
    if isinstance(exc, ET.ParseError):
        return "RSS 内容无法解析，请检查订阅地址是否有效。"
    if isinstance(exc, httpx.TimeoutException):
        return "站点请求超时，请稍后重试。"
    if isinstance(exc, httpx.ConnectError):
        return "无法连接站点，请检查网络或站点可用性。"
    if isinstance(exc, httpx.HTTPStatusError):
        status_code = exc.response.status_code
        if status_code in {403, 429}:
            return "站点可能触发访问限制，请稍后再试；Kisetsu 会自动放慢请求速度。"
        if status_code == 401:
            return "站点拒绝访问，可能需要登录或受到访问限制。"
        if status_code == 404:
            return "站点页面不存在或 RSS 地址无效。"
        return f"站点返回 HTTP {status_code}，请稍后重试。"
    if isinstance(exc, httpx.RequestError):
        return "站点网络请求失败，请检查网络或代理设置。"
    return "站点请求失败，请稍后重试或检查站点配置。"


def strip_html(value: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", unescape(value))).strip()


def stable_result_id(source: str, title: str, download_url: str | None, detail_url: str | None) -> str:
    payload = "|".join([source, title, download_url or "", detail_url or ""])
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:16]


def first_text(node: ET.Element, names: list[str]) -> str | None:
    for name in names:
        child = node.find(name)
        if child is not None and child.text:
            return child.text.strip()
    return None


def first_dict_value(data: dict, keys: Iterable[str]) -> object | None:
    lower_map = {str(key).lower(): value for key, value in data.items()}
    for key in keys:
        key_text = key.lower()
        if "." in key_text:
            current: object = data
            for part in key_text.split("."):
                if not isinstance(current, dict):
                    current = None
                    break
                part_map = {str(nested_key).lower(): nested_value for nested_key, nested_value in current.items()}
                current = part_map.get(part)
            value = current
        else:
            value = lower_map.get(key_text)
        if value not in (None, ""):
            return value
    return None


def coerce_int(value: object) -> int | None:
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    match = re.search(r"\d+", str(value).replace(",", ""))
    return int(match.group(0)) if match else None


def coerce_float(value: object) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    match = re.search(r"-?\d+(?:\.\d+)?", str(value).replace(",", ""))
    return float(match.group(0)) if match else None


def coerce_bool(value: object) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    text = str(value).strip().lower()
    if not text:
        return None
    if text in {"1", "true", "yes", "free", "免费", "限免", "percent_0", "discount_free"}:
        return True
    if text.startswith("percent_"):
        return True
    if text in {"0", "false", "no", "normal"}:
        return False
    return True if "free" in text or "免费" in text else None


def bytes_to_size(value: object) -> str | None:
    if isinstance(value, str) and re.search(r"\b(?:KiB|MiB|GiB|TiB|KB|MB|GB|TB|PB)\b", value, flags=re.I):
        return value.strip()
    size = coerce_int(value)
    if size is None:
        return None
    units = ["B", "KB", "MB", "GB", "TB"]
    number = float(size)
    unit = units[0]
    for unit in units:
        if number < 1024 or unit == units[-1]:
            break
        number /= 1024
    if unit == "B":
        return f"{int(number)} B"
    return f"{number:.2f} {unit}"


def coerce_size_bytes(value: object) -> int | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    text = str(value).strip().replace(",", "")
    match = re.search(r"([\d.]+)\s*(B|KB|KIB|MB|MIB|GB|GIB|TB|TIB)\b", text, flags=re.I)
    if not match:
        return coerce_int(value)
    powers = {"B": 0, "KB": 1, "KIB": 1, "MB": 2, "MIB": 2, "GB": 3, "GIB": 3, "TB": 4, "TIB": 4}
    return int(float(match.group(1)) * (1024 ** powers[match.group(2).upper()]))


def clean_optional(value: object) -> str | None:
    if value is None:
        return None
    text = strip_html(str(value))
    return text or None


def clean_label_list(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        parts = [clean_optional(item) for item in value]
        language_re = re.compile(r"(中字|中英|简中|繁中|CHS|CHT|ENG|字幕|日语|国语|粤语)", re.I)
        language_parts = [part for part in parts if part and language_re.search(part)]
        parts = language_parts or [part for part in parts if part and not re.fullmatch(r"\d+k|2160p|1080p|720p", part, flags=re.I)]
        return " · ".join(parts) if parts else None
    return clean_optional(value)


def category_label(site_id: str | None, value: object) -> str | None:
    text = clean_optional(value)
    if not text:
        return None
    aliases = SITE_CATEGORY_ALIASES.get(site_id or "")
    if aliases and text in aliases:
        return aliases[text]
    mapping = SITE_CATEGORY_LABELS.get(site_id or "")
    if mapping and text in mapping:
        return mapping[text]
    return text if not text.isdigit() else None


def discount_label(value: object) -> str | None:
    if value in (None, ""):
        return None
    text = str(value).strip()
    upper = text.upper()
    if upper in {"FREE", "PERCENT_0", "DISCOUNT_FREE"}:
        return "FREE"
    percent = re.match(r"PERCENT[_-]?(\d+)", upper)
    if percent:
        value = percent.group(1)
        return "FREE" if value == "0" else f"{value}%"
    if upper in {"HALF", "HALF_DOWN"}:
        return "50%"
    if "免费" in text or "限免" in text:
        return "FREE"
    if "free" in text.lower():
        return "FREE"
    return text


def pt_free_remaining(value: object) -> str | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        timestamp = float(value)
        if timestamp > 10_000_000_000:
            timestamp /= 1000
        seconds = max(0, int(timestamp - datetime.now(timezone.utc).timestamp()))
        if seconds == 0:
            return None
        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        if hours >= 24:
            return f"{hours // 24}天{hours % 24}小时"
        if hours > 0:
            return f"{hours}小时{minutes}分钟"
        return f"{minutes}分钟"
    text = str(value).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            end = datetime.strptime(text, fmt)
            seconds = max(0, int((end - datetime.now()).total_seconds()))
            if seconds == 0:
                return None
            hours = seconds // 3600
            minutes = (seconds % 3600) // 60
            if hours >= 24:
                return f"{hours // 24}天{hours % 24}小时"
            if hours > 0:
                return f"{hours}小时{minutes}分钟"
            return f"{minutes}分钟"
        except ValueError:
            pass
    return text or None


def pt_metadata_from_dict(data: dict, site_id: str | None = None) -> dict[str, object | None]:
    discount_value = first_dict_value(
        data,
        [
            "discount",
            "discountType",
            "promotion",
            "spState",
            "status.discount",
            "status.free",
            "status.promotion",
        ],
    )
    is_free = coerce_bool(first_dict_value(data, ["is_free", "isFree", "free", "freeTorrent"])) or coerce_bool(discount_value)
    label = discount_label(discount_value)
    if label is None and is_free is True:
        label = "FREE"
    download_factor = coerce_float(first_dict_value(data, ["download_factor", "downloadFactor", "downloadvolumefactor", "status.downloadFactor"]))
    upload_factor = coerce_float(first_dict_value(data, ["upload_factor", "uploadFactor", "uploadvolumefactor", "status.uploadFactor"]))
    hit_and_run = coerce_bool(first_dict_value(data, ["hit_and_run", "hitAndRun", "hr", "isHr", "status.hitAndRun"]))
    if download_factor is None and label == "FREE":
        download_factor = 0.0
    if upload_factor is None and label and re.search(r"(?:2X|2倍|双倍)", label, flags=re.I):
        upload_factor = 2.0
    return {
        "subtitle": clean_optional(first_dict_value(data, ["small_descr", "smallDescr", "subtitle", "subTitle", "description", "descr", "labels", "overview"])),
        "category": category_label(site_id, first_dict_value(data, ["categoryName", "category", "typeName", "type", "cat", "medium", "mediaType"])),
        "language": clean_label_list(first_dict_value(data, ["labelsNew", "language", "lang", "subtitle_language", "subtitleLanguage"])),
        "is_free": is_free,
        "discount_label": label,
        "free_until": clean_optional(first_dict_value(data, ["free_until", "freeUntil", "free_deadline", "freeDeadline", "discountEndTime", "promotionUntil", "status.discountEndTime"])),
        "free_remaining": pt_free_remaining(first_dict_value(data, ["free_remaining", "freeRemaining", "freeTime", "freeLeft", "freeUntil", "discountEndTime", "promotionUntil", "status.discountEndTime"])),
        "seeders": coerce_int(first_dict_value(data, ["seeders", "seeder", "seeds", "seed", "uploadCount", "seedCount", "status.seeders"])),
        "leechers": coerce_int(first_dict_value(data, ["leechers", "leecher", "peers", "peer", "downloadCount", "leechCount", "status.leechers"])),
        "downloads": coerce_int(first_dict_value(data, ["downloads", "downloaded", "completed", "snatches", "finish", "finishCount", "timesCompleted", "times_completed", "status.timesCompleted"])),
        "size_bytes": coerce_size_bytes(first_dict_value(data, ["size", "sizeBytes", "totalSize", "status.size"])),
        "download_factor": download_factor,
        "upload_factor": upload_factor,
        "hit_and_run": hit_and_run,
    }


def pt_metadata_from_text(text: str) -> dict[str, object | None]:
    plain = strip_html(text)
    size_match = re.search(r"(\d+(?:\.\d+)?\s*(?:KiB|MiB|GiB|TiB|KB|MB|GB|TB))", plain, flags=re.I)
    seed_match = re.search(r"(?:做种|seed(?:er)?s?)[:：\s]*(\d+)", plain, flags=re.I)
    leech_match = re.search(r"(?:下载|leech(?:er)?s?|peers?)[:：\s]*(\d+)", plain, flags=re.I)
    complete_match = re.search(r"(?:完成|completed|snatches?)[:：\s]*(\d+)", plain, flags=re.I)
    free_match = re.search(r"(free|免费|限免)(?:\s*([^\s，,；;]+))?", plain, flags=re.I)
    percent_match = re.search(r"(?:percent[_-]?(\d+)|(\d{1,3})\s*%\s*(?:free|免费)?)", plain, flags=re.I)
    language_match = re.search(r"(中字|中英|简中|繁中|CHS|CHT|ENG|日语|国语|粤语)", plain, flags=re.I)
    label = "FREE" if free_match else (f"{percent_match.group(1) or percent_match.group(2)}%" if percent_match else None)
    return {
        "subtitle": None,
        "description": plain if plain else None,
        "language": language_match.group(1) if language_match else None,
        "is_free": bool(free_match or percent_match) if free_match or percent_match else None,
        "discount_label": label,
        "free_remaining": free_match.group(2) if free_match and free_match.lastindex else None,
        "seeders": coerce_int(seed_match.group(1)) if seed_match else None,
        "leechers": coerce_int(leech_match.group(1)) if leech_match else None,
        "downloads": coerce_int(complete_match.group(1)) if complete_match else None,
        "size": size_match.group(1) if size_match else None,
    }


def rss_items_to_results(source: str, rss_text: str) -> list[SearchResult]:
    root = ET.fromstring(rss_text)
    items = root.findall(".//item") or root.findall(".//{http://www.w3.org/2005/Atom}entry")
    results: list[SearchResult] = []
    for item in items:
        title = first_text(item, ["title", "{http://www.w3.org/2005/Atom}title"]) or "未命名资源"
        guid = first_text(item, ["guid", "{http://www.w3.org/2005/Atom}id"])
        page_link = first_text(item, ["link", "{http://www.w3.org/2005/Atom}link"]) or guid
        enclosure = item.find("enclosure")
        enclosure_url = None
        if enclosure is not None and enclosure.attrib.get("url"):
            enclosure_url = enclosure.attrib["url"]
        description = first_text(item, ["description", "summary", "{http://www.w3.org/2005/Atom}summary", "{http://www.w3.org/2005/Atom}content"])
        category = first_text(item, ["category"])
        text_metadata = pt_metadata_from_text(description or "")
        size = text_metadata.get("size")
        exact_size = None
        if enclosure is not None and enclosure.attrib.get("length"):
            exact_size = coerce_int(enclosure.attrib.get("length"))
            size = bytes_to_size(enclosure.attrib.get("length")) or size
        published = first_text(
            item,
            [
                "pubDate",
                "published",
                "updated",
                "{http://www.w3.org/2005/Atom}published",
                "{http://www.w3.org/2005/Atom}updated",
            ],
        )
        resource_url = enclosure_url or page_link
        magnet = resource_url if resource_url and resource_url.startswith("magnet:") else None
        download = None if magnet else resource_url
        detail_url = None if page_link and page_link.startswith("magnet:") else page_link
        source_url = f"{source}:{guid}" if guid and guid.isdigit() else None
        results.append(
            SearchResult(
                id=stable_result_id(source, title, download, detail_url),
                title=title,
                subtitle=text_metadata.get("subtitle") if isinstance(text_metadata.get("subtitle"), str) else None,
                description=text_metadata.get("description") if isinstance(text_metadata.get("description"), str) else None,
                published_at=published,
                size=size if isinstance(size, str) else None,
                size_bytes=exact_size,
                category=category_label(source, category) or (text_metadata.get("category") if isinstance(text_metadata.get("category"), str) else None),
                language=text_metadata.get("language") if isinstance(text_metadata.get("language"), str) else None,
                is_free=text_metadata.get("is_free") if isinstance(text_metadata.get("is_free"), bool) else None,
                discount_label=text_metadata.get("discount_label") if isinstance(text_metadata.get("discount_label"), str) else None,
                free_remaining=text_metadata.get("free_remaining") if isinstance(text_metadata.get("free_remaining"), str) else None,
                seeders=text_metadata.get("seeders") if isinstance(text_metadata.get("seeders"), int) else None,
                leechers=text_metadata.get("leechers") if isinstance(text_metadata.get("leechers"), int) else None,
                downloads=text_metadata.get("downloads") if isinstance(text_metadata.get("downloads"), int) else None,
                source=source,
                download_url=download,
                magnet_url=magnet,
                detail_url=detail_url,
                source_url=source_url,
            )
        )
    return results


def header_value(headers: dict[str, str] | None, name: str) -> str | None:
    target = name.lower()
    for key, value in (headers or {}).items():
        if key.lower() == target and value:
            return value
    return None


def merge_non_protected_headers(target: dict[str, str], source: dict[str, str] | None) -> None:
    for key, value in (source or {}).items():
        if key and value is not None and key.lower() not in PROTECTED_SITE_HEADERS:
            target[key] = value


class BaseSiteAdapter(ABC):
    id: str
    name: str
    base_url: str
    supports_pagination: bool = False
    default_page_size: int = 30
    max_recommended_pages: int = 5
    supports_brush: bool = False
    auth_mode: str = "none"
    auth_fields: list[str] = []
    rss_default_path: str | None = None
    rss_default_params: dict[str, int | str] = {}

    def info(self) -> SiteInfo:
        mirrors = list(getattr(self, "configured_mirrors", getattr(self, "fallback_base_urls", [])))
        api_key = getattr(self, "api_key", None)
        cookie = getattr(self, "cookie", None)
        passkey = getattr(self, "passkey", None)
        request_headers = getattr(self, "request_headers", {}) or {}
        authorization = getattr(self, "authorization", None) or header_value(request_headers, "Authorization")
        return SiteInfo(
            id=self.id,
            name=self.name,
            display_name=getattr(self, "display_name", self.name),
            base_url=self.base_url,
            primary_url=getattr(self, "primary_url", self.base_url),
            mirrors=mirrors,
            active_base_url=self.base_url,
            enabled=getattr(self, "enabled", True),
            brush_only=getattr(self, "brush_only", False),
            supports_brush=getattr(self, "supports_brush", False),
            auth_mode=getattr(self, "auth_mode", "none"),
            auth_fields=list(getattr(self, "auth_fields", [])),
            api_key_configured=bool(api_key),
            api_key_masked=mask_secret(api_key),
            cookie_configured=bool(cookie),
            cookie_masked=mask_secret(cookie),
            passkey_configured=bool(passkey),
            passkey_masked=mask_secret(passkey),
            authorization_configured=bool(authorization),
            authorization_masked=mask_secret(authorization),
            user_agent=getattr(self, "user_agent", None),
            timeout_seconds=getattr(self, "timeout_seconds", None),
            rss_url=None,
            rss_url_configured=bool(getattr(self, "rss_url", None)),
            rss_url_masked=mask_url_secret(getattr(self, "rss_url", None)),
            default_rss_url=self.default_rss_url(),
            request_headers_configured=bool(request_headers),
            request_headers_masked={
                key: mask_secret(value)
                for key, value in request_headers.items()
                if key.lower() not in PROTECTED_SITE_HEADERS
            },
        )

    async def fetch_text(self, url: str) -> str:
        return await RateLimitedHttpClient().fetch_text(
            self.id,
            url,
            self.rate_limit_policy(),
            headers=self.auth_headers(),
        )

    async def fetch_status(self, url: str) -> int:
        response = await RateLimitedHttpClient().request(
            self.id,
            url,
            self.rate_limit_policy(),
            headers=self.auth_headers(),
            timeout=float(getattr(self, "timeout_seconds", None) or 15),
            raise_for_status=False,
        )
        return response.status_code

    async def request(
        self,
        method: str,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        params: dict | None = None,
        data: dict | None = None,
        json: dict | None = None,
        raise_for_status: bool = True,
    ) -> httpx.Response:
        request_headers = self.auth_headers(headers)
        response = await RateLimitedHttpClient().request(
            self.id,
            url,
            self.rate_limit_policy(),
            method=method,
            headers=request_headers,
            params=params,
            data=data,
            json=json,
            timeout=float(getattr(self, "timeout_seconds", None) or 15),
            raise_for_status=raise_for_status,
        )
        return response

    def auth_headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        request_headers = getattr(self, "request_headers", None) or {}
        headers = {
            "User-Agent": getattr(self, "user_agent", None) or "Kisetsu/0.1",
            "Accept": "application/json, text/plain, */*",
        }
        merge_non_protected_headers(headers, request_headers)
        merge_non_protected_headers(headers, extra)
        cookie = getattr(self, "cookie", None) or header_value(request_headers, "Cookie")
        if cookie:
            headers["Cookie"] = cookie
        api_key = getattr(self, "api_key", None) or header_value(request_headers, "x-api-key")
        if api_key:
            headers["x-api-key"] = api_key
        authorization = getattr(self, "authorization", None) or header_value(request_headers, "Authorization")
        if authorization:
            headers["Authorization"] = authorization
        return headers

    async def test_connection(self) -> tuple[bool, str, int | None]:
        status = await self.fetch_status(self.base_url)
        if status < 500:
            return True, f"当前域名可访问，HTTP {status}。", status
        return False, f"当前域名返回 HTTP {status}，建议检查配置或换一个镜像。", status

    def rate_limit_policy(self) -> SiteRateLimitPolicy:
        return rate_limit_policy_for_site(self.id)

    async def backoff_after_access_limit(self, url: str, reason: str) -> None:
        await site_rate_limiter.backoff(self.id, url, self.rate_limit_policy(), reason=reason)

    @abstractmethod
    async def search(self, keyword: str, limit: int = 30) -> list[SearchResult]:
        raise NotImplementedError

    async def search_page(self, keyword: str, page: int = 1, page_size: int = 30) -> tuple[list[SearchResult], bool]:
        if page > 1 and not self.supports_pagination:
            return [], False
        results = await self.search(keyword, page_size)
        return results[:page_size], False

    async def parse_rss(self, rss_text: str) -> list[SearchResult]:
        return rss_items_to_results(self.id, rss_text)

    async def enrich_rss_preview_results(self, results: list[SearchResult], *, limit: int = 20) -> list[SearchResult]:
        return results

    async def preview_rss_resources(
        self,
        *,
        keyword: str | None = None,
        category: str | None = None,
        page: int = 1,
        page_size: int = 25,
    ) -> dict[str, object] | None:
        return None

    def rss_categories(self, results: list[SearchResult] | None = None) -> list[str]:
        configured = list(SITE_RSS_CATEGORIES.get(self.id, []))
        seen = set(configured)
        for result in results or []:
            category = (result.category or "").strip()
            if category and category not in seen:
                configured.append(category)
                seen.add(category)
        return configured

    def default_rss_url(self) -> str | None:
        path = getattr(self, "rss_default_path", None)
        if not path:
            return None
        url = urljoin(f"{self.base_url.rstrip('/')}/", path)
        params = getattr(self, "rss_default_params", {}) or {}
        if params:
            separator = "&" if "?" in url else "?"
            url = f"{url}{separator}{urlencode(params)}"
        return url

    def resolved_rss_url(self, explicit_url: str | None = None) -> str | None:
        value = explicit_url or getattr(self, "rss_url", None) or self.default_rss_url()
        return value.strip() if value and value.strip() else None

    async def download_torrent(self, result: SearchResult) -> tuple[bytes, str]:
        if not result.download_url:
            raise SiteAdapterError("资源没有可下载链接。")
        response = await self.request("GET", result.download_url)
        filename = torrent_filename(result)
        return response.content, filename


def torrent_filename(result: SearchResult) -> str:
    raw = re.sub(r"[\\/:*?\"<>|\x00-\x1f]+", " ", result.title).strip(" .")
    name = re.sub(r"\s+", " ", raw)[:120] or f"{result.source}-{result.id}"
    return name if name.lower().endswith(".torrent") else f"{name}.torrent"


def _default_site_adapter(site_id: str) -> BaseSiteAdapter:
    from .dmhy import DmhyAdapter
    from .hddolby import HDDolbyAdapter
    from .mikan import MikanAdapter
    from .mteam import MTeamAdapter
    from .nyaa import NyaaAdapter
    from .opencd import OpenCDAdapter
    from .soulvoice import SoulVoiceAdapter


    adapters: dict[str, BaseSiteAdapter] = {
        "dmhy": DmhyAdapter(),
        "mikan": MikanAdapter(),
        "nyaa": NyaaAdapter(),
        "mteam": MTeamAdapter(),
        "soulvoice": SoulVoiceAdapter(),
        "hddolby": HDDolbyAdapter(),
        "opencd": OpenCDAdapter(),
    }
    if site_id not in adapters:
        raise SiteAdapterError(f"暂不支持的站点：{site_id}")
    return adapters[site_id]


def default_site_settings() -> dict[str, SiteSettingsUpdate]:
    settings: dict[str, SiteSettingsUpdate] = {}
    for site_id in ("dmhy", "mikan", "nyaa", "mteam", "soulvoice", "hddolby", "opencd"):
        adapter = _default_site_adapter(site_id)
        info = adapter.info()
        settings[site_id] = SiteSettingsUpdate(
            display_name=info.display_name,
            primary_url=info.primary_url or info.base_url,
            mirrors=info.mirrors,
            active_base_url=info.active_base_url or info.base_url,
            enabled=info.enabled,
            brush_only=info.brush_only,
            user_agent=info.user_agent,
            timeout_seconds=info.timeout_seconds,
            rss_url=info.rss_url,
            authorization=None,
        )
    return settings


def merge_site_settings(raw_settings: dict | None = None) -> dict[str, SiteSettingsUpdate]:
    merged = default_site_settings()
    for site_id, payload in (raw_settings or {}).items():
        if site_id not in merged or not isinstance(payload, dict):
            continue
        default = merged[site_id]
        data = default.model_dump(mode="json")
        data.update({key: value for key, value in payload.items() if value is not None})
        merged[site_id] = SiteSettingsUpdate(**data)
    return merged


def _apply_settings(adapter: BaseSiteAdapter, settings: SiteSettingsUpdate) -> BaseSiteAdapter:
    primary = settings.primary_url or adapter.base_url
    active = settings.active_base_url or primary
    mirrors = [url for url in settings.mirrors if url != active]
    fallback_urls = []
    for url in [primary, *mirrors]:
        if url != active and url not in fallback_urls:
            fallback_urls.append(url)
    adapter.primary_url = primary
    adapter.base_url = active
    adapter.fallback_base_urls = fallback_urls
    adapter.configured_mirrors = list(settings.mirrors)
    adapter.display_name = settings.display_name or getattr(adapter, "display_name", adapter.name)
    adapter.enabled = settings.enabled
    adapter.brush_only = settings.brush_only and getattr(adapter, "supports_brush", False)
    adapter.api_key = settings.api_key
    adapter.cookie = settings.cookie
    adapter.passkey = settings.passkey
    adapter.authorization = settings.authorization
    adapter.user_agent = settings.user_agent
    adapter.timeout_seconds = settings.timeout_seconds
    adapter.rss_url = settings.rss_url
    adapter.request_headers = settings.request_headers
    return adapter


def list_sites(raw_settings: dict | None = None, site_ids: Iterable[str] | None = None) -> list[SiteInfo]:
    settings = merge_site_settings(raw_settings)
    ids = list(site_ids) if site_ids is not None else ["dmhy", "mikan", "nyaa", "mteam", "soulvoice", "hddolby", "opencd"]
    return [
        _apply_settings(_default_site_adapter(site_id), settings[site_id]).info()
        for site_id in ids
        if site_id in settings
    ]


def get_site_adapter(site_id: str, raw_settings: dict | None = None) -> BaseSiteAdapter:
    adapter = _default_site_adapter(site_id)
    settings = merge_site_settings(raw_settings)
    return _apply_settings(adapter, settings[site_id])


def site_usage_restriction(
    adapter: BaseSiteAdapter,
    purpose: str,
    *,
    respect_site_enabled: bool = True,
) -> tuple[str, str] | None:
    if respect_site_enabled and not getattr(adapter, "enabled", True):
        return "site_disabled", "站点已在设置中停用"
    if purpose not in {"brush", "site_diagnostics"} and getattr(adapter, "brush_only", False):
        return "site_brush_only", "站点已设为仅站点刷流，本入口不会访问该站点"
    return None


def absolute_url(base_url: str, href: str | None) -> str | None:
    if not href:
        return None
    if href.startswith("magnet:"):
        return href
    return urljoin(base_url, href)


def root_domain(value: str) -> str:
    parsed = urlparse(value if re.match(r"^https?://", value, flags=re.I) else f"https://{value}")
    host = (parsed.netloc or parsed.path).split("@")[-1].split(":")[0].lower()
    parts = [part for part in host.split(".") if part]
    if len(parts) <= 2:
        return host
    return ".".join(parts[-2:])
