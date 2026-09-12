from __future__ import annotations

import asyncio

from fastapi import APIRouter, HTTPException, Query, Request

from app.file_manager.models import (
    FileManagerCancelRequest,
    FileManagerCreateFolderRequest,
    FileManagerDeletePreview,
    FileManagerDeletePreviewRequest,
    FileManagerDeleteRequest,
    FileManagerDirectoryResponse,
    FileManagerEditSession,
    FileManagerEditSessionRequest,
    FileManagerLockRequest,
    FileManagerOperationRequest,
    FileManagerOperationStatus,
    FileManagerRenameRequest,
    FileManagerRootResponse,
    FileManagerWriteResponse,
)
from app.file_manager.service import FileManagerError, FileManagerService


router = APIRouter(prefix="/api/files", tags=["files"])


def service(request: Request) -> FileManagerService:
    value = getattr(request.app.state, "file_manager", None)
    if not isinstance(value, FileManagerService):
        raise HTTPException(status_code=503, detail="文件管理服务尚未启动。")
    return value


def client_host(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def raise_http(exc: FileManagerError) -> None:
    raise HTTPException(status_code=exc.status_code, detail=exc.message) from exc


@router.get("/roots", response_model=FileManagerRootResponse)
async def roots(request: Request) -> FileManagerRootResponse:
    return await asyncio.to_thread(service(request).roots_response)


@router.get("/list", response_model=FileManagerDirectoryResponse)
async def list_directory(
    request: Request,
    root_id: str = Query(min_length=1),
    path: str = "",
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=250, ge=1, le=500),
    show_hidden: bool = False,
) -> FileManagerDirectoryResponse:
    try:
        return await asyncio.to_thread(
            service(request).list_directory,
            root_id,
            path,
            offset=offset,
            limit=limit,
            show_hidden=show_hidden,
        )
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/edit-session", response_model=FileManagerEditSession)
async def create_edit_session(
    payload: FileManagerEditSessionRequest,
    request: Request,
) -> FileManagerEditSession:
    try:
        return service(request).create_edit_session(client_host=client_host(request), confirm=payload.confirm)
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/edit-session/lock", response_model=FileManagerWriteResponse)
async def lock_edit_session(payload: FileManagerLockRequest, request: Request) -> FileManagerWriteResponse:
    return service(request).lock_edit_session(token=payload.token, client_host=client_host(request))


@router.post("/rename", response_model=FileManagerWriteResponse)
async def rename(payload: FileManagerRenameRequest, request: Request) -> FileManagerWriteResponse:
    try:
        return await asyncio.to_thread(
            service(request).rename,
            edit_token=payload.edit_token,
            client_host=client_host(request),
            root_id=payload.root_id,
            relative_path=payload.path,
            new_name=payload.new_name,
        )
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/folders", response_model=FileManagerWriteResponse)
async def create_folder(payload: FileManagerCreateFolderRequest, request: Request) -> FileManagerWriteResponse:
    try:
        return await asyncio.to_thread(
            service(request).create_folder,
            edit_token=payload.edit_token,
            client_host=client_host(request),
            root_id=payload.root_id,
            parent_path=payload.parent_path,
            name=payload.name,
        )
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/delete-preview", response_model=FileManagerDeletePreview)
async def preview_delete(
    payload: FileManagerDeletePreviewRequest,
    request: Request,
) -> FileManagerDeletePreview:
    try:
        return await asyncio.to_thread(
            service(request).preview_delete,
            edit_token=payload.edit_token,
            client_host=client_host(request),
            references=payload.sources,
        )
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/delete", response_model=FileManagerOperationStatus, status_code=202)
async def start_delete(payload: FileManagerDeleteRequest, request: Request) -> FileManagerOperationStatus:
    try:
        return await service(request).start_delete(payload, client_host=client_host(request))
    except FileManagerError as exc:
        raise_http(exc)


@router.post("/operations", response_model=FileManagerOperationStatus, status_code=202)
async def start_operation(payload: FileManagerOperationRequest, request: Request) -> FileManagerOperationStatus:
    try:
        return await service(request).start_operation(payload, client_host=client_host(request))
    except FileManagerError as exc:
        raise_http(exc)


@router.get("/operations/{operation_id}", response_model=FileManagerOperationStatus)
async def operation(operation_id: str, request: Request) -> FileManagerOperationStatus:
    try:
        return service(request).operation(operation_id)
    except FileManagerError as exc:
        raise_http(exc)


@router.get("/operations", response_model=list[FileManagerOperationStatus])
async def recent_operations(
    request: Request,
    limit: int = Query(default=20, ge=1, le=50),
) -> list[FileManagerOperationStatus]:
    return service(request).recent_operations(limit)


@router.post("/operations/{operation_id}/cancel", response_model=FileManagerOperationStatus)
async def cancel_operation(
    operation_id: str,
    payload: FileManagerCancelRequest,
    request: Request,
) -> FileManagerOperationStatus:
    try:
        return service(request).cancel_operation(
            operation_id,
            edit_token=payload.edit_token,
            client_host=client_host(request),
        )
    except FileManagerError as exc:
        raise_http(exc)
