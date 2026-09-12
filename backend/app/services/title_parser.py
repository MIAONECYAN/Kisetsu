from __future__ import annotations

import re

from app.models import EpisodeParseRule, ParsedAnimeTitle


RESOLUTION_RE = re.compile(r"\b(2160p|1080p|720p|480p|4K|3840x2160|1920x1080|1280x720|854x480)\b", re.I)
LANGUAGE_RE = re.compile(r"\b(CHS&CHT|CHS|CHT|BIG5|GB|简日|繁日|简繁|简体|繁体)\b", re.I)
VERSION_RE = re.compile(r"\b(v\d+)\b", re.I)
SIZE_RE = re.compile(r"(?<!\d)(\d+(?:\.\d+)?\s*(?:KiB|MiB|GiB|KB|MB|GB))(?![A-Za-z])", re.I)

RESOLUTION_PRESET_ALIASES = {
    "720p": "720p",
    "1280x720": "720p",
    "1080p": "1080p",
    "1920x1080": "1080p",
    "2160p": "2160p",
    "3840x2160": "2160p",
    "4096x2160": "2160p",
    "4k": "2160p",
}


def normalize_resolution_preset(value: str | None) -> str | None:
    if not value:
        return None
    normalized = value.strip().casefold().replace("×", "x").replace(" ", "")
    return RESOLUTION_PRESET_ALIASES.get(normalized)


SEASON_EPISODE_RE = re.compile(r"\bS(?P<season>\d{1,2})[:._-]?E(?P<episode>\d{1,4})(?:-?E?(?P<episode_end>\d{1,4}))?\b", re.I)
SEASON_EPISODE_REPEAT_RANGE_RE = re.compile(
    r"\bS(?P<season>\d{1,2})[:._-]?E(?P<episode>\d{1,4})"
    r"\s*[-~～]\s*S(?P=season)[:._-]?E(?P<episode_end>\d{1,4})\b",
    re.I,
)
SEASON_DASH_EPISODE_RE = re.compile(r"\bS(?P<season>\d{1,2})\s*[-_]\s*(?P<episode>\d{1,4})(?:\s*[-~]\s*(?P<episode_end>\d{1,4}))?\b", re.I)
SEASON_WORD_DASH_EPISODE_RE = re.compile(
    r"(?:\bSeason\s*(?P<season>\d{1,2})|(?P<ord>\d{1,2})(?:st|nd|rd|th)\s+Season|第\s*(?P<cn>[一二三四五六七八九十\d]{1,3})\s*季)"
    r"\s*[-_]\s*(?P<episode>\d{1,4})(?:\s*[-~]\s*(?P<episode_end>\d{1,4}))?",
    re.I,
)
EP_PREFIX_RE = re.compile(r"(?:^|[\s\-_])(?:EP|E)\s*(?P<episode>\d{1,4})(?:\b|[^\d])", re.I)
DASH_RELEASE_EPISODE_RE = re.compile(
    r"\s[-–—]\s*(?P<episode>\d{1,3})(?:v\d+)?\s*(?=(?:\[[^\]]+\]|\([^\)]*\)|【[^】]+】|$))",
    re.I,
)
EPISODE_RE = re.compile(
    r"(?:^|[\s\-_第])(?P<episode>\d{1,3})"
    r"(?!\s*(?:[-_]\s*)?(?:nen|years?|bits?)\b)"
    r"(?!\s*[年月日时時分秒])"
    r"(?:\s*[-~]\s*(?P<episode_end>\d{1,3}))?"
    r"(?:[话話集集]|(?=$|[\s\-_)\]】])|(?=\.(?:mkv|mp4|avi|mov|ass|srt)\b))",
    re.I,
)
STAR_RANGE_RE = re.compile(r"★\s*(?P<start>\d{1,3})\s*[~～-]\s*(?P<end>\d{1,3})\s*(?P<final>\(完\)|（完）)?\s*★")
STAR_SINGLE_RE = re.compile(r"★\s*(?P<episode>\d{1,3})(?:v\d+)?\s*(?P<final>\(完\)|（完）)?\s*★")
EPISODE_VALUE_RE = r"\d{1,3}(?:\.\d+)?"
TOKEN_RANGE_RE = re.compile(r"(?:^|[^\d.])(?P<start>\d{1,3})\s*[~～至-]\s*(?P<end>\d{1,3})\s*(?P<final>\(完\)|（完）)?(?=$|[^\d.])")
TOKEN_SINGLE_FINAL_RE = re.compile(r"(?:^|[^\d])(?P<episode>\d{1,3})(?:v\d+)?\s*(?P<final>\(完\)|（完）)(?=$|[^\d])")
EPISODE_WORD_RE = re.compile(r"第\s*(?P<episode>\d{1,3})(?:\s*[~～至-]\s*(?P<episode_end>\d{1,3}))?\s*[话話集]")
FULL_EPISODE_COUNT_RE = re.compile(
    r"(?:全\s*(?P<prefix_count>\d{1,3})\s*[话話集]|"
    r"(?P<suffix_count>\d{1,3})\s*[话話集]\s*(?:全|全集|完结|完結))",
    re.I,
)
FINAL_RE = re.compile(r"(\(完\)|（完）|\b(?:END|Fin|Complete)\b|全集|合集)", re.I)
BATCH_KEYWORD_RE = re.compile(r"(全集|合集|Complete|Batch|全)", re.I)
EXPLICIT_BATCH_RE = re.compile(r"(\b(?:Complete|Batch)\b|全集)", re.I)
SPECIAL_KEYWORD_RE = re.compile(r"(SP|OVA|OAD|特典|特典映像|映像特典|番外|特别篇|特別篇|劇場版|剧场版|电影|電影)", re.I)
TOKEN_BATCH_RANGE_RE = re.compile(
    r"(?P<start>\d{1,3})\s*[-~～至]\s*(?P<end>\d{1,3})\s*(?:TV)?\s*(?:全集|合集|全|Complete|Batch)",
    re.I,
)
TOKEN_ANY_RANGE_RE = re.compile(r"(?P<start>\d{1,3})\s*[-~～至]\s*(?P<end>\d{1,3})", re.I)
TOKEN_FINAL_RANGE_RE = re.compile(
    r"(?P<start>\d{1,3})\s*[-~～至]\s*(?P<end>\d{1,3})\s*(?:Fin|END|完|完结|完結)",
    re.I,
)
TOKEN_DECIMAL_BATCH_RANGE_RE = re.compile(
    rf"(?P<start>{EPISODE_VALUE_RE})\s*[-~～至]\s*(?P<end>{EPISODE_VALUE_RE})"
    r"(?:\s*\(\s*(?P<season_start>\d{1,3})\s*[-~～至]\s*(?P<season_end>\d{1,3})\s*\))?"
    r"\s*(?:TV)?\s*(?P<batch>全集|合集|全|Complete|Batch)?",
    re.I,
)
PART_DASH_EPISODE_RE = re.compile(
    r"(?:Part|第)\s*(?P<part>\d{1,2})\s*(?:部分|部)?(?:\s*/[^-]+)?\s*-\s*(?P<episode>\d{1,3})(?=\s*(?:[\[【(]|$))",
    re.I,
)
SEASON_MARK_RE = re.compile(
    r"(?:S(?P<snum>\d{1,2})(?!\d)|\bSeason\s*(?P<word>\d{1,2})\b|(?P<ord>\d{1,2})(?:st|nd|rd|th)\s+Season|第\s*(?P<cn>[一二三四五六七八九十\d]{1,3})\s*季)",
    re.I,
)
PART_MARK_RE = re.compile(r"(?:Part|第)\s*(?P<part>\d{1,2})\s*(?:部分|部)", re.I)


CN_NUMBERS = {
    "一": 1,
    "二": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
    "十": 10,
}


GENERIC_RELEASE_TAGS = {
    "国漫",
    "国产",
    "国产动画",
    "动画",
    "动漫",
    "動畫",
    "劇場版",
    "剧场版",
    "电影",
    "電影",
    "movie",
    "tv",
    "web",
    "webrip",
    "web-dl",
    "baha",
    "avc",
    "hevc",
    "h264",
    "h.264",
    "h265",
    "h.265",
    "aac",
    "mp4",
    "mkv",
    "gb",
    "big5",
}

KNOWN_FANSUB_TOKENS = {
    "ani",
    "asw",
    "gm-team",
    "lilith-raws",
    "loliHouse".lower(),
    "nekomoe",
    "nekomoe kissaten",
    "dbd-raws",
    "喵萌",
    "喵萌奶茶屋",
    "桜都",
    "樱都",
    "北宇治",
    "千夏",
    "云光",
    "绿茶",
    "六四位元",
    "芝士动物朋友",
}


def _normalize_release_token(value: str | None) -> str:
    if not value:
        return ""
    return re.sub(r"\s+", " ", value.strip()).lower()


def _is_generic_release_tag(value: str | None) -> bool:
    normalized = _normalize_release_token(value)
    if not normalized:
        return False
    if normalized in GENERIC_RELEASE_TAGS:
        return True
    if re.fullmatch(r"\d{4}", normalized):
        return True
    return bool(
        RESOLUTION_RE.fullmatch(normalized)
        or LANGUAGE_RE.fullmatch(normalized)
        or SIZE_RE.fullmatch(normalized)
        or re.fullmatch(r"(?:x26[45]|10bit|8bit|hdr|sdr|aac\d?(?:\.\d)?|ddp\d?(?:\.\d)?|flac)", normalized, flags=re.I)
    )


def _looks_like_fansub_token(value: str | None) -> bool:
    normalized = _normalize_release_token(value)
    if not normalized or _is_generic_release_tag(normalized):
        return False
    if any(name in normalized for name in KNOWN_FANSUB_TOKENS):
        return True
    return bool(re.search(r"(字幕|字幕组|字幕組|压制|壓製|fansub|sub(?:s)?\b|raws?\b|team\b|group\b)", value or "", flags=re.I))


def _looks_like_title_token(value: str | None) -> bool:
    if not value:
        return False
    cleaned = value.strip()
    if not cleaned or _is_generic_release_tag(cleaned) or _looks_like_release_season_label(cleaned):
        return False
    if re.fullmatch(r"\d{1,4}(?:v\d+)?", cleaned, flags=re.I):
        return False
    if EPISODE_WORD_RE.fullmatch(cleaned):
        return False
    if RESOLUTION_RE.search(cleaned) or LANGUAGE_RE.search(cleaned) or VERSION_RE.search(cleaned) or SIZE_RE.search(cleaned):
        return False
    return True


def _cn_int(value: str | None) -> int | None:
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return int(value)
    if value in CN_NUMBERS:
        return CN_NUMBERS[value]
    if value.startswith("十") and len(value) == 2:
        return 10 + CN_NUMBERS.get(value[1], 0)
    if value.endswith("十") and len(value) == 2:
        return CN_NUMBERS.get(value[0], 0) * 10
    if "十" in value and len(value) == 3:
        return CN_NUMBERS.get(value[0], 0) * 10 + CN_NUMBERS.get(value[2], 0)
    return None


def _looks_like_release_season_label(value: str | None) -> bool:
    if not value:
        return False
    return bool(re.fullmatch(r"\d+\s*月\s*新番|[春夏秋冬]\s*季\s*新番|新番", value.strip(), flags=re.I))


def _format_episode_value(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    if "." in cleaned:
        left, right = cleaned.split(".", 1)
        right = right.rstrip("0")
        return f"{int(left)}.{right}" if right else str(int(left))
    return str(int(cleaned))


def _python_regex(pattern: str) -> str:
    return re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)


def _group(match: re.Match[str], name: str | None) -> str | None:
    if not name:
        return None
    try:
        if name.isdigit():
            value = match.group(int(name))
        else:
            value = match.group(name)
    except (IndexError, KeyError):
        return None
    return value.strip() if value else None


def _int_group(match: re.Match[str], name: str | None) -> int | None:
    value = _group(match, name)
    if value is None or not re.fullmatch(r"\d{1,3}", value):
        return None
    return int(value)


def _resolve_season(
    *,
    explicit_season: int | None,
    inferred_season: int | None,
    context_season: int | None,
) -> tuple[int | None, str, bool, str | None]:
    if context_season is not None:
        if explicit_season is not None and explicit_season != context_season:
            return (
                context_season,
                "subscription",
                True,
                f"资源解析为 Season {explicit_season:02d}，但订阅是 Season {context_season:02d}",
            )
        return context_season, "subscription", False, None
    if explicit_season is not None:
        return explicit_season, "title_explicit", False, None
    if inferred_season is not None:
        return inferred_season, "default", False, None
    return None, "unknown", False, None


def _parse_with_custom_rules(
    raw_title: str,
    rules: list[EpisodeParseRule],
    *,
    context_season_number: int | None = None,
) -> ParsedAnimeTitle | None:
    for rule in sorted((item for item in rules if item.enabled), key=lambda item: item.priority):
        try:
            match = re.search(_python_regex(rule.pattern), raw_title, flags=re.I)
        except re.error as exc:
            return ParsedAnimeTitle(
                original_title=raw_title,
                parse_rule_name=rule.name,
                parse_failure_reason=f"自定义集数规则“{rule.name}”正则错误：{exc}",
                confidence=0.15,
                parse_confidence=0.15,
                needs_confirmation=True,
            )
        if not match:
            continue
        episode = _int_group(match, rule.episode_group)
        start = _int_group(match, rule.start_group)
        end = _int_group(match, rule.end_group)
        if episode is None and start is not None:
            episode = start
        is_batch = bool(start is not None and end is not None and end > start)
        is_final = bool(_group(match, rule.final_group)) or bool(FINAL_RE.search(raw_title))
        if episode is None:
            return ParsedAnimeTitle(
                original_title=raw_title,
                parse_rule_name=rule.name,
                parse_failure_reason=f"自定义集数规则“{rule.name}”已命中，但没有捕获到集数。",
                confidence=0.25,
                parse_confidence=0.25,
                needs_confirmation=True,
            )
        fallback = parse_title(raw_title, context_season_number=context_season_number)
        confidence = 0.92 if is_batch or episode is not None else 0.55
        return ParsedAnimeTitle(
            original_title=raw_title,
            title=fallback.title,
            episode=episode,
            episode_number=episode,
            episode_start=episode,
            episode_end=end,
            is_batch=is_batch,
            is_final=is_final,
            parse_rule_name=rule.name,
            parse_confidence=confidence,
            parse_failure_reason=None,
            season=fallback.season,
            season_number=fallback.season_number,
            explicit_season_number=fallback.explicit_season_number,
            inferred_season_number=fallback.inferred_season_number,
            context_season_number=fallback.context_season_number,
            effective_season_number=fallback.effective_season_number,
            season_source=fallback.season_source,
            season_conflict=fallback.season_conflict,
            season_conflict_reason=fallback.season_conflict_reason,
            fansub=fallback.fansub,
            resolution=fallback.resolution,
            subtitle_language=fallback.subtitle_language,
            version=fallback.version,
            confidence=confidence,
            needs_confirmation=confidence < 0.75,
        )
    return None


def parse_title(
    raw_title: str,
    episode_parse_rules: list[EpisodeParseRule] | None = None,
    *,
    context_season_number: int | None = None,
) -> ParsedAnimeTitle:
    custom = _parse_with_custom_rules(
        raw_title,
        episode_parse_rules or [],
        context_season_number=context_season_number,
    )
    if custom is not None:
        return custom
    title = raw_title.strip()
    working = title
    fansub = None
    bracket_title = None
    explicit_season = None
    inferred_season = None
    part_number = None
    season_marker = SEASON_MARK_RE.search(working)
    if season_marker:
        explicit_season = int(
            season_marker.group("snum")
            or season_marker.group("word")
            or season_marker.group("ord")
            or _cn_int(season_marker.group("cn"))
            or 0
        ) or None
    part_marker = PART_MARK_RE.search(working)
    if part_marker:
        part_number = int(part_marker.group("part"))
    leading_group = re.match(r"^(?:\[(?P<square>[^\]]+)\]|【(?P<wide>[^】]+)】)", working)
    if leading_group:
        leading_value = (leading_group.group("square") or leading_group.group("wide") or "").strip()
        following_group = re.match(r"^(?:\[\s*(?P<square>[^\]]+?)\s*\]|【\s*(?P<wide>[^】]+?)\s*】)", working[leading_group.end() :].strip())
        following_token_text = (following_group.group("square") or following_group.group("wide") or "").strip() if following_group else ""
        next_token_is_episode = bool(
            following_token_text
            and (
                re.fullmatch(r"\d{1,3}(?:v\d+)?", following_token_text, flags=re.I)
                or EPISODE_WORD_RE.fullmatch(following_token_text)
            )
        )
        leading_is_title = bool(
            _looks_like_title_token(leading_value)
            and not _looks_like_fansub_token(leading_value)
            and (
                leading_group.group("wide")
                or next_token_is_episode
                or _is_generic_release_tag(following_token_text)
                or bool(re.search(r"[\u4e00-\u9fff]", leading_value))
            )
        )
        if _looks_like_fansub_token(leading_value):
            fansub = leading_value
        elif leading_is_title:
            bracket_title = leading_value
        working = working[leading_group.end() :].strip()
    else:
        leading_star = re.match(r"^(?P<fansub>[^★]{2,40})★", working)
        if leading_star and ("字幕" in leading_star.group("fansub") or "组" in leading_star.group("fansub")):
            fansub = leading_star.group("fansub").strip()
            working = working[leading_star.end() :].strip()

    episode = None
    episode_end = None
    explicit_batch = False
    explicit_multi_episode = False
    is_special = False
    absolute_episode_start = None
    absolute_episode_end = None
    season_episode_start = None
    season_episode_end = None
    batch_title = None
    parse_rule_name = None
    bracket_tokens = [a or b or c for a, b, c in re.findall(r"\[([^\]]+)\]|\(([^\)]+)\)|【([^】]+)】", working)]
    for token in bracket_tokens:
        token = token.strip()
        if not token:
            continue
        final_range = TOKEN_FINAL_RANGE_RE.fullmatch(token)
        if final_range:
            episode = int(final_range.group("start"))
            episode_end = int(final_range.group("end"))
            explicit_batch = True
            explicit_multi_episode = episode_end > episode
            parse_rule_name = "完结合集范围"
            continue
        decimal_batch_range = TOKEN_DECIMAL_BATCH_RANGE_RE.fullmatch(token)
        if decimal_batch_range and (
            decimal_batch_range.group("batch")
            or decimal_batch_range.group("season_start") is not None
            or "." in decimal_batch_range.group("start")
            or "." in decimal_batch_range.group("end")
        ):
            absolute_episode_start = _format_episode_value(decimal_batch_range.group("start"))
            absolute_episode_end = _format_episode_value(decimal_batch_range.group("end"))
            if decimal_batch_range.group("season_start") is not None and decimal_batch_range.group("season_end") is not None:
                season_episode_start = int(decimal_batch_range.group("season_start"))
                season_episode_end = int(decimal_batch_range.group("season_end"))
                episode = season_episode_start
                episode_end = season_episode_end
            elif "." not in decimal_batch_range.group("start") and "." not in decimal_batch_range.group("end"):
                episode = int(decimal_batch_range.group("start"))
                episode_end = int(decimal_batch_range.group("end"))
            explicit_batch = True
            explicit_multi_episode = True
            batch_title = token
            is_special = is_special or bool(SPECIAL_KEYWORD_RE.search(token))
            parse_rule_name = "小数合集范围" if "." in token else "合集范围"
            continue
        batch_range = TOKEN_BATCH_RANGE_RE.search(token)
        if batch_range:
            episode = int(batch_range.group("start"))
            episode_end = int(batch_range.group("end"))
            explicit_batch = True
            explicit_multi_episode = episode_end > episode
            is_special = is_special or bool(SPECIAL_KEYWORD_RE.search(token))
            parse_rule_name = "合集范围"
            continue
        any_range = TOKEN_ANY_RANGE_RE.fullmatch(token)
        if any_range:
            episode = int(any_range.group("start"))
            episode_end = int(any_range.group("end"))
            explicit_multi_episode = episode_end > episode
            explicit_batch = explicit_batch or (episode == 1 and episode_end - episode + 1 >= 6)
            parse_rule_name = "方括号合集范围" if explicit_batch else "方括号多集范围"
            continue
        version_episode = re.fullmatch(r"(?P<episode>\d{1,3})\s*(?P<version>v\d+)", token, flags=re.I)
        if version_episode:
            if episode is None:
                episode = int(version_episode.group("episode"))
                parse_rule_name = "方括号集数版本"
            continue
        if SIZE_RE.fullmatch(token):
            continue
        if RESOLUTION_RE.search(token) or LANGUAGE_RE.search(token) or VERSION_RE.search(token):
            continue
        episode_word = EPISODE_WORD_RE.fullmatch(token)
        if episode_word:
            if episode is None:
                episode = int(episode_word.group("episode"))
                parse_rule_name = "第01话"
            if episode_word.group("episode_end"):
                episode_end = int(episode_word.group("episode_end"))
                parse_rule_name = "第01话合集范围"
            continue
        if re.fullmatch(r"\d{1,3}(?:\s*[-~]\s*\d{1,3})?", token):
            parts = re.split(r"\s*[-~]\s*", token)
            if episode is None:
                episode = int(parts[0])
                parse_rule_name = "方括号集数"
            if len(parts) > 1:
                episode_end = int(parts[1])
                explicit_multi_episode = episode_end > episode
                explicit_batch = explicit_batch or (episode == 1 and episode_end - episode + 1 >= 6)
                parse_rule_name = "方括号合集范围" if explicit_batch else "方括号多集范围"
            continue
        if not _looks_like_title_token(token):
            continue
        if bracket_title is None or _looks_like_release_season_label(bracket_title) or len(token) > len(bracket_title) + 4:
            bracket_title = token

    absolute_match = PART_DASH_EPISODE_RE.search(working)
    season_match = (
        SEASON_EPISODE_REPEAT_RANGE_RE.search(working)
        or SEASON_EPISODE_RE.search(working)
        or SEASON_DASH_EPISODE_RE.search(working)
        or SEASON_WORD_DASH_EPISODE_RE.search(working)
    )
    if season_match:
        groups = season_match.groupdict()
        explicit_season = int(groups.get("season") or groups.get("ord") or _cn_int(groups.get("cn")) or 0) or None
        episode = int(season_match.group("episode"))
        parse_rule_name = (
            "SxxExx-SxxExx"
            if season_match.re is SEASON_EPISODE_REPEAT_RANGE_RE
            else "SxxExx"
            if season_match.re is SEASON_EPISODE_RE
            else "Season - 集数"
        )
        if season_match.group("episode_end"):
            episode_end = int(season_match.group("episode_end"))
            explicit_multi_episode = episode_end > episode
    elif absolute_match:
        part_number = int(absolute_match.group("part"))
        episode = int(absolute_match.group("episode"))
        parse_rule_name = "Part 后绝对集数"
    elif episode is None:
        episode_working = SEASON_MARK_RE.sub(" ", working)
        episode_match = (
            STAR_RANGE_RE.search(episode_working)
            or TOKEN_RANGE_RE.search(episode_working)
            or TOKEN_SINGLE_FINAL_RE.search(episode_working)
            or STAR_SINGLE_RE.search(episode_working)
            or EP_PREFIX_RE.search(episode_working)
            or EPISODE_WORD_RE.search(episode_working)
            or DASH_RELEASE_EPISODE_RE.search(episode_working)
            or EPISODE_RE.search(episode_working)
        )
        if episode_match:
            groups = episode_match.groupdict()
            if groups.get("start"):
                episode = int(groups["start"])
                episode_end = int(groups["end"])
                parse_rule_name = "星号合集范围" if episode_match.re is STAR_RANGE_RE else "合集范围"
                explicit_multi_episode = episode_end > episode
                explicit_batch = episode_match.re is STAR_RANGE_RE or bool(FINAL_RE.search(episode_match.group(0))) or (episode == 1 and episode_end - episode + 1 >= 6)
            else:
                episode = int(groups["episode"])
                if groups.get("episode_end"):
                    episode_end = int(groups["episode_end"])
                    explicit_multi_episode = episode_end > episode
                    parse_rule_name = "第01话合集范围" if explicit_batch else "第01话多集范围"
                elif episode_match.re is STAR_SINGLE_RE:
                    parse_rule_name = "星号单集"
                elif episode_match.re is EP_PREFIX_RE:
                    parse_rule_name = "EP 集数"
                elif episode_match.re is TOKEN_SINGLE_FINAL_RE:
                    parse_rule_name = "完结单集"
                elif episode_match.re is EPISODE_WORD_RE:
                    parse_rule_name = "第01话"
                elif episode_match.re is DASH_RELEASE_EPISODE_RE:
                    parse_rule_name = "末尾发布集数"
                else:
                    parse_rule_name = "内置集数"

    full_episode_count = FULL_EPISODE_COUNT_RE.search(working)
    if full_episode_count:
        count = int(full_episode_count.group("prefix_count") or full_episode_count.group("suffix_count"))
        has_explicit_range = episode is not None and episode_end is not None and episode_end > episode
        if count > 1 and not has_explicit_range and episode in {None, 1}:
            episode = 1
            episode_end = count
            explicit_batch = True
            explicit_multi_episode = True
            parse_rule_name = "全集数量"

    resolution_match = RESOLUTION_RE.search(working)
    language_match = LANGUAGE_RE.search(working)
    version_match = VERSION_RE.search(working)
    size_match = SIZE_RE.search(working)
    is_final = bool(FINAL_RE.search(working))
    is_special = is_special or bool(SPECIAL_KEYWORD_RE.search(working)) and episode is None
    if episode is not None and episode_end is not None and episode_end > episode:
        explicit_multi_episode = True
    is_batch = bool(
        explicit_batch
        or EXPLICIT_BATCH_RE.search(working)
        or (explicit_multi_episode and bool(BATCH_KEYWORD_RE.search(working)))
        or (explicit_multi_episode and is_final)
    )
    if explicit_season is None and is_batch and episode == 1 and episode_end is not None and episode_end > episode:
        inferred_season = 1
    effective_season, season_source, season_conflict, season_conflict_reason = _resolve_season(
        explicit_season=explicit_season,
        inferred_season=inferred_season,
        context_season=context_season_number,
    )

    cleaned = re.sub(r"\[[^\]]+\]|\([^\)]*\)|【[^】]+】", " ", working)
    cleaned = RESOLUTION_RE.sub(" ", cleaned)
    cleaned = LANGUAGE_RE.sub(" ", cleaned)
    cleaned = VERSION_RE.sub(" ", cleaned)
    cleaned = SIZE_RE.sub(" ", cleaned)
    cleaned = SEASON_EPISODE_RE.sub(" ", cleaned)
    cleaned = SEASON_DASH_EPISODE_RE.sub(" ", cleaned)
    cleaned = SEASON_WORD_DASH_EPISODE_RE.sub(" ", cleaned)
    cleaned = PART_DASH_EPISODE_RE.sub(" ", cleaned)
    cleaned = PART_MARK_RE.sub(" ", cleaned)
    cleaned = SEASON_MARK_RE.sub(" ", cleaned)
    cleaned = STAR_RANGE_RE.sub(" ", cleaned)
    cleaned = STAR_SINGLE_RE.sub(" ", cleaned)
    cleaned = EP_PREFIX_RE.sub(" ", cleaned)
    cleaned = TOKEN_SINGLE_FINAL_RE.sub(" ", cleaned)
    cleaned = TOKEN_RANGE_RE.sub(" ", cleaned)
    if batch_title:
        cleaned = cleaned.replace(batch_title, " ")
    cleaned = EPISODE_WORD_RE.sub(" ", cleaned)
    cleaned = DASH_RELEASE_EPISODE_RE.sub(" ", cleaned)
    cleaned = EPISODE_RE.sub(" ", cleaned)
    cleaned = re.sub(r"\.(mkv|mp4|avi|ass|srt)$", " ", cleaned, flags=re.I)
    cleaned = re.sub(r"[★\s_\-]+", " ", cleaned).strip(" -_★")
    parsed_title = cleaned or bracket_title

    confidence = 0.25
    if parsed_title:
        confidence += 0.25
    if episode is not None:
        confidence += 0.25
    if fansub or resolution_match:
        confidence += 0.15
    if language_match:
        confidence += 0.10
    confidence = min(confidence, 0.95)
    parse_failure_reason = None if episode is not None else "未识别到集数，可在订阅设置的集数识别中添加自定义规则。"

    return ParsedAnimeTitle(
        original_title=raw_title,
        title=parsed_title,
        episode=episode,
        episode_number=episode,
        episode_start=episode,
        episode_end=episode_end,
        is_batch=is_batch,
        is_multi_episode=explicit_multi_episode,
        is_final=is_final,
        is_special=is_special,
        parse_rule_name=parse_rule_name,
        parse_reason=parse_rule_name,
        parse_confidence=round(confidence, 2),
        parse_failure_reason=parse_failure_reason,
        season=effective_season,
        season_number=effective_season,
        explicit_season_number=explicit_season,
        inferred_season_number=inferred_season,
        context_season_number=context_season_number,
        effective_season_number=effective_season,
        season_source=season_source,
        season_conflict=season_conflict,
        season_conflict_reason=season_conflict_reason,
        part_number=part_number,
        absolute_episode_number=episode if absolute_match else None,
        absolute_episode_start=absolute_episode_start,
        absolute_episode_end=absolute_episode_end,
        absolute_episode_start_sort=float(absolute_episode_start) if absolute_episode_start is not None else None,
        absolute_episode_end_sort=float(absolute_episode_end) if absolute_episode_end is not None else None,
        season_episode_start=season_episode_start,
        season_episode_end=season_episode_end,
        batch_title=batch_title,
        fansub=fansub,
        resolution=resolution_match.group(1) if resolution_match else None,
        subtitle_language=language_match.group(1) if language_match else None,
        version=version_match.group(1) if version_match else None,
        file_size=size_match.group(1).replace(" ", "") if size_match else None,
        confidence=round(confidence, 2),
        needs_confirmation=confidence < 0.75,
    )
