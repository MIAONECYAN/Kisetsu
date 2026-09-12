from __future__ import annotations

import errno
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


INVALID_PATH_CHARS_RE = re.compile(r"[\\/:*?\"<>|\x00-\x1f]+")
FOLDER_KEY_RE = re.compile(r"[^0-9a-z\u4e00-\u9fff]+", re.IGNORECASE)


@dataclass(frozen=True)
class ManagedDirectoryTarget:
    root: Path
    path: Path


@dataclass(frozen=True)
class EmptyDirectoryCleanupResult:
    attempted: bool
    status: str
    path: str
    message: str
    deleted_count: int = 0


class _CleanupRefused(RuntimeError):
    pass


def _absolute_path(value: str | Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(str(value))))


def _strict_relative_path(child: Path, parent: Path) -> Path | None:
    try:
        relative = child.relative_to(parent)
    except ValueError:
        return None
    return relative if relative.parts else None


def paths_overlap(first: str | Path, second: str | Path) -> bool:
    first_path = _absolute_path(first)
    second_path = _absolute_path(second)
    return (
        first_path == second_path
        or first_path in second_path.parents
        or second_path in first_path.parents
    )


def safe_subscription_folder_name(value: str | None, fallback: str = "Anime") -> str:
    cleaned = INVALID_PATH_CHARS_RE.sub(" ", value or "").strip(" .")
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned[:120] or fallback


def _folder_key(value: str | None) -> str:
    return FOLDER_KEY_RE.sub("", value or "").casefold()


def subscription_download_directory(base_path: str | Path | None, title: str | None) -> Path | None:
    if not base_path:
        return None
    base = _absolute_path(base_path)
    folder = safe_subscription_folder_name(title)
    if _folder_key(base.name) == _folder_key(folder):
        return base
    return base / folder


def subscription_directory_targets(
    *,
    name: str,
    configured_roots: Iterable[str | Path],
    save_path: str | Path | None = None,
    history_paths: Iterable[str | Path] = (),
) -> list[ManagedDirectoryTarget]:
    roots = list(dict.fromkeys(_absolute_path(root) for root in configured_roots if str(root).strip()))
    explicit_base = _absolute_path(save_path) if save_path and str(save_path).strip() else None
    targets: dict[Path, ManagedDirectoryTarget] = {}

    def add(candidate: Path, possible_roots: Iterable[Path]) -> None:
        valid_roots = [root for root in possible_roots if _strict_relative_path(candidate, root) is not None]
        if not valid_roots:
            return
        root = max(valid_roots, key=lambda item: len(item.parts))
        current = targets.get(candidate)
        if current is None or len(root.parts) > len(current.root.parts):
            targets[candidate] = ManagedDirectoryTarget(root=root, path=candidate)

    if explicit_base is not None:
        candidate = subscription_download_directory(explicit_base, name)
        if candidate is not None:
            if candidate != explicit_base:
                add(candidate, [explicit_base, *roots])
            else:
                add(candidate, roots)
    else:
        for root in roots:
            candidate = subscription_download_directory(root, name)
            if candidate is not None:
                add(candidate, [root])

    history_roots = [*roots]
    if explicit_base is not None:
        history_roots.append(explicit_base)
    for history_path in history_paths:
        if not history_path or not str(history_path).strip():
            continue
        add(_absolute_path(history_path), history_roots)

    return sorted(targets.values(), key=lambda item: len(item.path.parts), reverse=True)


def _collect_empty_directories(candidate: Path, root: Path) -> list[Path]:
    directories: list[Path] = []
    pending = [candidate]
    while pending:
        current = pending.pop()
        try:
            details = current.lstat()
        except FileNotFoundError as exc:
            raise _CleanupRefused("目录在清理前已不存在。") from exc
        except OSError as exc:
            raise _CleanupRefused(f"目录当前不可访问，未清理：{exc}") from exc
        if stat.S_ISLNK(details.st_mode):
            raise _CleanupRefused("目录路径包含符号链接，未清理。")
        if not stat.S_ISDIR(details.st_mode):
            raise _CleanupRefused("清理目标不是文件夹，未清理。")
        if current != root and os.path.ismount(current):
            raise _CleanupRefused("清理目标跨越挂载点，未清理。")
        directories.append(current)
        try:
            entries = list(os.scandir(current))
        except OSError as exc:
            raise _CleanupRefused(f"无法读取目录内容，未清理：{exc}") from exc
        for entry in entries:
            try:
                entry_details = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise _CleanupRefused(f"无法确认目录内容，未清理：{exc}") from exc
            if stat.S_ISLNK(entry_details.st_mode):
                raise _CleanupRefused("目录内包含符号链接，未清理。")
            if stat.S_ISDIR(entry_details.st_mode):
                pending.append(Path(entry.path))
                continue
            raise _CleanupRefused("目录非空，未清理。")
    return directories


def prune_empty_managed_directory(
    candidate_path: str | Path,
    *,
    managed_root: str | Path,
) -> EmptyDirectoryCleanupResult:
    candidate = _absolute_path(candidate_path)
    root = _absolute_path(managed_root)
    result_path = str(candidate)
    if _strict_relative_path(candidate, root) is None:
        return EmptyDirectoryCleanupResult(
            attempted=False,
            status="skipped",
            path=result_path,
            message="清理目标不是受管根目录的子目录，未清理。",
        )
    try:
        root_details = root.lstat()
    except FileNotFoundError:
        return EmptyDirectoryCleanupResult(
            attempted=False,
            status="skipped",
            path=result_path,
            message="受管根目录不存在，未清理。",
        )
    except OSError as exc:
        return EmptyDirectoryCleanupResult(
            attempted=False,
            status="skipped",
            path=result_path,
            message=f"受管根目录当前不可访问，未清理：{exc}",
        )
    if stat.S_ISLNK(root_details.st_mode) or not stat.S_ISDIR(root_details.st_mode):
        return EmptyDirectoryCleanupResult(
            attempted=False,
            status="skipped",
            path=result_path,
            message="受管根目录不是安全的实体文件夹，未清理。",
        )
    if not candidate.exists():
        return EmptyDirectoryCleanupResult(
            attempted=True,
            status="absent",
            path=result_path,
            message="目录已不存在，无需清理。",
        )

    current = root
    relative = candidate.relative_to(root)
    for part in relative.parts:
        current = current / part
        try:
            details = current.lstat()
        except FileNotFoundError:
            return EmptyDirectoryCleanupResult(
                attempted=True,
                status="absent",
                path=result_path,
                message="目录已不存在，无需清理。",
            )
        except OSError as exc:
            return EmptyDirectoryCleanupResult(
                attempted=True,
                status="skipped",
                path=result_path,
                message=f"无法确认目录路径，未清理：{exc}",
            )
        if stat.S_ISLNK(details.st_mode):
            return EmptyDirectoryCleanupResult(
                attempted=True,
                status="skipped",
                path=result_path,
                message="目录路径包含符号链接，未清理。",
            )
        if not stat.S_ISDIR(details.st_mode):
            return EmptyDirectoryCleanupResult(
                attempted=True,
                status="skipped",
                path=result_path,
                message="清理目标不是文件夹，未清理。",
            )

    try:
        directories = _collect_empty_directories(candidate, root)
    except _CleanupRefused as exc:
        return EmptyDirectoryCleanupResult(
            attempted=True,
            status="skipped",
            path=result_path,
            message=str(exc),
        )

    deleted_count = 0
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        try:
            directory.rmdir()
            deleted_count += 1
        except FileNotFoundError:
            continue
        except OSError as exc:
            if exc.errno in {errno.ENOTEMPTY, errno.EEXIST}:
                return EmptyDirectoryCleanupResult(
                    attempted=True,
                    status="skipped",
                    path=result_path,
                    message="目录在清理时出现了新内容，已停止清理。",
                    deleted_count=deleted_count,
                )
            if exc.errno in {errno.ENOTDIR, errno.ELOOP, errno.EBUSY}:
                return EmptyDirectoryCleanupResult(
                    attempted=True,
                    status="skipped",
                    path=result_path,
                    message="目录类型或挂载状态在清理时发生变化，已停止清理。",
                    deleted_count=deleted_count,
                )
            return EmptyDirectoryCleanupResult(
                attempted=True,
                status="error",
                path=result_path,
                message=f"清理空目录失败：{exc}",
                deleted_count=deleted_count,
            )
    return EmptyDirectoryCleanupResult(
        attempted=True,
        status="deleted",
        path=result_path,
        message="空目录已清理。",
        deleted_count=deleted_count,
    )


def _safe_relative_file_name(value: Any) -> PurePosixPath | None:
    raw = str(value or "").replace("\\", "/")
    relative = PurePosixPath(raw)
    if (
        not raw
        or "\x00" in raw
        or relative.is_absolute()
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        return None
    return relative


def brush_task_directory(item: dict[str, Any], *, brush_root: str | Path) -> ManagedDirectoryTarget | None:
    root = _absolute_path(brush_root)
    files = item.get("files") if isinstance(item.get("files"), list) else []
    relative_files = [
        relative
        for file in files
        if isinstance(file, dict)
        for relative in [_safe_relative_file_name(file.get("name"))]
        if relative is not None
    ]
    if files and len(relative_files) != len(files):
        return None
    if relative_files:
        top_level = {relative.parts[0] for relative in relative_files if len(relative.parts) > 1}
        if len(top_level) == 1 and all(len(relative.parts) > 1 for relative in relative_files):
            return ManagedDirectoryTarget(root=root, path=root / next(iter(top_level)))

    raw_content_path = str(item.get("content_path") or item.get("contentPath") or "").strip()
    if not raw_content_path:
        return None
    content_path = _absolute_path(raw_content_path)
    relative_content = _strict_relative_path(content_path, root)
    if relative_content is None:
        return None
    if content_path.exists() and not content_path.is_dir():
        return None
    return ManagedDirectoryTarget(root=root, path=root / relative_content.parts[0])
