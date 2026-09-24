from __future__ import annotations

import re
import json
from collections import OrderedDict
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from html import unescape
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

from app.db import Store
from app.metadata.bangumi import total_episodes_from_subject
from app.models import (
    MikanProjectAnime,
    MikanProjectResourceGroup,
    MikanProjectResourcesResponse,
    MikanProjectSection,
    MikanProjectSectionKind,
    MikanProjectSeasonResponse,
    MikanProjectSettings,
    PosterPalette,
    SearchResult,
)
from app.services.search import result_dedupe_key, search_multi_site
from app.services.subscription_identity import subscription_mikan_bangumi_ids, title_identity_keys
from app.settings import DATA_DIR, bangumi_user_agent
from app.sites.mikan import MikanAdapter

SETTINGS_KEY = "mikan_project_settings"
SEASON_CACHE_KEY = "mikan_project_season_cache"
SEASON_CACHE_VERSION = 2
MIKAN_HOME_URL = "https://mikanani.me/"
MIKAN_PROJECT_POSTER_ROOT = DATA_DIR / "cache" / "posters" / "mikan_project"

SECTION_DEFINITIONS: tuple[tuple[MikanProjectSectionKind, str, str], ...] = (
    ("monday", "周一", "一"),
    ("tuesday", "周二", "二"),
    ("wednesday", "周三", "三"),
    ("thursday", "周四", "四"),
    ("friday", "周五", "五"),
    ("saturday", "周六", "六"),
    ("sunday", "周日", "日"),
    ("movie", "剧场版", "剧场版"),
    ("ova", "OVA", "OVA"),
    ("unknown", "未识别", "?"),
)

MIKAN_DAY_TO_SECTION: dict[int, MikanProjectSectionKind] = {
    0: "sunday",
    1: "monday",
    2: "tuesday",
    3: "wednesday",
    4: "thursday",
    5: "friday",
    6: "saturday",
    7: "movie",
    8: "ova",
}

SEASONS = [
    (1, "winter", "冬季番组"),
    (4, "spring", "春季番组"),
    (7, "summer", "夏季番组"),
    (10, "autumn", "秋季番组"),
]


def stored_mikan_project_settings(store: Store) -> MikanProjectSettings:
    data = store.get_config(SETTINGS_KEY) or {}
    try:
        return MikanProjectSettings(**data)
    except ValueError:
        return MikanProjectSettings()


def save_mikan_project_settings(store: Store, settings: MikanProjectSettings) -> MikanProjectSettings:
    store.set_config(SETTINGS_KEY, settings.model_dump(mode="json"))
    return settings


def current_season(now: datetime | None = None) -> tuple[int, str, str]:
    current = now or datetime.now(timezone.utc)
    selected = SEASONS[0]
    for season in SEASONS:
        if current.month >= season[0]:
            selected = season
    return current.year, selected[1], f"{current.year} {selected[2]}"


def _empty_sections() -> list[MikanProjectSection]:
    return [
        MikanProjectSection(id=kind, name=name, short_name=short_name, items=[])
        for kind, name, short_name in SECTION_DEFINITIONS
    ]


def _normalize_text(value: str | None) -> str:
    return re.sub(r"\s+", "", (value or "").casefold())


def _mikan_day_to_section(value: int) -> MikanProjectSectionKind:
    return MIKAN_DAY_TO_SECTION.get(value, "unknown")


def _absolute_mikan_url(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = unescape(value).strip()
    if not cleaned:
        return None
    if cleaned.startswith("//"):
        return f"https:{cleaned}"
    if cleaned.startswith("http://") or cleaned.startswith("https://"):
        return cleaned
    if cleaned.startswith("/"):
        return f"https://mikanani.me{cleaned}"
    return f"https://mikanani.me/{cleaned}"


def _first_attr(attrs: str, name: str) -> str | None:
    match = re.search(rf"""\b{name}\s*=\s*["']([^"']+)["']""", attrs, flags=re.I | re.S)
    return unescape(match.group(1)).strip() if match else None


def _first_text(pattern: str, text: str) -> str | None:
    match = re.search(pattern, text, flags=re.I | re.S)
    if not match:
        return None
    return re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", " ", match.group(1)))).strip()


def _html_text(value: str | None) -> str | None:
    cleaned = re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", " ", value or ""))).strip()
    return cleaned or None


def _first_href(value: str | None) -> str | None:
    match = re.search(r"""<a\b[^>]*href=["']([^"']+)["']""", value or "", flags=re.I | re.S)
    return _absolute_mikan_url(match.group(1)) if match else None


def _plain_int(value: Any) -> int | None:
    if isinstance(value, int) and value > 0:
        return value
    if isinstance(value, str):
        match = re.search(r"\d+", value)
        if match:
            number = int(match.group(0))
            return number if number > 0 else None
    return None


def _mikan_project_poster_local_url(mikan_bangumi_id: str) -> str:
    return f"/api/mikan-project/posters/{mikan_bangumi_id}"


def _parse_mikan_home_anime(
    block: str,
    section: MikanProjectSectionKind,
    subscribed_ids: set[str],
    subscribed_names: set[str],
) -> MikanProjectAnime | None:
    span_match = re.search(r"""<span\b(?P<attrs>[^>]*)>""", block, flags=re.I | re.S)
    if not span_match:
        return None
    attrs = span_match.group("attrs")
    mikan_id = _first_attr(attrs, "data-bangumiid")
    if not mikan_id:
        return None

    link_match = re.search(r"""<a\b(?P<attrs>[^>]*class=["'][^"']*\ban-text\b[^"']*["'][^>]*)>(?P<text>.*?)</a>""", block, flags=re.I | re.S)
    link_attrs = link_match.group("attrs") if link_match else ""
    title = _first_attr(link_attrs, "title") if link_match else None
    if not title and link_match:
        title = re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", " ", link_match.group("text")))).strip()
    if not title:
        title_match = re.search(r"""<div\b[^>]*class=["']date-text["'][^>]*\btitle=["']([^"']+)["'][^>]*>""", block, flags=re.I | re.S)
        title = unescape(title_match.group(1)).strip() if title_match else None
    if not title:
        return None

    status_text = _first_text(r"""<div\b[^>]*class=["']date-text["'][^>]*>(.*?)</div>""", block)
    poster_original_url = _absolute_mikan_url(_first_attr(attrs, "data-src"))
    detail_url = _absolute_mikan_url(_first_attr(link_attrs, "href")) if link_match else None
    class_text = _first_attr(attrs, "class") or ""
    is_grayscale = "greyout" in class_text.split() or status_text == "此番组下暂无作品"
    resource_text = _first_text(r"""<div\b[^>]*class=["'][^"']*\bnum-node\b[^"']*["'][^>]*>(.*?)</div>""", block)
    resource_count = int(resource_text) if resource_text and resource_text.isdigit() else None
    normalized_names = title_identity_keys([title])
    subscribed = mikan_id in subscribed_ids or any(name and name in subscribed_names for name in normalized_names)
    return MikanProjectAnime(
        bangumi_id=mikan_id,
        title=title,
        original_title=None,
        poster_url=_mikan_project_poster_local_url(mikan_id) if poster_original_url else None,
        poster_original_url=poster_original_url,
        poster_local_url=_mikan_project_poster_local_url(mikan_id) if poster_original_url else None,
        detail_url=detail_url,
        update_date=status_text,
        air_date=None,
        section=section,
        subscribed=subscribed,
        is_grayscale=is_grayscale,
        status_text=status_text,
        resource_count=resource_count,
    )


def parse_mikan_home(html_text: str, subscribed_ids: set[str] | None = None, subscribed_names: set[str] | None = None, *, now: datetime | None = None) -> MikanProjectSeasonResponse:
    decoded = unescape(html_text)
    subscribed_ids = subscribed_ids or set()
    subscribed_names = subscribed_names or set()
    current = now or datetime.now(timezone.utc)
    year, season, fallback_title = current_season(current)
    title = _first_text(r"""<div\b[^>]*class=["'][^"']*\bdate-text\b[^"']*["'][^>]*>\s*(.*?番组)\s*<span\b""", decoded) or fallback_title
    title_year = re.search(r"(\d{4})", title)
    if title_year:
        year = int(title_year.group(1))
    for cn, key in [("冬", "winter"), ("春", "spring"), ("夏", "summer"), ("秋", "autumn")]:
        if cn in title:
            season = key
            break

    sections = {item.id: item for item in _empty_sections()}
    seen_bangumi_ids: set[str] = set()
    warnings: list[str] = []
    section_matches = list(re.finditer(r"""<div\b[^>]*class=["']sk-bangumi["'][^>]*data-dayofweek=["'](?P<day>\d+)["'][^>]*>""", decoded, flags=re.I | re.S))
    for index, match in enumerate(section_matches):
        start = match.end()
        end = section_matches[index + 1].start() if index + 1 < len(section_matches) else len(decoded)
        mikan_day = int(match.group("day"))
        section_kind = _mikan_day_to_section(mikan_day)
        if section_kind == "unknown":
            warnings.append(f"Mikan 返回未识别的番组栏目：data-dayofweek={mikan_day}")
        section = decoded[start:end]
        for item_match in re.finditer(r"""<li\b[^>]*>(?P<block>.*?)</li>""", section, flags=re.I | re.S):
            anime = _parse_mikan_home_anime(item_match.group("block"), section_kind, subscribed_ids, subscribed_names)
            if not anime:
                continue
            if anime.bangumi_id in seen_bangumi_ids:
                warnings.append(f"Mikan 番组 {anime.bangumi_id} 出现在多个栏目，已按首次出现位置去重")
                continue
            seen_bangumi_ids.add(anime.bangumi_id)
            sections[section_kind].items.append(anime)

    return MikanProjectSeasonResponse(
        cache_version=SEASON_CACHE_VERSION,
        season_title=title,
        year=year,
        season=season,
        cached_at=datetime.now(timezone.utc),
        last_refresh_started_at=current,
        settings=MikanProjectSettings(),
        sections=list(sections.values()),
        warnings=warnings,
    )


def _subscription_markers(store: Store) -> tuple[set[str], set[str]]:
    ids: set[str] = set()
    names: set[str] = set()
    for subscription in store.list_subscriptions():
        mikan_ids = subscription_mikan_bangumi_ids(subscription)
        if len(mikan_ids) == 1:
            ids.update(mikan_ids)
            continue
        if len(mikan_ids) > 1 or "mikan" not in set(subscription.get("sites") or []):
            continue
        names.update(
            title_identity_keys(
                [
                    str(subscription.get("name") or ""),
                    str(subscription.get("keyword") or ""),
                    *(str(item) for item in subscription.get("aliases") or []),
                ]
            )
        )
        for row in store.list_metadata_bindings_for_target("subscription", str(subscription.get("id")), limit=20):
            names.update(title_identity_keys([row.get("selected_title"), row.get("original_title")]))
    return ids, names


async def fetch_mikan_home() -> str:
    headers = {
        "User-Agent": "Mozilla/5.0 Kisetsu/0.1",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": MIKAN_HOME_URL,
    }
    async with httpx.AsyncClient(headers=headers, timeout=15, follow_redirects=True) as client:
        response = await client.get(MIKAN_HOME_URL)
        response.raise_for_status()
    return response.text


async def fetch_mikan_detail(detail_url: str) -> str:
    headers = {
        "User-Agent": "Mozilla/5.0 Kisetsu/0.1",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": MIKAN_HOME_URL,
    }
    async with httpx.AsyncClient(headers=headers, timeout=15, follow_redirects=True) as client:
        response = await client.get(detail_url)
        response.raise_for_status()
    return response.text


def _bangumi_subject_id_from_url(value: str | None) -> str | None:
    match = re.search(r"""(?:bgm\.tv|bangumi\.tv)/subject/(\d+)""", value or "", flags=re.I)
    return match.group(1) if match else None


def _infobox_value(item: dict[str, Any], keys: set[str]) -> Any:
    for entry in item.get("infobox") or []:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("key") or "") in keys:
            return entry.get("value")
    return None


def _infobox_text(item: dict[str, Any], keys: set[str]) -> str | None:
    value = _infobox_value(item, keys)
    if isinstance(value, list):
        texts = []
        for entry in value:
            if isinstance(entry, dict) and entry.get("v"):
                texts.append(str(entry["v"]))
            elif entry:
                texts.append(str(entry))
        return "、".join(texts) or None
    return str(value).strip() if value else None


async def fetch_bangumi_subject(subject_id: str, *, timeout_seconds: float = 15) -> dict[str, Any]:
    headers = {
        "User-Agent": bangumi_user_agent(),
        "Accept": "application/json",
    }
    async with httpx.AsyncClient(timeout=timeout_seconds, headers=headers) as client:
        response = await client.get(f"https://api.bgm.tv/v0/subjects/{subject_id}")
        response.raise_for_status()
    data = response.json()
    return data if isinstance(data, dict) else {}


async def fetch_bangumi_episodes(subject_id: str, *, timeout_seconds: float = 15) -> list[dict[str, Any]]:
    headers = {
        "User-Agent": bangumi_user_agent(),
        "Accept": "application/json",
    }
    limit = 100
    offset = 0
    episodes: list[dict[str, Any]] = []
    async with httpx.AsyncClient(timeout=timeout_seconds, headers=headers) as client:
        for _ in range(50):
            response = await client.get(
                "https://api.bgm.tv/v0/episodes",
                params={"subject_id": subject_id, "limit": limit, "offset": offset},
            )
            response.raise_for_status()
            payload = response.json()
            page = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(page, list):
                raise ValueError("Bangumi 章节列表结构无效")
            episodes.extend(item for item in page if isinstance(item, dict))
            total = payload.get("total") if isinstance(payload, dict) else None
            if isinstance(total, int) and not isinstance(total, bool) and total >= 0:
                if len(episodes) >= total:
                    return episodes
                if not page:
                    raise ValueError("Bangumi 章节列表分页不完整")
            elif len(page) < limit:
                return episodes
            offset += len(page)
    raise ValueError("Bangumi 章节列表超过安全分页上限")


async def fetch_bangumi_subject_with_episodes(subject_id: str, *, timeout_seconds: float = 15) -> dict[str, Any]:
    """Fetch a subject and use structured chapters only when 话数 is absent."""
    subject = await fetch_bangumi_subject(subject_id, timeout_seconds=timeout_seconds)
    if total_episodes_from_subject(subject) is not None:
        return subject
    with suppress(Exception):
        return {
            **subject,
            "episodes": await fetch_bangumi_episodes(subject_id, timeout_seconds=timeout_seconds),
        }
    return subject


def parse_mikan_detail(html_text: str) -> dict[str, Any]:
    decoded = unescape(html_text)
    updates: dict[str, Any] = {}

    title = _first_text(r"""<p\b[^>]*class=["'][^"']*\bbangumi-title\b[^"']*["'][^>]*>(.*?)</p>""", decoded)
    if title:
        updates["title"] = re.sub(r"\s+", " ", re.sub(r"\bRSS\b", "", title)).strip()

    poster_match = re.search(r"""class=["'][^"']*\bbangumi-poster\b[^"']*["'][^>]*style=["'][^"']*background-image:\s*url\((["']?)(?P<url>.*?)\1\)""", decoded, flags=re.I | re.S)
    if poster_match:
        poster_url = _absolute_mikan_url(poster_match.group("url"))
        if poster_url:
            updates["poster_original_url"] = poster_url

    for match in re.finditer(r"""<p\b[^>]*class=["'][^"']*\bbangumi-info\b[^"']*["'][^>]*>(?P<body>.*?)</p>""", decoded, flags=re.I | re.S):
        body = match.group("body")
        label_match = re.match(r"""\s*([^：:]+)[：:]\s*(?P<value>.*)""", body, flags=re.S)
        if not label_match:
            continue
        label = _html_text(label_match.group(1)) or ""
        value_html = label_match.group("value")
        value_text = _html_text(value_html)
        if label == "放送日期":
            updates["broadcast_day"] = value_text
        elif label == "放送开始":
            updates["broadcast_start"] = value_text
        elif label == "官方网站":
            updates["official_url"] = _first_href(value_html) or value_text
        elif label == "Bangumi番组计划链接":
            bangumi_url = _first_href(value_html) or value_text
            if bangumi_url:
                updates["bangumi_url"] = bangumi_url
                subject_id = _bangumi_subject_id_from_url(bangumi_url)
                if subject_id:
                    updates["bangumi_subject_id"] = subject_id

    return {key: value for key, value in updates.items() if value not in {None, ""}}


def merge_bangumi_subject_details(updates: dict[str, Any], item: dict[str, Any]) -> dict[str, Any]:
    if not item:
        return updates
    merged = dict(updates)
    summary = item.get("summary")
    if summary and not merged.get("synopsis"):
        merged["synopsis"] = str(summary).strip()
    if item.get("name") and not merged.get("original_title"):
        merged["original_title"] = str(item["name"])
    if item.get("date") and not merged.get("air_date"):
        merged["air_date"] = str(item["date"])
    total_episodes = total_episodes_from_subject(item)
    if total_episodes and not merged.get("total_episodes"):
        merged["total_episodes"] = total_episodes
    if not merged.get("broadcast_start"):
        broadcast_start = _infobox_text(item, {"放送开始", "上映年度"})
        if broadcast_start:
            merged["broadcast_start"] = broadcast_start
    if not merged.get("official_url"):
        official_url = _infobox_text(item, {"官方网站"})
        if official_url:
            merged["official_url"] = official_url
    if not merged.get("bangumi_url") and item.get("id"):
        merged["bangumi_url"] = f"https://bgm.tv/subject/{item['id']}"
        merged["bangumi_subject_id"] = str(item["id"])
    return {key: value for key, value in merged.items() if value not in {None, ""}}


async def fetch_mikan_project_anime_detail(
    store: Store,
    bangumi_id: str,
    *,
    detail_html: str | None = None,
) -> MikanProjectAnime | None:
    anime = find_cached_anime(store, bangumi_id)
    if not anime:
        return None
    detail_url = anime.detail_url or f"https://mikanani.me/Home/Bangumi/{bangumi_id}"
    updates = parse_mikan_detail(detail_html if detail_html is not None else await fetch_mikan_detail(detail_url))
    subject_id = updates.get("bangumi_subject_id") or anime.bangumi_subject_id
    if subject_id:
        subject = await fetch_bangumi_subject_with_episodes(str(subject_id))
        updates = merge_bangumi_subject_details(updates, subject)
    if updates.get("poster_original_url") and not updates.get("poster_url"):
        updates["poster_url"] = anime.poster_url
        updates["poster_local_url"] = anime.poster_local_url
    return anime.model_copy(update=updates)


async def refresh_mikan_project_season(store: Store) -> MikanProjectSeasonResponse:
    settings = stored_mikan_project_settings(store)
    started_at = datetime.now(timezone.utc)
    year, season, title = current_season(started_at)
    subscribed_ids, subscribed_names = _subscription_markers(store)
    sections = {item.id: item for item in _empty_sections()}
    warnings: list[str] = []

    response = parse_mikan_home(await fetch_mikan_home(), subscribed_ids, subscribed_names, now=started_at)
    sections = {item.id: item for item in response.sections}
    warnings.extend(response.warnings)

    response = response.model_copy(update={
        "cache_version": SEASON_CACHE_VERSION,
        "season_title": response.season_title or title,
        "year": response.year or year,
        "season": response.season or season,
        "cached_at": datetime.now(timezone.utc),
        "last_refresh_started_at": started_at,
        "settings": settings,
        "sections": list(sections.values()),
        "warnings": warnings,
    })
    store.set_config(SEASON_CACHE_KEY, response.model_dump(mode="json"))
    return response


def load_cached_mikan_project_season(store: Store) -> MikanProjectSeasonResponse | None:
    data = store.get_config(SEASON_CACHE_KEY)
    if not data:
        return None
    if data.get("cache_version") != SEASON_CACHE_VERSION:
        return None
    try:
        response = MikanProjectSeasonResponse(**data)
    except ValueError:
        return None
    settings = stored_mikan_project_settings(store)
    subscribed_ids, subscribed_names = _subscription_markers(store)
    sections: list[MikanProjectSection] = []
    for section in response.sections:
        items = []
        for anime in section.items:
            names = title_identity_keys([anime.title, anime.original_title])
            items.append(anime.model_copy(update={"subscribed": anime.bangumi_id in subscribed_ids or any(name and name in subscribed_names for name in names)}))
        sections.append(section.model_copy(update={"items": items}))
    return response.model_copy(update={"settings": settings, "sections": sections})


def mikan_project_cache_is_stale(response: MikanProjectSeasonResponse, settings: MikanProjectSettings) -> bool:
    if not response.cached_at or not settings.auto_refresh_enabled:
        return False
    age = datetime.now(timezone.utc) - response.cached_at
    return age >= timedelta(hours=settings.refresh_interval_hours)


def find_cached_anime(store: Store, bangumi_id: str) -> MikanProjectAnime | None:
    cached = load_cached_mikan_project_season(store)
    if not cached:
        return None
    for section in cached.sections:
        for anime in section.items:
            if anime.bangumi_id == bangumi_id:
                return anime
    return None


def _candidate_keywords(anime: MikanProjectAnime | None, bangumi_id: str) -> list[str]:
    if not anime:
        return [bangumi_id]
    values = [anime.bangumi_id, anime.title, anime.original_title]
    keywords: list[str] = []
    seen: set[str] = set()
    for value in values:
        cleaned = (value or "").strip()
        key = _normalize_text(cleaned)
        if cleaned and key not in seen:
            seen.add(key)
            keywords.append(cleaned)
    return keywords or [bangumi_id]


def mikan_project_poster_path(mikan_bangumi_id: str) -> Path | None:
    cache_dir = MIKAN_PROJECT_POSTER_ROOT / re.sub(r"[^A-Za-z0-9_-]", "_", mikan_bangumi_id)
    if not cache_dir.exists():
        return None
    candidates = sorted(
        [item for item in cache_dir.iterdir() if item.is_file() and item.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}],
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def _mikan_project_poster_cache_dir(mikan_bangumi_id: str) -> Path:
    return MIKAN_PROJECT_POSTER_ROOT / re.sub(r"[^A-Za-z0-9_-]", "_", mikan_bangumi_id)


def _mikan_project_poster_palette_path(mikan_bangumi_id: str) -> Path:
    return _mikan_project_poster_cache_dir(mikan_bangumi_id) / "palette.json"


def mikan_project_poster_palette_for_path(mikan_bangumi_id: str, path: Path | None) -> PosterPalette | None:
    if path is None or not path.exists():
        return None
    palette_path = _mikan_project_poster_palette_path(mikan_bangumi_id)
    if palette_path.exists() and palette_path.stat().st_mtime >= path.stat().st_mtime:
        with suppress(Exception):
            return PosterPalette(**json.loads(palette_path.read_text(encoding="utf-8")))
    try:
        from app.api.routes import _extract_poster_palette

        palette = _extract_poster_palette(path)
    except Exception:
        return None
    if palette is not None:
        with suppress(OSError):
            palette_path.parent.mkdir(parents=True, exist_ok=True)
            palette_path.write_text(palette.model_dump_json(), encoding="utf-8")
    return palette


def _poster_extension(content_type: str, poster_url: str) -> str:
    normalized = content_type.split(";", 1)[0].strip().lower()
    if normalized in {"image/jpeg", "image/jpg"}:
        return ".jpg"
    if normalized == "image/png":
        return ".png"
    if normalized == "image/webp":
        return ".webp"
    suffix = Path(urlparse(poster_url).path).suffix.lower()
    return suffix if suffix in {".jpg", ".jpeg", ".png", ".webp"} else ".jpg"


async def cache_mikan_project_poster(store: Store, mikan_bangumi_id: str) -> Path | None:
    cached = mikan_project_poster_path(mikan_bangumi_id)
    if cached:
        return cached
    anime = find_cached_anime(store, mikan_bangumi_id)
    if not anime or not anime.poster_original_url:
        return None
    headers = {
        "User-Agent": "Mozilla/5.0 Kisetsu/0.1",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": MIKAN_HOME_URL,
    }
    async with httpx.AsyncClient(headers=headers, timeout=15, follow_redirects=True) as client:
        response = await client.get(anime.poster_original_url)
        response.raise_for_status()
    content_type = response.headers.get("content-type", "")
    if not content_type.lower().startswith("image/") or not response.content:
        return None
    cache_dir = _mikan_project_poster_cache_dir(mikan_bangumi_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"poster{_poster_extension(content_type, anime.poster_original_url)}"
    path.write_bytes(response.content)
    return path


async def _with_mikan_project_poster_palette(store: Store, anime: MikanProjectAnime | None) -> MikanProjectAnime | None:
    if anime is None or anime.poster_palette is not None:
        return anime
    path = mikan_project_poster_path(anime.bangumi_id)
    if path is None:
        with suppress(Exception):
            path = await cache_mikan_project_poster(store, anime.bangumi_id)
    palette = mikan_project_poster_palette_for_path(anime.bangumi_id, path)
    if palette is None:
        return anime
    return anime.model_copy(update={"poster_palette": palette})


async def fetch_mikan_project_resources(store: Store, bangumi_id: str) -> MikanProjectResourcesResponse:
    warnings: list[str] = []
    anime = find_cached_anime(store, bangumi_id)
    detail_url = anime.detail_url if anime and anime.detail_url else f"https://mikanani.me/Home/Bangumi/{bangumi_id}"
    detail_html: str | None = None
    try:
        detail_html = await fetch_mikan_detail(detail_url)
        enriched_anime = await fetch_mikan_project_anime_detail(store, bangumi_id, detail_html=detail_html)
        if enriched_anime:
            anime = enriched_anime
    except Exception as exc:
        warnings.append(f"Mikan Project 详情加载失败，已仅显示资源：{exc}")
    anime = await _with_mikan_project_poster_palette(store, anime)

    if detail_html:
        exact_groups = MikanAdapter().parse_bangumi_groups(detail_html, bangumi_id)
        if exact_groups:
            response_groups: list[MikanProjectResourceGroup] = []
            for group in exact_groups:
                items: list[SearchResult] = []
                for result in group.resources:
                    from app.api.routes import enrich_search_result

                    enriched = enrich_search_result(result).model_copy(update={"parsed_fansub": group.name})
                    items.append(enriched)
                response_groups.append(
                    MikanProjectResourceGroup(
                        fansub_id=group.id,
                        fansub=group.name,
                        resources=items,
                    )
                )
            return MikanProjectResourcesResponse(anime=anime, groups=response_groups, warnings=warnings)
        warnings.append("Mikan Project 详情未提供可识别的字幕组资源关系，已回退到标题解析。")

    results: list[SearchResult] = []
    seen: set[str] = set()
    for keyword in _candidate_keywords(anime, bangumi_id):
        found, site_warnings, _diagnostics = await search_multi_site(
            keyword,
            ["mikan"],
            max_pages=2,
            page_size=50,
            site_settings=store.get_runtime_config("site_settings") or {},
            deduplicate=True,
            timeout_seconds=15,
        )
        warnings.extend(site_warnings)
        for result in found:
            key = result_dedupe_key(result)
            if key in seen:
                continue
            seen.add(key)
            results.append(result)

    groups: OrderedDict[str, list[SearchResult]] = OrderedDict()
    for result in results:
        from app.api.routes import enrich_search_result

        enriched = enrich_search_result(result)
        fansub = (enriched.parsed_fansub or "").strip() or "未知字幕组"
        groups.setdefault(fansub, []).append(enriched)
    return MikanProjectResourcesResponse(
        anime=anime,
        groups=[MikanProjectResourceGroup(fansub=fansub, resources=items) for fansub, items in groups.items()],
        warnings=warnings,
    )
