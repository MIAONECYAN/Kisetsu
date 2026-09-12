from __future__ import annotations

import re
from pathlib import Path

from app.models import OrganizePreviewItem, OrganizePreviewRequest, ParsedAnimeTitle, PlexSeasonMapping


INVALID_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def clean_path_component(value: str) -> str:
    cleaned = INVALID_FILENAME_CHARS.sub(" ", value)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned.rstrip(".") or "未命名条目"


def show_directory(mapping: PlexSeasonMapping) -> str:
    show = clean_path_component(mapping.show_name)
    if mapping.show_year:
        return f"{show} ({mapping.show_year})"
    return show


def season_directory(season_number: int) -> str:
    return f"Season {season_number:02d}"


def extension_for(filename: str) -> str:
    suffix = Path(filename).suffix
    return suffix if suffix else ".mkv"


def episode_code(season: int, episode: int, episode_end: int | None = None) -> str:
    if episode_end and episode_end != episode:
        return f"S{season:02d}E{episode:02d}-E{episode_end:02d}"
    return f"S{season:02d}E{episode:02d}"


def preview_path(request: OrganizePreviewRequest) -> OrganizePreviewItem:
    if request.media_type == "movie":
        show_dir = show_directory(request.mapping)
        filename = show_dir + extension_for(request.original_filename)
        library_root = request.library_root.strip() or "Anime Library"
        return OrganizePreviewItem(
            media_type="movie",
            source_path=request.source_path,
            library_root=library_root,
            show_directory=show_dir,
            season_directory="",
            filename=filename,
            destination_preview=str(Path(library_root) / show_dir / filename),
        )
    parsed = request.parsed_title or ParsedAnimeTitle(original_title=request.original_filename)
    mapping = request.mapping
    warnings: list[str] = []
    season = 0 if request.is_special else (parsed.season or mapping.season_number)
    episode = parsed.episode
    if episode is None:
        episode = 1 + mapping.episode_offset
        warnings.append("未识别到集数，已按映射起始集数生成预览。")
    else:
        episode += mapping.episode_offset

    episode_end = parsed.episode_end
    if episode_end is not None:
        episode_end += mapping.episode_offset

    show_dir = show_directory(mapping)
    season_dir = season_directory(season)
    code = episode_code(season, episode, episode_end)
    title_bits = [clean_path_component(mapping.show_name), "-", code]
    if request.episode_title:
        title_bits.extend(["-", clean_path_component(request.episode_title)])
    filename = " ".join(title_bits) + extension_for(request.original_filename)
    library_root = request.library_root.strip() or "Anime Library"
    destination = str(Path(library_root) / show_dir / season_dir / filename)
    return OrganizePreviewItem(
        media_type=request.media_type,
        source_path=request.source_path,
        library_root=library_root,
        show_directory=show_dir,
        season_directory=season_dir,
        filename=filename,
        destination_preview=destination,
        will_move=False,
        warnings=warnings,
    )
