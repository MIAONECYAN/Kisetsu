from __future__ import annotations

import asyncio
import errno
import hashlib
import os
import shutil
import stat
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable

from app.brush.service import SETTINGS_KEY as BRUSH_SETTINGS_KEY
from app.db import Store
from app.db.secret_migration import private_migration_backup_dir
from app.file_manager.models import (
    FileManagerDeletePreview,
    FileManagerDeleteRequest,
    FileManagerDirectoryResponse,
    FileManagerEditSession,
    FileManagerItem,
    FileManagerOperationRequest,
    FileManagerOperationStatus,
    FileManagerReference,
    FileManagerRoot,
    FileManagerRootResponse,
    FileManagerWriteResponse,
    FileRootKind,
)
from app.settings import PROJECT_ROOT, data_directory, database_path, secrets_database_path


EDIT_SESSION_TTL = timedelta(minutes=10)
DELETE_PREVIEW_TTL = timedelta(minutes=2)
MAX_DIRECTORY_PAGE_SIZE = 500
COPY_CHUNK_SIZE = 4 * 1024 * 1024


class FileManagerError(RuntimeError):
    def __init__(self, message: str, *, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class FileOperationCanceled(RuntimeError):
    pass


class FileDeleteFailure(RuntimeError):
    def __init__(self, message: str, *, mutated: bool):
        super().__init__(message)
        self.message = message
        self.mutated = mutated


@dataclass(frozen=True)
class ManagedRoot:
    id: str
    name: str
    path: Path
    kind: FileManagerRootKind
    sources: tuple[str, ...]


@dataclass
class EditSessionState:
    token: str
    client_host: str
    expires_at: datetime


@dataclass
class OperationState:
    payload: FileManagerOperationStatus
    cancel_event: threading.Event = field(default_factory=threading.Event)


@dataclass(frozen=True)
class DeleteEntrySnapshot:
    path: Path
    identity: tuple[int, int, int, int, int, int]
    is_directory: bool
    size: int


@dataclass(frozen=True)
class DeletePlan:
    root_id: str
    relative_path: str
    source: Path
    entries: tuple[DeleteEntrySnapshot, ...]
    digest: str
    files_total: int
    directories_total: int
    bytes_total: int


@dataclass(frozen=True)
class DeletePreviewState:
    token: str
    edit_token: str
    client_host: str
    expires_at: datetime
    plans: tuple[DeletePlan, ...]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_iso(value: datetime | None = None) -> str:
    return (value or utc_now()).isoformat()


def _contains_or_equals(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def _paths_intersect(left: Path, right: Path) -> bool:
    return _contains_or_equals(left, right) or _contains_or_equals(right, left)


class FileManagerService:
    def __init__(self, store_factory: Callable[[], Store]):
        self.store_factory = store_factory
        self._sessions: dict[str, EditSessionState] = {}
        self._delete_previews: dict[str, DeletePreviewState] = {}
        self._operations: dict[str, OperationState] = {}
        self._tasks: set[asyncio.Task] = set()
        self._state_lock = threading.RLock()
        self._filesystem_lock = threading.RLock()
        self._closing = False

    async def shutdown(self) -> None:
        self._closing = True
        with self._state_lock:
            for operation in self._operations.values():
                if operation.payload.status in {"queued", "running"}:
                    operation.cancel_event.set()
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        with self._state_lock:
            self._sessions.clear()
            self._delete_previews.clear()

    def roots_response(self) -> FileManagerRootResponse:
        roots = [self._public_root(root) for root in self._managed_roots()]
        if roots:
            message = f"可查看 {len(roots)} 个 Kisetsu 管理目录；默认处于只读模式。"
        else:
            message = "尚未配置可管理的下载、刷流或整理目录。"
        return FileManagerRootResponse(roots=roots, message=message)

    def list_directory(
        self,
        root_id: str,
        relative_path: str = "",
        *,
        offset: int = 0,
        limit: int = 250,
        show_hidden: bool = False,
    ) -> FileManagerDirectoryResponse:
        root = self._root_or_error(root_id)
        directory = self._resolve_existing(root, relative_path, require_directory=True)
        limit = min(max(limit, 1), MAX_DIRECTORY_PAGE_SIZE)
        offset = max(offset, 0)
        items: list[FileManagerItem] = []
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if not show_hidden and entry.name.startswith("."):
                        continue
                    lexical = directory / entry.name
                    if self._path_is_protected(lexical):
                        continue
                    try:
                        details = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    items.append(self._item(root, lexical, details))
        except PermissionError as exc:
            raise FileManagerError("没有权限读取这个目录。", status_code=403) from exc
        except OSError as exc:
            raise FileManagerError(f"读取目录失败：{self._safe_os_error(exc)}") from exc
        items.sort(key=lambda item: (not item.is_directory, item.name.casefold(), item.name))
        total = len(items)
        page = items[offset : offset + limit]
        return FileManagerDirectoryResponse(
            root_id=root.id,
            path=self._relative_string(root, directory),
            items=page,
            offset=offset,
            limit=limit,
            total=total,
            has_more=offset + len(page) < total,
        )

    def create_edit_session(self, *, client_host: str, confirm: bool) -> FileManagerEditSession:
        if not confirm:
            raise FileManagerError("必须明确确认后才能关闭只读模式。", status_code=422)
        token = uuid.uuid4().hex + uuid.uuid4().hex
        expires_at = utc_now() + EDIT_SESSION_TTL
        with self._state_lock:
            self._purge_expired_sessions_locked()
            self._sessions[token] = EditSessionState(token=token, client_host=client_host, expires_at=expires_at)
        return FileManagerEditSession(
            token=token,
            expires_at=utc_iso(expires_at),
            message="编辑模式已开启；十分钟无操作后会自动恢复只读。",
        )

    def lock_edit_session(self, *, token: str, client_host: str) -> FileManagerWriteResponse:
        with self._state_lock:
            session = self._sessions.get(token)
            if session and session.client_host == client_host:
                self._sessions.pop(token, None)
                stale_previews = [
                    preview_token
                    for preview_token, preview in self._delete_previews.items()
                    if preview.edit_token == token
                ]
                for preview_token in stale_previews:
                    self._delete_previews.pop(preview_token, None)
        return FileManagerWriteResponse(message="已恢复只读模式。")

    def rename(
        self,
        *,
        edit_token: str,
        client_host: str,
        root_id: str,
        relative_path: str,
        new_name: str,
    ) -> FileManagerWriteResponse:
        self._require_edit_session(edit_token, client_host)
        root = self._root_or_error(root_id, require_writable=True)
        source = self._resolve_existing(root, relative_path)
        self._ensure_mutable_source(source)
        name = self._validate_name(new_name)
        destination = source.parent / name
        self._ensure_new_destination(root, destination)
        with self._filesystem_lock:
            try:
                source.rename(destination)
            except OSError as exc:
                raise FileManagerError(f"重命名失败：{self._safe_os_error(exc)}") from exc
        details = destination.lstat()
        return FileManagerWriteResponse(message=f"已重命名为“{name}”。", item=self._item(root, destination, details))

    def create_folder(
        self,
        *,
        edit_token: str,
        client_host: str,
        root_id: str,
        parent_path: str,
        name: str,
    ) -> FileManagerWriteResponse:
        self._require_edit_session(edit_token, client_host)
        root = self._root_or_error(root_id, require_writable=True)
        parent = self._resolve_existing(root, parent_path, require_directory=True)
        destination = parent / self._validate_name(name)
        self._ensure_new_destination(root, destination)
        with self._filesystem_lock:
            try:
                destination.mkdir()
            except OSError as exc:
                raise FileManagerError(f"新建文件夹失败：{self._safe_os_error(exc)}") from exc
        return FileManagerWriteResponse(
            message=f"已创建文件夹“{destination.name}”。",
            item=self._item(root, destination, destination.lstat()),
        )

    def preview_delete(
        self,
        *,
        edit_token: str,
        client_host: str,
        references: list[FileManagerReference],
    ) -> FileManagerDeletePreview:
        self._require_edit_session(edit_token, client_host)
        if not references or len(references) > 100:
            raise FileManagerError("每次必须选择 1 至 100 个项目。", status_code=422)
        with self._filesystem_lock:
            plans = tuple(self._delete_plans(references))
        token = uuid.uuid4().hex + uuid.uuid4().hex
        expires_at = utc_now() + DELETE_PREVIEW_TTL
        preview = DeletePreviewState(
            token=token,
            edit_token=edit_token,
            client_host=client_host,
            expires_at=expires_at,
            plans=plans,
        )
        with self._state_lock:
            self._purge_expired_delete_previews_locked()
            self._delete_previews[token] = preview
        names = [plan.source.name for plan in plans]
        files_total = sum(plan.files_total for plan in plans)
        directories_total = sum(plan.directories_total for plan in plans)
        bytes_total = sum(plan.bytes_total for plan in plans)
        return FileManagerDeletePreview(
            token=token,
            expires_at=utc_iso(expires_at),
            items_total=len(plans),
            files_total=files_total,
            directories_total=directories_total,
            bytes_total=bytes_total,
            item_names=names[:3],
            names_truncated=len(names) > 3,
            message="删除预检已完成；确认后会再次核对内容。",
        )

    async def start_delete(
        self,
        request: FileManagerDeleteRequest,
        *,
        client_host: str,
    ) -> FileManagerOperationStatus:
        self._require_edit_session(request.edit_token, client_host)
        if self._closing:
            raise FileManagerError("后端正在停止，暂时不能开始文件操作。", status_code=503)
        now = utc_now()
        with self._state_lock:
            self._purge_expired_delete_previews_locked(now)
            preview = self._delete_previews.pop(request.preview_token, None)
            if preview is None:
                raise FileManagerError("删除确认已过期，请重新选择并核对。", status_code=409)
            if preview.client_host != client_host or preview.edit_token != request.edit_token:
                raise FileManagerError("删除确认与当前编辑会话不匹配。", status_code=403)
            operation_id = uuid.uuid4().hex
            state = OperationState(
                payload=FileManagerOperationStatus(
                    id=operation_id,
                    kind="delete",
                    items_total=len(preview.plans),
                    bytes_total=sum(plan.bytes_total for plan in preview.plans),
                    started_at=utc_iso(),
                    message="正在等待永久删除…",
                )
            )
            self._purge_operations_locked()
            self._operations[operation_id] = state
        task = asyncio.create_task(asyncio.to_thread(self._run_delete_operation, operation_id, preview))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return state.payload.model_copy(deep=True)

    async def start_operation(
        self,
        request: FileManagerOperationRequest,
        *,
        client_host: str,
    ) -> FileManagerOperationStatus:
        self._require_edit_session(request.edit_token, client_host)
        if self._closing:
            raise FileManagerError("后端正在停止，暂时不能开始文件操作。", status_code=503)
        operation_id = uuid.uuid4().hex
        state = OperationState(
            payload=FileManagerOperationStatus(
                id=operation_id,
                kind=request.kind,
                items_total=len(request.sources),
                started_at=utc_iso(),
                message="正在等待处理…",
            )
        )
        with self._state_lock:
            self._purge_operations_locked()
            self._operations[operation_id] = state
        task = asyncio.create_task(asyncio.to_thread(self._run_operation, operation_id, request))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return state.payload.model_copy(deep=True)

    def operation(self, operation_id: str) -> FileManagerOperationStatus:
        with self._state_lock:
            state = self._operations.get(operation_id)
            if state is None:
                raise FileManagerError("文件操作不存在或后端已经重启。", status_code=404)
            return state.payload.model_copy(deep=True)

    def recent_operations(self, limit: int = 20) -> list[FileManagerOperationStatus]:
        with self._state_lock:
            values = sorted(
                (state.payload for state in self._operations.values()),
                key=lambda item: item.started_at,
                reverse=True,
            )
            return [item.model_copy(deep=True) for item in values[: max(1, min(limit, 50))]]

    def cancel_operation(self, operation_id: str, *, edit_token: str, client_host: str) -> FileManagerOperationStatus:
        self._require_edit_session(edit_token, client_host)
        with self._state_lock:
            state = self._operations.get(operation_id)
            if state is None:
                raise FileManagerError("文件操作不存在或后端已经重启。", status_code=404)
            if state.payload.kind == "delete":
                raise FileManagerError("永久删除开始后不能取消。", status_code=409)
            if state.payload.status in {"queued", "running"}:
                state.cancel_event.set()
                state.payload.message = "正在取消…"
            return state.payload.model_copy(deep=True)

    def _run_delete_operation(self, operation_id: str, preview: DeletePreviewState) -> None:
        self._update_operation(operation_id, status="running", message="正在再次核对删除内容…")
        completed = 0
        partially_deleted = False
        errors: list[str] = []
        try:
            with self._filesystem_lock:
                references = [
                    FileManagerReference(root_id=plan.root_id, path=plan.relative_path)
                    for plan in preview.plans
                ]
                current_plans = self._delete_plans(references)
                expected = {(plan.root_id, plan.relative_path): plan.digest for plan in preview.plans}
                current = {(plan.root_id, plan.relative_path): plan.digest for plan in current_plans}
                if current != expected:
                    raise FileManagerError("所选内容在确认后发生了变化，未删除任何项目。", status_code=409)
                self._update_operation(operation_id, message="正在永久删除…")
                for plan in current_plans:
                    self._update_operation(operation_id, current_item=plan.source.name)
                    try:
                        self._delete_plan(plan, operation_id)
                        completed += 1
                        self._update_operation(operation_id, items_completed=completed)
                    except FileDeleteFailure as exc:
                        partially_deleted = partially_deleted or exc.mutated
                        errors.append(f"{plan.source.name}：{exc.message}")
                    except Exception as exc:
                        errors.append(f"{plan.source.name}：{self._operation_error(exc)}")
            if errors and (completed or partially_deleted):
                self._finish_operation(
                    operation_id,
                    status="partial",
                    message=f"已永久删除 {completed} 个完整项目，{len(errors)} 项未能完整删除。",
                    errors=errors,
                )
            elif errors:
                self._finish_operation(operation_id, status="failed", message="没有删除任何项目。", errors=errors)
            else:
                self._finish_operation(operation_id, status="success", message=f"已永久删除 {completed} 项。")
        except Exception as exc:
            errors.append(self._operation_error(exc))
            self._finish_operation(operation_id, status="failed", message="没有删除任何项目。", errors=errors)

    def _run_operation(self, operation_id: str, request: FileManagerOperationRequest) -> None:
        with self._state_lock:
            state = self._operations[operation_id]
            state.payload.status = "running"
            state.payload.message = "正在检查文件…"
        completed = 0
        errors: list[str] = []
        try:
            with self._filesystem_lock:
                plans = self._operation_plans(request)
                total_bytes = sum(self._measure_source(plan[1], state.cancel_event) for plan in plans)
                self._update_operation(operation_id, bytes_total=total_bytes, message="正在处理文件…")
                for root, source, destination in plans:
                    if state.cancel_event.is_set():
                        raise FileOperationCanceled
                    self._update_operation(operation_id, current_item=source.name)
                    try:
                        if request.kind == "copy":
                            self._copy_atomic(source, destination, state.cancel_event, operation_id)
                        else:
                            self._move_item(source, destination, state.cancel_event, operation_id)
                        completed += 1
                        self._update_operation(operation_id, items_completed=completed)
                    except FileOperationCanceled:
                        raise
                    except Exception as exc:
                        errors.append(f"{source.name}：{self._operation_error(exc)}")
            if errors and completed:
                self._finish_operation(
                    operation_id,
                    status="partial",
                    message=f"已完成 {completed} 项，{len(errors)} 项失败。",
                    errors=errors,
                )
            elif errors:
                self._finish_operation(operation_id, status="failed", message="文件操作失败。", errors=errors)
            else:
                action = "复制" if request.kind == "copy" else "移动"
                self._finish_operation(operation_id, status="success", message=f"已{action} {completed} 项。")
        except FileOperationCanceled:
            self._finish_operation(operation_id, status="canceled", message="文件操作已取消。", errors=errors)
        except Exception as exc:
            errors.append(self._operation_error(exc))
            self._finish_operation(operation_id, status="failed", message="文件操作失败。", errors=errors)

    def _delete_plans(self, references: list[FileManagerReference]) -> list[DeletePlan]:
        plans: list[DeletePlan] = []
        seen_sources: list[Path] = []
        managed_roots = self._managed_roots()
        for reference in references:
            root = self._root_or_error(reference.root_id, require_writable=True, roots=managed_roots)
            source = self._resolve_existing(root, reference.path)
            if source == root.path:
                raise FileManagerError("不能删除 Kisetsu 管理根目录本身。", status_code=403)
            nested_roots = [
                managed
                for managed in managed_roots
                if managed.id != root.id and _contains_or_equals(managed.path, source)
            ]
            if nested_roots:
                raise FileManagerError("所选目录包含另一个 Kisetsu 管理根目录，不能整体删除。", status_code=403)
            self._ensure_mutable_source(source)
            if any(_paths_intersect(source, existing) for existing in seen_sources):
                raise FileManagerError("不能同时删除父目录及其中的子项目。")
            plans.append(self._snapshot_delete_plan(root, reference.path, source))
            seen_sources.append(source)
        return plans

    def _snapshot_delete_plan(self, root: ManagedRoot, relative_path: str, source: Path) -> DeletePlan:
        entries: list[DeleteEntrySnapshot] = []
        digest = hashlib.sha256()
        files_total = 0
        directories_total = 0
        bytes_total = 0
        try:
            source_details = source.lstat()
        except OSError as exc:
            raise FileManagerError(f"无法核对“{source.name}”：{self._safe_os_error(exc)}") from exc
        source_device = source_details.st_dev

        def visit(path: Path) -> None:
            nonlocal files_total, directories_total, bytes_total
            try:
                details = path.lstat()
            except OSError as exc:
                raise FileManagerError(f"无法核对“{path.name}”：{self._safe_os_error(exc)}") from exc
            if self._is_link_like(path, details):
                raise FileManagerError(f"“{path.name}”是符号链接或接合点，不能永久删除。")
            if stat.S_ISDIR(details.st_mode):
                if path != root.path and os.path.ismount(path):
                    raise FileManagerError(f"“{path.name}”是挂载点，不能随目录永久删除。")
                if path != source and details.st_dev != source_device:
                    raise FileManagerError(f"“{path.name}”是嵌套挂载点，不能随目录永久删除。")
                try:
                    with os.scandir(path) as children:
                        child_paths = sorted((Path(child.path) for child in children), key=lambda item: item.name)
                except OSError as exc:
                    raise FileManagerError(f"无法读取“{path.name}”：{self._safe_os_error(exc)}") from exc
                for child in child_paths:
                    visit(child)
                directories_total += 1
                is_directory = True
                size = 0
            elif stat.S_ISREG(details.st_mode):
                files_total += 1
                bytes_total += max(details.st_size, 0)
                is_directory = False
                size = max(details.st_size, 0)
            else:
                raise FileManagerError(f"“{path.name}”是设备、套接字或其他特殊文件，不能永久删除。")
            identity = self._file_identity(details)
            entry = DeleteEntrySnapshot(path=path, identity=identity, is_directory=is_directory, size=size)
            entries.append(entry)
            relative = "." if path == source else PurePosixPath(*path.relative_to(source).parts).as_posix()
            digest.update(relative.encode("utf-8", errors="surrogateescape"))
            digest.update(b"\0")
            digest.update(repr(identity).encode("ascii"))
            digest.update(b"\0")

        visit(source)
        return DeletePlan(
            root_id=root.id,
            relative_path=relative_path,
            source=source,
            entries=tuple(entries),
            digest=digest.hexdigest(),
            files_total=files_total,
            directories_total=directories_total,
            bytes_total=bytes_total,
        )

    def _delete_plan(self, plan: DeletePlan, operation_id: str) -> None:
        removed = 0
        for entry in plan.entries:
            try:
                details = entry.path.lstat()
                current_identity = self._file_identity(details)
                identity_matches = (
                    current_identity[:3] == entry.identity[:3]
                    if entry.is_directory
                    else current_identity == entry.identity
                )
                if self._is_link_like(entry.path, details) or not identity_matches:
                    raise FileDeleteFailure("内容在删除过程中发生了变化，已停止处理。", mutated=removed > 0)
                if entry.is_directory:
                    entry.path.rmdir()
                else:
                    entry.path.unlink()
                    self._increment_operation_bytes(operation_id, entry.size)
                removed += 1
            except FileDeleteFailure:
                raise
            except OSError as exc:
                raise FileDeleteFailure(self._safe_os_error(exc), mutated=removed > 0) from exc

    @staticmethod
    def _file_identity(details: os.stat_result) -> tuple[int, int, int, int, int, int]:
        return (
            details.st_dev,
            details.st_ino,
            stat.S_IFMT(details.st_mode),
            details.st_size,
            details.st_mtime_ns,
            details.st_ctime_ns,
        )

    @staticmethod
    def _is_link_like(path: Path, details: os.stat_result) -> bool:
        if stat.S_ISLNK(details.st_mode):
            return True
        is_junction = getattr(path, "is_junction", None)
        return bool(is_junction and is_junction())

    def _operation_plans(self, request: FileManagerOperationRequest) -> list[tuple[ManagedRoot, Path, Path]]:
        destination_root = self._root_or_error(request.destination_root_id, require_writable=True)
        destination_directory = self._resolve_existing(
            destination_root,
            request.destination_path,
            require_directory=True,
        )
        plans: list[tuple[ManagedRoot, Path, Path]] = []
        seen_sources: list[Path] = []
        seen_destinations: set[Path] = set()
        for reference in request.sources:
            source_root = self._root_or_error(reference.root_id, require_writable=request.kind == "move")
            source = self._resolve_existing(source_root, reference.path)
            self._ensure_mutable_source(source)
            if any(_paths_intersect(source, existing) for existing in seen_sources):
                raise FileManagerError("不能同时处理父目录及其中的子项目。")
            destination = destination_directory / source.name
            self._ensure_new_destination(destination_root, destination)
            if source == destination or (source.is_dir() and _contains_or_equals(destination, source)):
                raise FileManagerError("不能把项目复制或移动到自身内部。")
            if destination in seen_destinations:
                raise FileManagerError(f"目标目录中会产生重复名称“{destination.name}”。")
            seen_sources.append(source)
            seen_destinations.add(destination)
            plans.append((source_root, source, destination))
        return plans

    def _measure_source(self, source: Path, cancel_event: threading.Event) -> int:
        if cancel_event.is_set():
            raise FileOperationCanceled
        details = source.lstat()
        if stat.S_ISLNK(details.st_mode):
            raise FileManagerError("符号链接只能查看，不能复制或移动。")
        if stat.S_ISREG(details.st_mode):
            return details.st_size
        if not stat.S_ISDIR(details.st_mode):
            raise FileManagerError("暂不支持处理设备、套接字或其他特殊文件。")
        total = 0
        for current, directories, files in os.walk(source, followlinks=False):
            if cancel_event.is_set():
                raise FileOperationCanceled
            current_path = Path(current)
            for name in [*directories, *files]:
                item = current_path / name
                item_details = item.lstat()
                if stat.S_ISLNK(item_details.st_mode):
                    raise FileManagerError("包含符号链接的文件夹只能查看，不能复制或移动。")
                if stat.S_ISREG(item_details.st_mode):
                    total += item_details.st_size
                elif not stat.S_ISDIR(item_details.st_mode):
                    raise FileManagerError(f"“{name}”是暂不支持的特殊文件。")
        return total

    def _copy_atomic(
        self,
        source: Path,
        destination: Path,
        cancel_event: threading.Event,
        operation_id: str,
    ) -> None:
        temporary = destination.parent / f".kisetsu-copy-{uuid.uuid4().hex}"
        try:
            self._copy_path(source, temporary, cancel_event, operation_id)
            if cancel_event.is_set():
                raise FileOperationCanceled
            temporary.rename(destination)
        except Exception:
            self._remove_temporary(temporary)
            raise

    def _move_item(
        self,
        source: Path,
        destination: Path,
        cancel_event: threading.Event,
        operation_id: str,
    ) -> None:
        try:
            source.rename(destination)
            self._increment_operation_bytes(operation_id, self._measure_source(destination, threading.Event()))
            return
        except OSError as exc:
            if exc.errno != errno.EXDEV:
                raise
        self._copy_atomic(source, destination, cancel_event, operation_id)
        if cancel_event.is_set():
            raise FileOperationCanceled
        try:
            if source.is_dir():
                shutil.rmtree(source)
            else:
                source.unlink()
        except OSError as exc:
            raise FileManagerError(
                f"文件已复制到目标，但无法移除源项目：{self._safe_os_error(exc)}"
            ) from exc

    def _copy_path(
        self,
        source: Path,
        destination: Path,
        cancel_event: threading.Event,
        operation_id: str,
    ) -> None:
        details = source.lstat()
        if stat.S_ISLNK(details.st_mode):
            destination.symlink_to(os.readlink(source), target_is_directory=False)
            return
        if stat.S_ISDIR(details.st_mode):
            destination.mkdir()
            with os.scandir(source) as entries:
                for entry in entries:
                    if cancel_event.is_set():
                        raise FileOperationCanceled
                    self._copy_path(Path(entry.path), destination / entry.name, cancel_event, operation_id)
            shutil.copystat(source, destination, follow_symlinks=False)
            return
        if not stat.S_ISREG(details.st_mode):
            raise FileManagerError(f"“{source.name}”是暂不支持的特殊文件。")
        with source.open("rb") as reader, destination.open("xb") as writer:
            while True:
                if cancel_event.is_set():
                    raise FileOperationCanceled
                chunk = reader.read(COPY_CHUNK_SIZE)
                if not chunk:
                    break
                writer.write(chunk)
                self._increment_operation_bytes(operation_id, len(chunk))
        shutil.copystat(source, destination, follow_symlinks=False)

    @staticmethod
    def _remove_temporary(path: Path) -> None:
        try:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        except OSError:
            pass

    def _managed_roots(self) -> list[ManagedRoot]:
        store = self.store_factory()
        candidates: list[tuple[FileRootKind, str, str]] = []

        qbittorrent = store.get_runtime_config("qbittorrent") or {}
        transmission = store.get_runtime_config("transmission") or {}
        brush = store.get_config(BRUSH_SETTINGS_KEY) or {}
        self._append_root(candidates, "download", "qBittorrent 下载", qbittorrent.get("default_save_path"))
        self._append_root(candidates, "download", "Transmission 下载", transmission.get("default_save_path"))
        self._append_root(candidates, "brush", "站点刷流", brush.get("save_path"))

        for subscription in store.list_subscriptions():
            self._append_root(
                candidates,
                "download",
                f"订阅下载 · {subscription.get('name') or '未命名订阅'}",
                subscription.get("save_path"),
            )
        for target in store.list_organize_targets():
            self._append_root(
                candidates,
                "library",
                f"媒体库 · {target.get('name') or '整理目标'}",
                target.get("path"),
            )

        configured_paths = [self._normalized_candidate_path(value[2]) for value in candidates]
        configured_paths = [path for path in configured_paths if path is not None]
        for history in store.list_history(limit=200):
            raw_path = str(history.get("save_path") or "").strip()
            path = self._normalized_candidate_path(raw_path)
            if path is None or any(_contains_or_equals(path, configured) for configured in configured_paths):
                continue
            self._append_root(candidates, "history", "下载记录目录", raw_path)

        merged: dict[Path, dict[str, object]] = {}
        protected = self._protected_paths()
        for kind, label, raw_path in candidates:
            path = self._normalized_candidate_path(raw_path)
            if path is None or any(_contains_or_equals(path, item) for item in protected):
                continue
            current = merged.get(path)
            if current is None:
                merged[path] = {"kind": kind, "labels": [label]}
            elif label not in current["labels"]:
                current["labels"].append(label)

        kind_order = {"download": 0, "brush": 1, "library": 2, "history": 3}
        roots: list[ManagedRoot] = []
        for path, payload in merged.items():
            labels = tuple(payload["labels"])
            kind = payload["kind"]
            digest = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:20]
            roots.append(
                ManagedRoot(
                    id=f"root-{digest}",
                    name=labels[0],
                    path=path,
                    kind=kind,
                    sources=labels,
                )
            )
        roots.sort(key=lambda item: (kind_order[item.kind], item.name.casefold(), str(item.path)))
        return roots

    @staticmethod
    def _append_root(candidates: list[tuple[FileRootKind, str, str]], kind, label: str, raw_path) -> None:
        value = str(raw_path or "").strip()
        if value:
            candidates.append((kind, label, value))

    @staticmethod
    def _normalized_candidate_path(raw_path: str | None) -> Path | None:
        value = str(raw_path or "").strip()
        if not value:
            return None
        candidate = Path(value).expanduser()
        if not candidate.is_absolute():
            return None
        try:
            resolved = candidate.resolve(strict=False)
        except OSError:
            return None
        return None if resolved == Path(resolved.anchor) else resolved

    def _protected_paths(self) -> tuple[Path, ...]:
        values = {PROJECT_ROOT.resolve(strict=False), data_directory().expanduser().resolve(strict=False)}
        database = database_path().expanduser().resolve(strict=False)
        values.add(database)
        secret_database = secrets_database_path(database).expanduser().resolve(strict=False)
        values.add(secret_database)
        values.update(
            Path(f"{secret_database}{suffix}").resolve(strict=False)
            for suffix in ("-journal", "-wal", "-shm")
        )
        values.add(private_migration_backup_dir(Store(database, secret_database)).resolve(strict=False))
        return tuple(sorted(values, key=lambda item: len(item.parts)))

    def _path_is_protected(self, path: Path) -> bool:
        lexical = path.resolve(strict=False)
        return any(_contains_or_equals(lexical, protected) for protected in self._protected_paths())

    def _ensure_mutable_source(self, path: Path) -> None:
        lexical = path.resolve(strict=False)
        if any(_paths_intersect(lexical, protected) for protected in self._protected_paths()):
            raise FileManagerError("Kisetsu 程序、配置和数据目录受保护，不能执行文件操作。", status_code=403)
        if path.is_symlink():
            raise FileManagerError("符号链接只能查看，不能执行文件操作。", status_code=403)

    def _root_or_error(
        self,
        root_id: str,
        *,
        require_writable: bool = False,
        roots: list[ManagedRoot] | None = None,
    ) -> ManagedRoot:
        root = next((item for item in (roots if roots is not None else self._managed_roots()) if item.id == root_id), None)
        if root is None:
            raise FileManagerError("目录不在 Kisetsu 当前允许的管理范围内。", status_code=403)
        if not root.path.exists() or not root.path.is_dir():
            raise FileManagerError("目录当前不可用，请检查磁盘、挂载点或路径设置。", status_code=404)
        if require_writable and not os.access(root.path, os.W_OK | os.X_OK):
            raise FileManagerError("这个目录没有写入权限。", status_code=403)
        return root

    def _resolve_existing(self, root: ManagedRoot, relative_path: str, *, require_directory: bool = False) -> Path:
        current = root.path
        for part in self._relative_parts(relative_path):
            current = current / part
            try:
                details = current.lstat()
            except FileNotFoundError as exc:
                raise FileManagerError("文件或目录已不存在，请刷新后重试。", status_code=404) from exc
            except OSError as exc:
                raise FileManagerError(f"无法访问路径：{self._safe_os_error(exc)}") from exc
            if stat.S_ISLNK(details.st_mode):
                raise FileManagerError("为避免路径越界，不能进入或操作符号链接。", status_code=403)
        try:
            resolved = current.resolve(strict=True)
            resolved.relative_to(root.path)
        except (OSError, ValueError) as exc:
            raise FileManagerError("路径超出允许的管理目录，操作已阻止。", status_code=403) from exc
        if self._path_is_protected(resolved):
            raise FileManagerError("Kisetsu 程序、配置和数据目录受保护。", status_code=403)
        if require_directory and not resolved.is_dir():
            raise FileManagerError("所选目标不是文件夹。")
        return resolved

    def _ensure_new_destination(self, root: ManagedRoot, destination: Path) -> None:
        try:
            destination.parent.resolve(strict=True).relative_to(root.path)
        except (OSError, ValueError) as exc:
            raise FileManagerError("目标路径超出允许的管理目录，操作已阻止。", status_code=403) from exc
        if self._path_is_protected(destination):
            raise FileManagerError("Kisetsu 程序、配置和数据目录受保护。", status_code=403)
        if destination.exists() or destination.is_symlink():
            raise FileManagerError(f"目标目录中已存在“{destination.name}”，不会覆盖现有文件。", status_code=409)

    @staticmethod
    def _relative_parts(value: str) -> tuple[str, ...]:
        raw = str(value or "")
        if "\x00" in raw or raw.startswith("/") or raw == ".":
            raise FileManagerError("路径格式无效。")
        path = PurePosixPath(raw)
        parts = path.parts if raw else ()
        if any(part in {"", ".", ".."} for part in parts):
            raise FileManagerError("路径中不能包含上级目录或无效片段。")
        return tuple(parts)

    @staticmethod
    def _validate_name(value: str) -> str:
        if value in {"", ".", ".."} or "/" in value or "\x00" in value:
            raise FileManagerError("名称不能为空，也不能包含斜杠或上级目录。")
        if len(os.fsencode(value)) > 255:
            raise FileManagerError("名称过长。")
        return value

    def _item(self, root: ManagedRoot, path: Path, details: os.stat_result) -> FileManagerItem:
        relative = self._relative_string(root, path)
        parent = PurePosixPath(relative).parent.as_posix() if relative else ""
        if parent == ".":
            parent = ""
        symbolic_link = stat.S_ISLNK(details.st_mode)
        directory = stat.S_ISDIR(details.st_mode)
        return FileManagerItem(
            id=hashlib.sha256(f"{root.id}\0{relative}".encode("utf-8")).hexdigest(),
            root_id=root.id,
            path=relative,
            parent_path=parent,
            name=path.name,
            kind=self._item_kind(path, directory),
            is_directory=directory,
            is_symbolic_link=symbolic_link,
            is_hidden=path.name.startswith("."),
            is_expandable=directory and not symbolic_link,
            size_bytes=None if directory or symbolic_link else details.st_size,
            modified_at=utc_iso(datetime.fromtimestamp(details.st_mtime, tz=timezone.utc)),
        )

    @staticmethod
    def _item_kind(path: Path, directory: bool) -> str:
        if directory:
            return "directory"
        suffix = path.suffix.casefold()
        if suffix in {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts"}:
            return "video"
        if suffix in {".flac", ".mp3", ".m4a", ".aac", ".wav", ".ogg"}:
            return "audio"
        if suffix in {".ass", ".ssa", ".srt", ".vtt", ".sub"}:
            return "subtitle"
        if suffix in {".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif"}:
            return "image"
        if suffix in {".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz"}:
            return "archive"
        return "other"

    @staticmethod
    def _relative_string(root: ManagedRoot, path: Path) -> str:
        relative = path.relative_to(root.path)
        return "" if not relative.parts else PurePosixPath(*relative.parts).as_posix()

    def _public_root(self, root: ManagedRoot) -> FileManagerRoot:
        exists = root.path.exists() and root.path.is_dir()
        return FileManagerRoot(
            id=root.id,
            name=root.name,
            path=str(root.path),
            kind=root.kind,
            sources=list(root.sources),
            exists=exists,
            readable=exists and os.access(root.path, os.R_OK | os.X_OK),
            writable=exists and os.access(root.path, os.W_OK | os.X_OK),
        )

    def _require_edit_session(self, token: str, client_host: str) -> None:
        now = utc_now()
        with self._state_lock:
            self._purge_expired_sessions_locked(now)
            session = self._sessions.get(token)
            if session is None or session.client_host != client_host:
                raise FileManagerError("编辑会话已失效，已恢复只读模式。", status_code=403)
            session.expires_at = now + EDIT_SESSION_TTL

    def _purge_expired_sessions_locked(self, now: datetime | None = None) -> None:
        current = now or utc_now()
        expired = [token for token, session in self._sessions.items() if session.expires_at <= current]
        for token in expired:
            self._sessions.pop(token, None)
        if expired:
            self._delete_previews = {
                token: preview
                for token, preview in self._delete_previews.items()
                if preview.edit_token not in expired
            }

    def _purge_expired_delete_previews_locked(self, now: datetime | None = None) -> None:
        current = now or utc_now()
        expired = [token for token, preview in self._delete_previews.items() if preview.expires_at <= current]
        for token in expired:
            self._delete_previews.pop(token, None)

    def _purge_operations_locked(self) -> None:
        terminal = sorted(
            (
                state.payload
                for state in self._operations.values()
                if state.payload.status not in {"queued", "running"}
            ),
            key=lambda item: item.finished_at or item.started_at,
            reverse=True,
        )
        for item in terminal[50:]:
            self._operations.pop(item.id, None)

    def _update_operation(self, operation_id: str, **values) -> None:
        with self._state_lock:
            payload = self._operations[operation_id].payload
            for key, value in values.items():
                setattr(payload, key, value)

    def _increment_operation_bytes(self, operation_id: str, amount: int) -> None:
        with self._state_lock:
            self._operations[operation_id].payload.bytes_completed += max(amount, 0)

    def _finish_operation(self, operation_id: str, *, status: str, message: str, errors: Iterable[str] = ()) -> None:
        with self._state_lock:
            payload = self._operations[operation_id].payload
            payload.status = status
            payload.message = message
            payload.errors = list(errors)
            payload.current_item = None
            payload.finished_at = utc_iso()

    @staticmethod
    def _safe_os_error(exc: OSError) -> str:
        if isinstance(exc, PermissionError):
            return "没有权限"
        if isinstance(exc, FileNotFoundError):
            return "文件或目录不存在"
        if isinstance(exc, FileExistsError):
            return "目标已存在"
        if exc.errno == errno.ENOSPC:
            return "磁盘空间不足"
        if exc.errno == errno.EROFS:
            return "目标磁盘为只读"
        if exc.errno == errno.ENAMETOOLONG:
            return "路径或名称过长"
        return exc.strerror or "文件系统错误"

    def _operation_error(self, exc: Exception) -> str:
        if isinstance(exc, FileManagerError):
            return exc.message
        if isinstance(exc, OSError):
            return self._safe_os_error(exc)
        return str(exc) or "未知文件系统错误"
