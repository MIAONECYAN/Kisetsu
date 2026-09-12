from __future__ import annotations

import errno
import os
import shutil
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path, PurePath

from app.models import OrganizePreviewItem, OrganizePreviewRequest, OrganizeSubtitleMapping
from app.services.plex_naming import clean_path_component, preview_path

SUBTITLE_EXTENSIONS = {".ass", ".ssa", ".srt", ".vtt", ".sup"}
VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".webm"}
_ORGANIZE_COMMIT_LOCK = threading.Lock()
SUBTITLE_LANGUAGE_SUFFIXES = {
    ".chs",
    ".cht",
    ".sc",
    ".tc",
    ".gb",
    ".big5",
    ".zh",
    ".zh-cn",
    ".zh-hans",
    ".zh-tw",
    ".zh-hant",
    ".jpn",
    ".ja",
    ".jp",
    ".eng",
    ".en",
}


class OrganizeApplyError(Exception):
    def __init__(self, message: str, *, status_code: int = 400, destination_path: str | None = None):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.destination_path = destination_path


@dataclass(frozen=True)
class OrganizeApplyResult:
    status: str
    message: str
    source_path: str
    destination_path: str


@dataclass(frozen=True)
class OrganizePreviewAvailability:
    pending: bool
    source_exists: bool
    destination_exists: bool
    reason: str


def _resolved_existing_path(path: Path) -> Path | None:
    if path.is_symlink():
        return None
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError):
        return None


def _same_existing_file(source: Path, destination: Path) -> bool:
    try:
        return source.exists() and destination.exists() and source.samefile(destination)
    except OSError:
        return False


def is_ignored_media_metadata_path(path: PurePath) -> bool:
    parts = tuple(part.casefold() for part in path.parts)
    return (
        path.name.startswith("._")
        or path.name.casefold() == ".ds_store"
        or "__macosx" in parts
    )


def _valid_video_file(path: Path) -> bool:
    if is_ignored_media_metadata_path(path):
        return False
    resolved = _resolved_existing_path(path)
    if resolved is None or resolved.suffix.casefold() not in VIDEO_EXTENSIONS:
        return False
    try:
        return resolved.is_file() and resolved.stat().st_size > 0
    except OSError:
        return False


def _directory_contains_video(path: Path) -> bool:
    resolved_root = _resolved_existing_path(path)
    if resolved_root is None or not resolved_root.is_dir():
        return False
    try:
        candidates = resolved_root.rglob("*")
        for candidate in candidates:
            if (
                candidate.is_symlink()
                or is_ignored_media_metadata_path(candidate.relative_to(resolved_root))
                or candidate.suffix.casefold() not in VIDEO_EXTENSIONS
            ):
                continue
            try:
                resolved = candidate.resolve(strict=True)
                resolved.relative_to(resolved_root)
                if resolved.is_file() and resolved.stat().st_size > 0:
                    return True
            except (OSError, RuntimeError, ValueError):
                continue
    except OSError:
        return False
    return False


def _path_is_inside(path: Path, root: Path) -> bool:
    resolved_path = _resolved_existing_path(path)
    resolved_root = _resolved_existing_path(root)
    if resolved_path is None or resolved_root is None or not resolved_root.is_dir():
        return False
    try:
        resolved_path.relative_to(resolved_root)
    except ValueError:
        return False
    return True


def _valid_preview_source(path: Path) -> bool:
    return _valid_video_file(path) or _directory_contains_video(path)


def organize_preview_availability(preview: OrganizePreviewItem) -> OrganizePreviewAvailability:
    library_root = Path(preview.library_root).expanduser()
    mappings = [
        mapping
        for mapping in preview.file_mappings
        if mapping.status in {"ready", "needs_confirmation"}
    ]

    if mappings:
        target_exists = [Path(mapping.target_path).expanduser().exists() for mapping in mappings]
        if all(target_exists):
            if preview_targets_already_organized(preview):
                return OrganizePreviewAvailability(False, True, True, "所有源文件已在整理目标位置")
            return OrganizePreviewAvailability(False, False, True, "整理目标文件已存在")

        source_exists = False
        for mapping, target_ready in zip(mappings, target_exists, strict=True):
            if target_ready:
                continue
            source = Path(mapping.source_path).expanduser()
            if _path_is_inside(source, library_root):
                continue
            if _valid_video_file(source):
                source_exists = True
                break
        if source_exists:
            return OrganizePreviewAvailability(True, True, any(target_exists), "存在可整理的源文件")
        return OrganizePreviewAvailability(False, False, any(target_exists), "没有可执行的源文件")

    destination = Path(preview.destination_preview).expanduser()
    if destination.is_symlink():
        return OrganizePreviewAvailability(False, False, False, "整理目标是符号链接，需要检查")
    if destination.exists():
        source = Path(preview.source_path).expanduser()
        if _same_existing_file(source, destination):
            return OrganizePreviewAvailability(False, True, True, "源文件已在整理目标位置")
        return OrganizePreviewAvailability(False, False, True, "整理目标文件已存在")

    source = Path(preview.source_path).expanduser()
    if source.is_symlink():
        return OrganizePreviewAvailability(False, False, False, "源路径是符号链接，需要检查")
    if _path_is_inside(source, library_root):
        return OrganizePreviewAvailability(False, True, False, "源路径已位于整理目标目录")
    if _valid_preview_source(source):
        return OrganizePreviewAvailability(True, True, False, "存在可整理的源文件")
    return OrganizePreviewAvailability(False, False, False, "源文件和整理目标均不存在")


def preview_targets_already_organized(preview: OrganizePreviewItem) -> bool:
    mappings = [mapping for mapping in preview.file_mappings if mapping.status != "skipped"]
    if mappings:
        return all(
            _same_existing_file(
                Path(mapping.source_path).expanduser(),
                Path(mapping.target_path).expanduser(),
            )
            for mapping in mappings
        )
    return _same_existing_file(
        Path(preview.source_path).expanduser(),
        Path(preview.destination_preview).expanduser(),
    )


def build_preview(request: OrganizePreviewRequest) -> OrganizePreviewItem:
    preview = preview_path(request)
    return preview.model_copy(update={"subtitle_mappings": subtitle_mappings_for_preview(preview)})


def subtitle_language_suffix(path: Path) -> str:
    suffixes = path.suffixes
    if len(suffixes) < 2:
        return ""
    subtitle_ext = suffixes[-1].lower()
    if subtitle_ext not in SUBTITLE_EXTENSIONS:
        return ""
    language_parts: list[str] = []
    for suffix in reversed(suffixes[:-1]):
        lowered = suffix.lower()
        if lowered not in SUBTITLE_LANGUAGE_SUFFIXES:
            break
        language_parts.insert(0, suffix)
    return "".join(language_parts)


def matching_subtitle_files(source: Path) -> list[Path]:
    if not source.is_file():
        return []
    parent = source.parent
    if not parent.exists():
        return []
    base_name = source.stem
    matches: list[Path] = []
    for candidate in parent.iterdir():
        if not candidate.is_file() or candidate == source:
            continue
        if candidate.suffix.lower() not in SUBTITLE_EXTENSIONS:
            continue
        language_suffix = subtitle_language_suffix(candidate)
        expected_stem = base_name + language_suffix
        if candidate.stem == base_name or candidate.stem == expected_stem:
            matches.append(candidate)
    return sorted(matches, key=lambda item: item.name.casefold())


def subtitle_mappings_for_preview(preview: OrganizePreviewItem) -> list[OrganizeSubtitleMapping]:
    source = Path(preview.source_path).expanduser()
    destination = Path(preview.destination_preview).expanduser()
    target_stem = destination.stem
    mappings: list[OrganizeSubtitleMapping] = []
    for subtitle in matching_subtitle_files(source):
        language_suffix = subtitle_language_suffix(subtitle)
        target_filename = f"{target_stem}{language_suffix}{subtitle.suffix}"
        target_path = destination.with_name(target_filename)
        status = "ready"
        message = "可整理"
        if target_path.exists() and subtitle.resolve() != target_path.resolve():
            status = "error"
            message = "目标字幕已存在，未覆盖已有文件"
        mappings.append(
            OrganizeSubtitleMapping(
                source_path=str(subtitle),
                original_filename=subtitle.name,
                target_filename=target_filename,
                target_path=str(target_path),
                language_suffix=language_suffix,
                extension=subtitle.suffix,
                status=status,
                message=message,
            )
        )
    return mappings


def destination_path_for_preview(preview: OrganizePreviewItem) -> Path:
    library_root = preview.library_root.strip()
    if not library_root:
        raise OrganizeApplyError("媒体库目录不能为空")

    root = Path(library_root).expanduser()
    if not root.is_absolute():
        raise OrganizeApplyError("执行整理需要填写绝对媒体库目录")

    filename = clean_path_component(Path(preview.filename).name)
    if preview.media_type == "movie":
        if preview.season_directory:
            raise OrganizeApplyError("电影预览不能包含季目录，请重新生成预览")
        return root / clean_path_component(preview.show_directory) / filename
    return root / clean_path_component(preview.show_directory) / clean_path_component(preview.season_directory) / filename


def _temporary_destination(destination: Path) -> Path:
    descriptor, path = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".kisetsu-part",
        dir=destination.parent,
    )
    os.close(descriptor)
    return Path(path)


def _commit_staged_file(staged: Path, destination: Path, expected_size: int) -> None:
    try:
        with _ORGANIZE_COMMIT_LOCK:
            if destination.exists():
                raise OrganizeApplyError(
                    "目标文件已存在，未覆盖已有文件",
                    status_code=409,
                    destination_path=str(destination),
                )
            os.replace(staged, destination)
            try:
                destination_size = destination.stat().st_size
            except OSError as exc:
                destination.unlink(missing_ok=True)
                raise OrganizeApplyError(
                    "目标文件写入后无法校验，已移除本次不完整文件",
                    destination_path=str(destination),
                ) from exc
            if destination_size != expected_size:
                destination.unlink(missing_ok=True)
                raise OrganizeApplyError(
                    "目标文件大小校验失败，已移除本次不完整文件",
                    destination_path=str(destination),
                )
    except Exception:
        staged.unlink(missing_ok=True)
        raise


def _stage_copy(source: Path, destination: Path) -> tuple[Path, int]:
    try:
        source_before = source.stat()
    except OSError as exc:
        raise OrganizeApplyError("源文件无法读取，未执行整理") from exc
    if source_before.st_size <= 0:
        raise OrganizeApplyError("源文件为空，未执行整理")

    staged = _temporary_destination(destination)
    try:
        shutil.copy2(str(source), str(staged))
        with staged.open("rb") as handle:
            os.fsync(handle.fileno())
        source_after = source.stat()
        staged_size = staged.stat().st_size
        if (
            source_after.st_size != source_before.st_size
            or source_after.st_mtime_ns != source_before.st_mtime_ns
        ):
            raise OrganizeApplyError("源文件在整理期间仍有变化，已取消本次整理")
        if staged_size != source_before.st_size:
            raise OrganizeApplyError("文件复制不完整，已移除本次临时文件")
        return staged, source_before.st_size
    except Exception:
        staged.unlink(missing_ok=True)
        raise


def _stage_hardlink(source: Path, destination: Path) -> tuple[Path, int]:
    try:
        source_size = source.stat().st_size
    except OSError as exc:
        raise OrganizeApplyError("源文件无法读取，未执行整理") from exc
    if source_size <= 0:
        raise OrganizeApplyError("源文件为空，未执行整理")

    staged = _temporary_destination(destination)
    staged.unlink()
    try:
        os.link(source, staged, follow_symlinks=False)
        if not source.samefile(staged) or staged.stat().st_size != source_size:
            raise OrganizeApplyError("硬链接校验失败，未执行整理")
        return staged, source_size
    except Exception:
        staged.unlink(missing_ok=True)
        raise


def _hardlink_fallback_allowed(exc: OSError) -> bool:
    return exc.errno in {
        errno.EXDEV,
        errno.EPERM,
        errno.EACCES,
        errno.ENOSYS,
        getattr(errno, "ENOTSUP", errno.EPERM),
        getattr(errno, "EOPNOTSUPP", errno.EPERM),
    }


def _preserve_source_file(source: Path, destination: Path) -> bool:
    try:
        staged, source_size = _stage_hardlink(source, destination)
        _commit_staged_file(staged, destination, source_size)
        return True
    except OSError as exc:
        if not _hardlink_fallback_allowed(exc):
            raise
    staged, source_size = _stage_copy(source, destination)
    _commit_staged_file(staged, destination, source_size)
    return False


def _move_source_file(source: Path, destination: Path) -> bool:
    try:
        staged, source_size = _stage_hardlink(source, destination)
    except OSError as exc:
        if not _hardlink_fallback_allowed(exc):
            raise
        staged, source_size = _stage_copy(source, destination)
    _commit_staged_file(staged, destination, source_size)
    try:
        source.unlink()
        return True
    except OSError:
        return False


def apply_preview(preview: OrganizePreviewItem, *, preserve_source: bool = False) -> OrganizeApplyResult:
    source = Path(preview.source_path).expanduser()
    if not source.is_absolute():
        raise OrganizeApplyError("执行整理需要填写绝对源文件路径")
    if not source.exists():
        raise OrganizeApplyError("源文件不存在，未执行整理", status_code=404)
    if not source.is_file():
        raise OrganizeApplyError("源路径不是文件，未执行整理")
    if not _valid_video_file(source):
        raise OrganizeApplyError("源文件不是受支持的视频文件，未执行整理")

    destination = destination_path_for_preview(preview)
    subtitle_sources: list[tuple[Path, Path]] = []
    for mapping in preview.subtitle_mappings:
        subtitle_source = Path(mapping.source_path).expanduser()
        subtitle_destination = Path(mapping.target_path).expanduser()
        if not subtitle_source.exists():
            raise OrganizeApplyError(
                f"外挂字幕不存在，未执行整理：{mapping.original_filename}",
                status_code=404,
                destination_path=str(destination),
            )
        if not subtitle_source.is_file():
            raise OrganizeApplyError(
                f"外挂字幕不是文件，未执行整理：{mapping.original_filename}",
                destination_path=str(destination),
            )
        if subtitle_destination.exists() and not _same_existing_file(subtitle_source, subtitle_destination):
            raise OrganizeApplyError(
                f"目标字幕已存在，未覆盖已有文件：{subtitle_destination.name}",
                status_code=409,
                destination_path=str(destination),
            )
        subtitle_sources.append((subtitle_source, subtitle_destination))

    if destination.exists():
        if _same_existing_file(source, destination):
            return OrganizeApplyResult(
                status="skipped",
                message="源文件已在目标位置，已跳过",
                source_path=str(source),
                destination_path=str(destination),
            )
        raise OrganizeApplyError(
            "目标文件已存在，未覆盖已有文件",
            status_code=409,
            destination_path=str(destination),
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    used_hardlink = False
    source_removed = False
    try:
        if preserve_source:
            used_hardlink = _preserve_source_file(source, destination)
        else:
            source_removed = _move_source_file(source, destination)
        for subtitle_source, subtitle_destination in subtitle_sources:
            if subtitle_source.resolve() == subtitle_destination.resolve():
                continue
            subtitle_destination.parent.mkdir(parents=True, exist_ok=True)
            if preserve_source:
                _preserve_source_file(subtitle_source, subtitle_destination)
            else:
                _move_source_file(subtitle_source, subtitle_destination)
    except OrganizeApplyError:
        raise
    except OSError as exc:
        raise OrganizeApplyError(
            f"文件整理失败：{exc.strerror or type(exc).__name__}",
            destination_path=str(destination),
        ) from exc
    subtitle_count = len(subtitle_sources)
    message = "整理完成，文件已复制到整理目标" if preserve_source else "整理完成，文件已移动到整理目标"
    if used_hardlink:
        message += "（同一文件系统使用硬链接）"
    elif not preserve_source and not source_removed:
        message += "（目标文件已完整写入，但源文件删除失败，已保留源文件）"
    if subtitle_count:
        message += f"，外挂字幕 {subtitle_count} 个已同步整理"
    return OrganizeApplyResult(
        status="moved",
        message=message,
        source_path=str(source),
        destination_path=str(destination),
    )
