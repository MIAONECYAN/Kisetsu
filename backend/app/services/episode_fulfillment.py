from __future__ import annotations

import re
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from app.db import Store
from app.models import (
    MetadataBindingRecord,
    OrganizeTarget,
    ParsedAnimeTitle,
    PlexMappingRecord,
    PlexSeasonMapping,
    Subscription,
    SubscriptionMatch,
)
from app.services.plex_naming import clean_path_component, season_directory, show_directory
from app.services.title_parser import parse_title

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".webm"}
SUCCESSFUL_ORGANIZE_STATUSES = {"moved", "skipped"}
ACTIVE_DOWNLOAD_STATUSES = {"pending_confirmation", "queued", "completed"}


@dataclass(frozen=True)
class EpisodeOrganizeState:
    status: Literal["已整理", "等待重新整理", "需要检查"]
    detail: str
    candidate_count: int = 0


@dataclass(frozen=True)
class EpisodeMediaIndex:
    target_available: bool
    states: dict[tuple[int, int], EpisodeOrganizeState]
    prior_organized_keys: frozenset[tuple[int, int]] = frozenset()
    unavailable_reason: str | None = None


@dataclass(frozen=True)
class EpisodeFulfillmentDecision:
    blocked: bool
    reason: str | None
    episode_keys: frozenset[tuple[int, int]]


def subscription_detail_metadata_bindings(
    subscription_id: int,
    matches: list[SubscriptionMatch] | list[dict],
    store: Store,
) -> list[MetadataBindingRecord]:
    subscription_rows = store.list_metadata_bindings_for_target("subscription", str(subscription_id), limit=100)
    rows = subscription_rows[:1]
    resource_rows: list[dict] = []
    for match in matches:
        match_id = match.id if isinstance(match, SubscriptionMatch) else match.get("id")
        if match_id is None:
            continue
        resource_rows.extend(
            store.list_metadata_bindings_for_target(
                "resource",
                f"subscription-match:{match_id}",
                limit=20,
            )
        )
    unique_resource_rows = {item["id"]: item for item in resource_rows}
    ordered_rows = rows + sorted(unique_resource_rows.values(), key=lambda item: item["id"], reverse=True)
    return [MetadataBindingRecord(**item) for item in ordered_rows]


def current_subscription_metadata_binding(
    subscription_id: int,
    metadata_bindings: list[MetadataBindingRecord],
) -> MetadataBindingRecord | None:
    target_id = str(subscription_id)
    return next(
        (
            binding
            for binding in metadata_bindings
            if binding.target_type == "subscription" and binding.target_id == target_id
        ),
        None,
    )


def subscription_detail_plex_mappings(
    metadata_bindings: list[MetadataBindingRecord],
    store: Store,
) -> list[PlexMappingRecord]:
    subject_keys: list[str] = []
    for binding in metadata_bindings:
        if binding.bangumi_id:
            subject_keys.append(f"bangumi:{binding.bangumi_id}")
        if binding.tmdb_id:
            subject_keys.append(f"tmdb:{binding.tmdb_id}")

    records: list[PlexMappingRecord] = []
    seen: set[str] = set()
    for subject_key in subject_keys:
        if subject_key in seen:
            continue
        seen.add(subject_key)
        item = store.get_plex_mapping(subject_key)
        if item is not None:
            records.append(PlexMappingRecord(**item))
    return records


def mapping_for_subscription(
    subscription: Subscription,
    metadata_bindings: list[MetadataBindingRecord],
    plex_mappings: list[PlexMappingRecord],
) -> PlexSeasonMapping:
    if plex_mappings:
        return plex_mappings[0].mapping
    binding = current_subscription_metadata_binding(subscription.id, metadata_bindings)
    if binding is None:
        binding = metadata_bindings[0] if metadata_bindings else None
    title = binding.selected_title if binding and binding.selected_title else subscription.name
    year = None
    if binding and binding.air_date:
        with suppress(ValueError):
            year = int(binding.air_date[:4])
    return PlexSeasonMapping(
        subject_key=f"subscription:{subscription.id}",
        show_name=title,
        show_year=year,
        season_number=subscription.season if subscription.season is not None else 1,
        episode_offset=subscription.episode_offset,
    )


def media_target_for_subscription(subscription: Subscription, store: Store) -> OrganizeTarget | None:
    if subscription.organize_target_id is not None:
        target = store.get_organize_target(subscription.organize_target_id)
        return OrganizeTarget(**target) if target is not None else None
    target = store.default_organize_target()
    return OrganizeTarget(**target) if target is not None else None


def covered_episode_numbers(
    episode: int | None,
    episode_start: int | None,
    episode_end: int | None,
    *,
    max_span: int = 200,
) -> set[int]:
    start = episode_start or episode
    end = episode_end or start
    if start is None or end is None or start <= 0 or end <= 0:
        return set()
    if end < start:
        end = start
    if end - start + 1 > max_span:
        end = start + max_span - 1
    return set(range(start, end + 1))


def subscription_logical_episode_numbers(
    subscription: Subscription,
    parsed: ParsedAnimeTitle,
) -> set[int]:
    if parsed.season_episode_start is not None and parsed.season_episode_end is not None:
        covered = covered_episode_numbers(
            None,
            parsed.season_episode_start,
            parsed.season_episode_end,
        )
        if covered:
            return covered
    covered = covered_episode_numbers(parsed.episode, parsed.episode_start, parsed.episode_end)
    if subscription.episode_offset == 0:
        return covered
    return {
        episode + subscription.episode_offset
        for episode in covered
        if episode + subscription.episode_offset > 0
    }


def subscription_target_episode_start(
    subscription: Subscription,
    *,
    logical: bool = True,
) -> int:
    start = max(1, subscription.episode_start or 1)
    if logical:
        start = max(1, start + subscription.episode_offset)
    return start


def subscription_episode_range_reaches_target(
    subscription: Subscription,
    episode_end: int | None,
    *,
    logical: bool = False,
) -> bool:
    if episode_end is None:
        return False
    return episode_end >= subscription_target_episode_start(subscription, logical=logical)


def subscription_episode_in_target_scope(
    subscription: Subscription,
    episode_number: int,
) -> bool:
    return episode_number >= subscription_target_episode_start(subscription)


def subscription_target_episode_counts(
    subscription: Subscription,
    catalog_total_episodes: int | None,
) -> tuple[int | None, int]:
    start = subscription_target_episode_start(subscription)
    skipped_before_start = start - 1
    if catalog_total_episodes is None:
        return None, skipped_before_start
    skipped_before_start = min(catalog_total_episodes, skipped_before_start)
    target_total = max(0, catalog_total_episodes - start + 1)
    return target_total, skipped_before_start


def episode_keys_for_parsed_title(
    subscription: Subscription,
    parsed: ParsedAnimeTitle,
) -> set[tuple[int, int]]:
    episodes = subscription_logical_episode_numbers(subscription, parsed)
    season = (
        parsed.effective_season_number
        if parsed.effective_season_number is not None
        else parsed.season_number
        if parsed.season_number is not None
        else parsed.season
        if parsed.season is not None
        else subscription.season
        if subscription.season is not None
        else 1
    )
    return {(season, episode) for episode in episodes}


def _episode_keys_from_media_name(
    filename: str,
    mapping: PlexSeasonMapping,
) -> set[tuple[int, int]]:
    stem = Path(filename).stem
    show_name = clean_path_component(mapping.show_name)
    match = re.fullmatch(
        rf"{re.escape(show_name)} - S0*(\d{{1,2}})E0*(\d{{1,3}})(?:-E0*(\d{{1,3}}))?(?: - .+)?",
        stem,
        flags=re.IGNORECASE,
    )
    if match is None:
        return set()
    season = int(match.group(1))
    start = int(match.group(2))
    end = int(match.group(3) or start)
    if start < 1 or end < start or end - start > 100:
        return set()
    return {(season, episode) for episode in range(start, end + 1)}


def _episode_keys_from_record_path(value: str | None) -> set[tuple[int, int]]:
    if not value:
        return set()
    match = re.search(
        r"(?i)(?<![A-Za-z0-9])S0*(\d{1,2})E0*(\d{1,3})(?:-E0*(\d{1,3}))?(?!\d)",
        Path(value).stem,
    )
    if match is None:
        return set()
    season = int(match.group(1))
    start = int(match.group(2))
    end = int(match.group(3) or start)
    if start < 1 or end < start or end - start > 100:
        return set()
    return {(season, episode) for episode in range(start, end + 1)}


def _path_is_inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, RuntimeError, ValueError):
        return False
    return True


def build_episode_media_index(
    subscription: Subscription,
    organize_target: OrganizeTarget | None,
    mapping: PlexSeasonMapping,
    store: Store,
) -> EpisodeMediaIndex:
    organize_records = store.list_organize_history(
        limit=100000,
        subscription_id=subscription.id,
    )
    prior_organized_keys: set[tuple[int, int]] = set()
    for record in organize_records:
        if record.get("status") not in SUCCESSFUL_ORGANIZE_STATUSES:
            continue
        destination_value = str(record.get("destination_path") or "").strip()
        if not destination_value:
            destination_value = str(
                (record.get("preview") or {}).get("destination_preview") or ""
            ).strip()
        prior_organized_keys.update(_episode_keys_from_record_path(destination_value))

    if organize_target is None or not organize_target.enabled:
        return EpisodeMediaIndex(
            target_available=False,
            states={},
            prior_organized_keys=frozenset(prior_organized_keys),
            unavailable_reason="整理目标未配置或已停用",
        )
    root = Path(organize_target.path).expanduser()
    if not root.exists() or not root.is_dir():
        return EpisodeMediaIndex(
            target_available=False,
            states={},
            prior_organized_keys=frozenset(prior_organized_keys),
            unavailable_reason="整理目标存储暂时不可访问",
        )

    season = (
        subscription.season
        if subscription.season is not None
        else mapping.season_number
        if mapping.season_number is not None
        else 1
    )
    season_root = root / show_directory(mapping) / season_directory(season)
    candidates: dict[tuple[int, int], set[str]] = {}
    unsafe_keys: set[tuple[int, int]] = set()

    def register(path: Path, keys: set[tuple[int, int]]) -> None:
        relevant_keys = {key for key in keys if key[0] == season}
        if not relevant_keys:
            return
        if path.is_symlink():
            unsafe_keys.update(relevant_keys)
            return
        try:
            valid_file = path.is_file() and path.stat().st_size > 0
        except OSError:
            valid_file = False
        if not valid_file:
            return
        if not _path_is_inside(path, root):
            unsafe_keys.update(relevant_keys)
            return
        try:
            resolved = path.resolve(strict=True)
            expected_parent = season_root.resolve(strict=True)
        except (OSError, RuntimeError):
            return
        if resolved.parent != expected_parent:
            return
        for key in relevant_keys:
            candidates.setdefault(key, set()).add(str(resolved))

    for record in organize_records:
        destination_value = str(record.get("destination_path") or "").strip()
        if not destination_value:
            destination_value = str(
                (record.get("preview") or {}).get("destination_preview") or ""
            ).strip()
        destination = Path(destination_value).expanduser() if destination_value else None
        if destination is None:
            continue
        try:
            if destination.parent.resolve(strict=False) != season_root.resolve(strict=False):
                continue
        except (OSError, RuntimeError):
            continue
        register(destination, _episode_keys_from_record_path(destination.name))

    if season_root.exists() and season_root.is_dir():
        try:
            children = list(season_root.iterdir())
        except OSError:
            children = []
        for child in children:
            if child.suffix.lower() not in VIDEO_EXTENSIONS:
                continue
            register(child, _episode_keys_from_media_name(child.name, mapping))

    states: dict[tuple[int, int], EpisodeOrganizeState] = {}
    for key in candidates.keys() | unsafe_keys:
        count = len(candidates.get(key, set()))
        if key in unsafe_keys or count > 1:
            states[key] = EpisodeOrganizeState(
                status="需要检查",
                detail="整理目标中存在多个候选文件或不安全的符号链接",
                candidate_count=count,
            )
        elif count == 1:
            states[key] = EpisodeOrganizeState(
                status="已整理",
                detail="整理目标文件存在",
                candidate_count=1,
            )
    return EpisodeMediaIndex(
        target_available=True,
        states=states,
        prior_organized_keys=frozenset(prior_organized_keys),
    )


def build_subscription_episode_media_index(
    subscription: Subscription,
    store: Store,
) -> EpisodeMediaIndex:
    matches = store.list_subscription_matches(subscription.id)
    metadata_bindings = subscription_detail_metadata_bindings(
        subscription.id,
        matches,
        store,
    )
    plex_mappings = subscription_detail_plex_mappings(metadata_bindings, store)
    mapping = mapping_for_subscription(subscription, metadata_bindings, plex_mappings)
    return build_episode_media_index(
        subscription,
        media_target_for_subscription(subscription, store),
        mapping,
        store,
    )


def submitted_episode_keys(
    subscription: Subscription,
    store: Store,
) -> set[tuple[int, int]]:
    active_history = [
        item
        for item in store.list_history(subscription_id=subscription.id, limit=100000)
        if item.get("status") in ACTIVE_DOWNLOAD_STATUSES
    ]
    if not active_history:
        return set()
    active_by_fingerprint = {
        str(item.get("fingerprint") or ""): item
        for item in active_history
    }
    keys: set[tuple[int, int]] = set()
    for match in store.list_subscription_matches(subscription.id):
        fingerprint = str(match.get("fingerprint") or "")
        if fingerprint not in active_by_fingerprint:
            continue
        try:
            parsed = ParsedAnimeTitle(**match["parsed_title"])
        except (KeyError, TypeError, ValueError):
            continue
        keys.update(episode_keys_for_parsed_title(subscription, parsed))
        active_by_fingerprint.pop(fingerprint, None)
    for history in active_by_fingerprint.values():
        title = str(history.get("torrent_name") or history.get("title") or "").strip()
        if not title:
            continue
        parsed = parse_title(
            title,
            subscription.episode_parse_rules,
            context_season_number=subscription.season,
        )
        keys.update(episode_keys_for_parsed_title(subscription, parsed))
    return keys


def automatic_download_fulfillment_decision(
    subscription: Subscription,
    parsed: ParsedAnimeTitle,
    media_index: EpisodeMediaIndex,
) -> EpisodeFulfillmentDecision:
    keys = frozenset(episode_keys_for_parsed_title(subscription, parsed))
    if not keys:
        return EpisodeFulfillmentDecision(blocked=False, reason=None, episode_keys=keys)

    states = [media_index.states.get(key) for key in keys]
    if states and all(state is not None and state.status == "已整理" for state in states):
        return EpisodeFulfillmentDecision(
            blocked=True,
            reason="已存在整理目标文件",
            episode_keys=keys,
        )
    if any(state is not None and state.status == "需要检查" for state in states):
        return EpisodeFulfillmentDecision(
            blocked=True,
            reason="整理目标文件需要检查，已暂停自动下载",
            episode_keys=keys,
        )
    if (
        not media_index.target_available
        and media_index.unavailable_reason == "整理目标存储暂时不可访问"
        and keys.intersection(media_index.prior_organized_keys)
    ):
        return EpisodeFulfillmentDecision(
            blocked=True,
            reason="整理目标存储暂时不可访问，已保留已整理状态",
            episode_keys=keys,
        )
    return EpisodeFulfillmentDecision(blocked=False, reason=None, episode_keys=keys)
