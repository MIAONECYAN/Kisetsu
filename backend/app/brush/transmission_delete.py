from __future__ import annotations

import errno
import hashlib
import os
import socket
import stat
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from urllib.parse import urlparse

from app.core.downloader import DownloaderError
from app.db import Store


PLAN_CONFIG_KEY = "brush_transmission_delete_plans"
PLAN_VERSION = 1
BACKEND_LOCAL_MACOS = "backend_local_macos"
RPC_NATIVE = "rpc_native"


class TransmissionDeleteError(DownloaderError):
    pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sockaddr_is_local(family: int, sockaddr: tuple[Any, ...]) -> bool:
    bind_address: tuple[Any, ...]
    if family == socket.AF_INET6:
        bind_address = (str(sockaddr[0]), 0, int(sockaddr[2]), int(sockaddr[3]))
    else:
        bind_address = (str(sockaddr[0]), 0)
    probe = socket.socket(family, socket.SOCK_STREAM)
    try:
        probe.bind(bind_address)
        return True
    except OSError:
        return False
    finally:
        probe.close()


def transmission_rpc_is_local(
    base_url: str,
    *,
    resolver: Callable[..., list[tuple[Any, ...]]] = socket.getaddrinfo,
    address_checker: Callable[[int, tuple[Any, ...]], bool] = _sockaddr_is_local,
) -> bool:
    parsed = urlparse((base_url or "").strip())
    host = parsed.hostname
    if not host:
        return False
    try:
        addresses = resolver(host, parsed.port or 9091, type=socket.SOCK_STREAM)
    except OSError:
        return False
    resolved: list[tuple[int, tuple[Any, ...]]] = []
    seen: set[tuple[int, str, int]] = set()
    for family, _socktype, _proto, _canonname, sockaddr in addresses:
        if family not in {socket.AF_INET, socket.AF_INET6}:
            continue
        key = (family, str(sockaddr[0]), int(sockaddr[3]) if family == socket.AF_INET6 else 0)
        if key in seen:
            continue
        seen.add(key)
        resolved.append((family, sockaddr))
    return bool(resolved) and all(address_checker(family, sockaddr) for family, sockaddr in resolved)


def transmission_delete_mode(
    base_url: str,
    *,
    platform_name: str | None = None,
    local_check: Callable[[str], bool] = transmission_rpc_is_local,
) -> str:
    if not local_check(base_url):
        raise TransmissionDeleteError(
            "Transmission 不在 Kisetsu 后端本机，无法安全确认下载文件路径，已阻止永久删除。"
        )
    return BACKEND_LOCAL_MACOS if (platform_name or sys.platform) == "darwin" else RPC_NATIVE


class DeletePlanStore:
    def __init__(self, store: Store):
        self.store = store

    def _payload(self) -> dict[str, Any]:
        payload = self.store.get_config(PLAN_CONFIG_KEY) or {}
        items = payload.get("items")
        return {"version": PLAN_VERSION, "items": dict(items) if isinstance(items, dict) else {}}

    def get(self, task_id: int) -> dict[str, Any] | None:
        value = self._payload()["items"].get(str(task_id))
        return dict(value) if isinstance(value, dict) else None

    def put(self, plan: dict[str, Any]) -> dict[str, Any]:
        payload = self._payload()
        items = payload["items"]
        normalized = dict(plan)
        normalized["updated_at"] = _now_iso()
        items[str(int(normalized["task_id"]))] = normalized
        completed = [
            key for key, value in items.items()
            if isinstance(value, dict) and value.get("stage") == "task_removed"
        ]
        for key in completed[:-50]:
            items.pop(key, None)
        self.store.set_config(PLAN_CONFIG_KEY, payload)
        return normalized

    def update(self, task_id: int, *, stage: str, error_code: str | None = None) -> dict[str, Any] | None:
        plan = self.get(task_id)
        if plan is None:
            return None
        plan["stage"] = stage
        plan["error_code"] = error_code
        return self.put(plan)

    def pending(self) -> list[dict[str, Any]]:
        return [
            dict(value) for value in self._payload()["items"].values()
            if isinstance(value, dict) and value.get("stage") in {"planned", "files_deleted"}
        ]


def _relative_file_name(value: object) -> PurePosixPath:
    raw = str(value or "")
    if not raw or "\x00" in raw:
        raise TransmissionDeleteError("Transmission 文件清单包含无效路径，已阻止永久删除。")
    relative = PurePosixPath(raw.replace("\\", "/"))
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise TransmissionDeleteError("Transmission 文件路径越界，已阻止永久删除。")
    return relative


def _lexical_path(root: Path, relative: PurePosixPath) -> Path:
    return root.joinpath(*relative.parts)


def _root_identity(root: Path) -> tuple[Path, os.stat_result]:
    try:
        if root.is_symlink():
            raise TransmissionDeleteError("刷流根目录是符号链接，已阻止永久删除。")
        resolved = root.resolve(strict=True)
        details = os.stat(resolved, follow_symlinks=False)
    except FileNotFoundError as exc:
        raise TransmissionDeleteError("刷流根目录当前不可访问，已阻止永久删除。") from exc
    if not stat.S_ISDIR(details.st_mode):
        raise TransmissionDeleteError("刷流根目录不是有效目录，已阻止永久删除。")
    if not os.access(resolved, os.R_OK | os.W_OK | os.X_OK):
        raise TransmissionDeleteError("Kisetsu 后端没有刷流目录的删除权限，已阻止永久删除。")
    return resolved, details


def _lstat_beneath(root: Path, relative: PurePosixPath) -> os.stat_result | None:
    current = root
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            details = os.lstat(current)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(details.st_mode):
            raise TransmissionDeleteError("删除路径包含符号链接，已阻止永久删除。")
        if index < len(relative.parts) - 1 and not stat.S_ISDIR(details.st_mode):
            raise TransmissionDeleteError("删除路径的父级不是目录，已阻止永久删除。")
    return details


def _task_file_keys(item: dict[str, Any]) -> set[tuple[str, str]]:
    root = str(item.get("save_path") or "").strip()
    keys: set[tuple[str, str]] = set()
    for file in item.get("files") or []:
        if not isinstance(file, dict):
            continue
        try:
            relative = _relative_file_name(file.get("name"))
        except TransmissionDeleteError:
            continue
        keys.add((os.path.normpath(root), relative.as_posix()))
    return keys


def build_macos_delete_plan(
    *,
    task_id: int,
    task_key: str,
    remote_id: str,
    item: dict[str, Any],
    all_items: list[dict[str, Any]],
    brush_root: str,
    session_info: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root, root_stat = _root_identity(Path(brush_root).expanduser())
    item_root_raw = str(item.get("save_path") or "").strip()
    try:
        item_root = Path(item_root_raw).expanduser().resolve(strict=True)
    except (FileNotFoundError, OSError) as exc:
        raise TransmissionDeleteError("Transmission 下载目录当前不可访问，已阻止永久删除。") from exc
    if item_root != root:
        raise TransmissionDeleteError("Transmission 下载目录与刷流专用目录不一致，已阻止永久删除。")

    files = item.get("files")
    if not isinstance(files, list) or not files:
        raise TransmissionDeleteError("Transmission 没有返回完整文件清单，已阻止永久删除。")
    incomplete = float(item.get("progress") or 0) < 0.999999 or any(
        isinstance(file, dict) and float(file.get("progress") or 0) < 0.999999 for file in files
    )
    if incomplete:
        session = session_info or {}
        uses_incomplete_dir = bool(session.get("incomplete-dir-enabled", session.get("incomplete_dir_enabled")))
        renames_partial = bool(session.get("rename-partial-files", session.get("rename_partial_files", True)))
        detail = "incomplete-dir 或 .part 路径" if uses_incomplete_dir or renames_partial else "未完成文件路径"
        raise TransmissionDeleteError(f"未完成任务的{detail}无法安全确认，已阻止永久删除。")

    own_keys = _task_file_keys(item)
    other_keys: set[tuple[str, str]] = set()
    for other in all_items:
        if other is item:
            continue
        same_remote = str(other.get("remote_id") or "") == remote_id
        same_hash = bool(item.get("hash") and str(other.get("hash") or "").casefold() == str(item.get("hash")).casefold())
        if same_remote or same_hash:
            continue
        other_keys.update(_task_file_keys(other))
    if own_keys.intersection(other_keys):
        raise TransmissionDeleteError("下载文件仍被其他 Transmission 任务引用，已阻止永久删除。")

    planned_files: list[dict[str, Any]] = []
    seen: set[str] = set()
    for file in files:
        if not isinstance(file, dict):
            raise TransmissionDeleteError("Transmission 文件清单格式无效，已阻止永久删除。")
        relative = _relative_file_name(file.get("name"))
        relative_text = relative.as_posix()
        if relative_text in seen:
            raise TransmissionDeleteError("Transmission 文件清单包含重复路径，已阻止永久删除。")
        seen.add(relative_text)
        target = _lexical_path(root, relative)
        if target == root:
            raise TransmissionDeleteError("删除目标指向刷流根目录，已阻止永久删除。")
        details = _lstat_beneath(root, relative)
        expected_size = int(file.get("size") or 0)
        if details is None:
            planned_files.append({"relative_path": relative_text, "exists": False, "size": expected_size})
            continue
        if not stat.S_ISREG(details.st_mode):
            raise TransmissionDeleteError("删除清单包含非普通文件，已阻止永久删除。")
        if details.st_nlink > 1:
            raise TransmissionDeleteError("下载文件存在硬链接，已阻止永久删除。")
        if details.st_size != expected_size:
            raise TransmissionDeleteError("下载文件大小与 Transmission 清单不一致，已阻止永久删除。")
        planned_files.append({
            "relative_path": relative_text,
            "exists": True,
            "size": expected_size,
            "device": int(details.st_dev),
            "inode": int(details.st_ino),
            "mtime_ns": int(details.st_mtime_ns),
        })

    created_at = _now_iso()
    return {
        "version": PLAN_VERSION,
        "operation_id": str(uuid.uuid4()),
        "task_id": task_id,
        "task_key": task_key,
        "remote_id": remote_id,
        "stage": "planned",
        "error_code": None,
        "root_fingerprint": hashlib.sha256(str(root).encode("utf-8")).hexdigest(),
        "root_device": int(root_stat.st_dev),
        "root_inode": int(root_stat.st_ino),
        "files": planned_files,
        "created_at": created_at,
        "updated_at": created_at,
    }


def ensure_plan_paths_unshared(
    plan: dict[str, Any],
    *,
    brush_root: str,
    protected_paths: set[str],
) -> None:
    if not protected_paths:
        return
    root, _root_stat = _root_identity(Path(brush_root).expanduser())
    normalized = {
        os.path.normcase(os.path.normpath(str(Path(path).expanduser().resolve(strict=False))))
        for path in protected_paths
    }
    for expected in plan.get("files") or []:
        if not isinstance(expected, dict):
            raise TransmissionDeleteError("删除计划文件清单格式无效，已停止永久删除。")
        relative = _relative_file_name(expected.get("relative_path"))
        target = os.path.normcase(os.path.normpath(str(_lexical_path(root, relative))))
        if target in normalized:
            raise TransmissionDeleteError("下载文件仍被其他下载器任务引用，已阻止永久删除。")


def _open_parent_fd(root_fd: int, parent_parts: tuple[str, ...]) -> int:
    current_fd = os.dup(root_fd)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        for part in parent_parts:
            next_fd = os.open(part, flags, dir_fd=current_fd)
            os.close(current_fd)
            current_fd = next_fd
        return current_fd
    except Exception:
        os.close(current_fd)
        raise


def _verify_file_identity(details: os.stat_result, expected: dict[str, Any]) -> None:
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISREG(details.st_mode):
        raise TransmissionDeleteError("文件类型在删除前发生变化，已停止永久删除。")
    if details.st_nlink > 1:
        raise TransmissionDeleteError("文件在删除前出现硬链接，已停止永久删除。")
    identity = (int(details.st_dev), int(details.st_ino), int(details.st_size), int(details.st_mtime_ns))
    planned = (
        int(expected.get("device") or -1),
        int(expected.get("inode") or -1),
        int(expected.get("size") or 0),
        int(expected.get("mtime_ns") or -1),
    )
    if identity != planned:
        raise TransmissionDeleteError("文件身份在删除前发生变化，已停止永久删除。")


def delete_macos_plan_files(plan: dict[str, Any], *, brush_root: str) -> None:
    root, root_stat = _root_identity(Path(brush_root).expanduser())
    fingerprint = hashlib.sha256(str(root).encode("utf-8")).hexdigest()
    if (
        fingerprint != plan.get("root_fingerprint")
        or int(root_stat.st_dev) != int(plan.get("root_device") or -1)
        or int(root_stat.st_ino) != int(plan.get("root_inode") or -1)
    ):
        raise TransmissionDeleteError("刷流目录或挂载卷在删除前发生变化，已停止永久删除。")
    if os.unlink not in os.supports_dir_fd or os.stat not in os.supports_dir_fd:
        raise TransmissionDeleteError("当前 Python 环境不支持安全的目录相对删除，已阻止永久删除。")

    root_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(root, root_flags)
    directories: set[tuple[str, ...]] = set()
    try:
        for expected in plan.get("files") or []:
            relative = _relative_file_name(expected.get("relative_path"))
            for depth in range(1, len(relative.parts)):
                directories.add(tuple(relative.parts[:depth]))
            parent_fd = _open_parent_fd(root_fd, tuple(relative.parts[:-1]))
            try:
                try:
                    details = os.stat(relative.name, dir_fd=parent_fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if not bool(expected.get("exists")):
                    raise TransmissionDeleteError("原本不存在的路径出现了新文件，已停止永久删除。")
                _verify_file_identity(details, expected)
                os.unlink(relative.name, dir_fd=parent_fd)
            finally:
                os.close(parent_fd)

        for parts in sorted(directories, key=len, reverse=True):
            parent_fd = _open_parent_fd(root_fd, parts[:-1])
            try:
                try:
                    os.rmdir(parts[-1], dir_fd=parent_fd)
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    if exc.errno == errno.ENOTEMPTY:
                        continue
                    raise
            finally:
                os.close(parent_fd)
    finally:
        os.close(root_fd)
