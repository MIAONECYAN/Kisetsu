from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from difflib import SequenceMatcher

from app.playlists.models import PlaylistQuarterItem, PlexPairing, PlexShow


MATCHABLE_EXTERNAL_IDS = {"tmdb", "tvdb", "imdb"}


def normalize_title(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def normalize_external_id(site: str, value: str) -> tuple[str, str] | None:
    key = site.casefold().strip()
    identifier = value.strip()
    if key not in MATCHABLE_EXTERNAL_IDS or not identifier:
        return None
    if key == "tmdb":
        identifier = re.sub(r"^(?:tv|movie)/", "", identifier, flags=re.I)
    return key, identifier.casefold()


def plex_external_ids(show: PlexShow) -> set[tuple[str, str]]:
    result: set[tuple[str, str]] = set()
    for guid in show.guids:
        match = re.match(r"(?P<site>[A-Za-z0-9_-]+)://(?P<id>[^?/#]+)", guid)
        if match:
            normalized = normalize_external_id(match.group("site"), match.group("id"))
            if normalized:
                result.add(normalized)
    return result


def item_external_ids(item: PlaylistQuarterItem) -> set[tuple[str, str]]:
    return {
        normalized
        for site, value in item.external_ids.items()
        if (normalized := normalize_external_id(site, value)) is not None
    }


def show_titles(show: PlexShow) -> set[str]:
    return {
        normalized
        for value in (show.title, show.original_title)
        if value and (normalized := normalize_title(value))
    }


def similarity_ratio(left: str, right: str, *, minimum: float) -> float:
    matcher = SequenceMatcher(None, left, right)
    if matcher.real_quick_ratio() < minimum or matcher.quick_ratio() < minimum:
        return 0
    return matcher.ratio()


@dataclass(slots=True)
class MatchDecision:
    pairing: PlexPairing | None
    state: str
    reason: str
    candidates: list[PlexShow]


@dataclass(slots=True)
class PlexShowMatchIndex:
    shows: list[PlexShow]
    external_ids: list[frozenset[tuple[str, str]]]
    titles: list[tuple[str, ...]]
    external_lookup: dict[tuple[str, str], tuple[int, ...]]
    title_lookup: dict[str, tuple[int, ...]]

    def external_matches(self, values: set[tuple[str, str]]) -> list[PlexShow]:
        indices = {
            index
            for value in values
            for index in self.external_lookup.get(value, ())
        }
        return [self.shows[index] for index in sorted(indices)]

    def title_matches(self, values: set[str]) -> list[PlexShow]:
        indices = {
            index
            for value in values
            for index in self.title_lookup.get(value, ())
        }
        return [self.shows[index] for index in sorted(indices)]


def build_match_index(shows: list[PlexShow]) -> PlexShowMatchIndex:
    indexed_external_ids: list[frozenset[tuple[str, str]]] = []
    indexed_titles: list[tuple[str, ...]] = []
    external_lookup_lists: dict[tuple[str, str], list[int]] = {}
    title_lookup_lists: dict[str, list[int]] = {}
    for index, show in enumerate(shows):
        external_ids = frozenset(plex_external_ids(show))
        titles = tuple(show_titles(show))
        indexed_external_ids.append(external_ids)
        indexed_titles.append(titles)
        for value in external_ids:
            external_lookup_lists.setdefault(value, []).append(index)
        for value in titles:
            title_lookup_lists.setdefault(value, []).append(index)
    return PlexShowMatchIndex(
        shows=shows,
        external_ids=indexed_external_ids,
        titles=indexed_titles,
        external_lookup={key: tuple(value) for key, value in external_lookup_lists.items()},
        title_lookup={key: tuple(value) for key, value in title_lookup_lists.items()},
    )


def decide_match(
    item: PlaylistQuarterItem,
    shows: list[PlexShow] | PlexShowMatchIndex,
) -> MatchDecision:
    index = shows if isinstance(shows, PlexShowMatchIndex) else build_match_index(shows)
    external_ids = item_external_ids(item)
    if external_ids:
        external_matches = index.external_matches(external_ids)
        if len(external_matches) == 1:
            show = external_matches[0]
            return MatchDecision(
                pairing=PlexPairing(
                    item_key=item.key,
                    plex_rating_key=show.rating_key,
                    title=show.title,
                    year=show.year,
                    source="external_id",
                    score=1,
                    reason="Plex 外部 GUID 精确匹配",
                ),
                state="matched",
                reason="Plex 外部 GUID 精确匹配",
                candidates=external_matches,
            )
        if len(external_matches) > 1:
            return MatchDecision(None, "ambiguous", "同一外部 ID 对应多个 Plex 节目，需要手动确认。", external_matches)

    item_titles = {
        normalized
        for value in [item.title, item.original_title, *item.aliases]
        if (normalized := normalize_title(value))
    }
    exact = index.title_matches(item_titles)
    compatible = [show for show in exact if show.year is None or abs(show.year - item.begin.year) <= 1]
    if len(compatible) == 1:
        show = compatible[0]
        return MatchDecision(
            pairing=PlexPairing(
                item_key=item.key,
                plex_rating_key=show.rating_key,
                title=show.title,
                year=show.year,
                source="title",
                score=0.92 if show.year == item.begin.year else 0.88,
                reason="标准化标题精确匹配，年份相容",
            ),
            state="matched",
            reason="标准化标题精确匹配，年份相容",
            candidates=compatible,
        )
    if exact:
        return MatchDecision(None, "ambiguous", "标题对应多个节目或年份冲突，需要手动确认。", exact)

    scored: list[tuple[float, PlexShow]] = []
    for show, titles in zip(index.shows, index.titles, strict=True):
        score = max(
            (
                similarity_ratio(left, right, minimum=0.55)
                for left in item_titles
                for right in titles
            ),
            default=0,
        )
        if score >= 0.55:
            scored.append((score, show))
    scored.sort(key=lambda value: value[0], reverse=True)
    candidates = [show for _, show in scored[:8]]
    if candidates:
        return MatchDecision(None, "ambiguous", "只找到模糊标题候选，未自动配对。", candidates)
    return MatchDecision(None, "unmatched", "Plex 媒体库中没有可靠候选。", [])


def search_shows(shows: list[PlexShow], query: str, *, limit: int = 30) -> list[PlexShow]:
    normalized_query = normalize_title(query)
    if not normalized_query:
        return shows[:limit]
    scored: list[tuple[float, PlexShow]] = []
    for show in shows:
        titles = show_titles(show)
        if any(normalized_query in value for value in titles):
            score = 1.0
        else:
            score = max(
                (similarity_ratio(normalized_query, value, minimum=0.35) for value in titles),
                default=0,
            )
        if score >= 0.35:
            scored.append((score, show))
    scored.sort(key=lambda value: (-value[0], value[1].title.casefold()))
    return [show for _, show in scored[:limit]]
