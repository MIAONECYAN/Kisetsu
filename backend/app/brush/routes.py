from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query, Request

from app.brush.models import (
    BrushActionRequest,
    BrushActionResponse,
    BrushBatchActionRequest,
    BrushCandidatePage,
    BrushCapabilities,
    BrushClearRequest,
    BrushRun,
    BrushRunResponse,
    BrushSettings,
    BrushSiteAccount,
    BrushStatus,
    BrushTask,
)
from app.brush.service import BrushService
from app.sites import describe_site_error


router = APIRouter(prefix="/api/brush", tags=["brush"])


def service(request: Request) -> BrushService:
    value = getattr(request.app.state, "brush", None)
    if not isinstance(value, BrushService):
        raise HTTPException(status_code=503, detail="站点刷流服务尚未启动。")
    return value


@router.get("/settings", response_model=BrushSettings)
async def get_settings(request: Request) -> BrushSettings:
    return service(request).settings()


@router.put("/settings", response_model=BrushStatus)
async def update_settings(payload: BrushSettings, request: Request) -> BrushStatus:
    try:
        return await service(request).update_settings(payload)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/status", response_model=BrushStatus)
async def get_status(request: Request) -> BrushStatus:
    return await service(request).status()


@router.get("/capabilities", response_model=list[BrushCapabilities])
async def get_capabilities(request: Request) -> list[BrushCapabilities]:
    return service(request).capabilities()


@router.get("/site-accounts", response_model=list[BrushSiteAccount])
async def site_accounts(request: Request, refresh: bool = False) -> list[BrushSiteAccount]:
    return await service(request).site_accounts(refresh=refresh)


@router.post("/start", response_model=BrushStatus)
async def start(request: Request) -> BrushStatus:
    try:
        return await service(request).start()
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/stop", response_model=BrushStatus)
async def stop(request: Request) -> BrushStatus:
    return await service(request).stop()


@router.post("/run-now", response_model=BrushRunResponse)
async def run_now(request: Request) -> BrushRunResponse:
    run = await service(request).run_brush(trigger="manual")
    return BrushRunResponse(ok=run.status in {"success", "partial"}, message=run.summary or "刷流执行完成", status=await service(request).status(), run=run)


@router.post("/check-now", response_model=BrushRunResponse)
async def check_now(request: Request) -> BrushRunResponse:
    run = await service(request).run_check(trigger="manual")
    return BrushRunResponse(ok=run.status in {"success", "partial"}, message=run.summary or "任务检查完成", status=await service(request).status(), run=run)


@router.get("/candidates/{site_id}", response_model=BrushCandidatePage)
async def candidates(
    site_id: str,
    request: Request,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=100),
) -> BrushCandidatePage:
    try:
        return await service(request).candidates(site_id, page=page, page_size=page_size)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=describe_site_error(exc)) from exc


@router.get("/tasks", response_model=list[BrushTask])
async def tasks(request: Request, include_archived: bool = False) -> list[BrushTask]:
    return service(request).repository().list_tasks(include_archived=include_archived)


@router.get("/tasks/{task_id}", response_model=BrushTask)
async def task_detail(task_id: int, request: Request) -> BrushTask:
    task = service(request).repository().get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="刷流任务不存在。")
    return task


@router.post("/tasks/{task_id}/manage", response_model=BrushActionResponse)
async def manage_task(task_id: int, payload: BrushActionRequest, request: Request) -> BrushActionResponse:
    try:
        response = await service(request).manage_task(task_id, payload.action)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc) or "刷流任务操作失败。") from exc
    if not response.ok:
        raise HTTPException(status_code=409, detail=response.message)
    return response


@router.post("/tasks/manage-batch", response_model=BrushActionResponse)
async def batch_manage(payload: BrushBatchActionRequest, request: Request) -> BrushActionResponse:
    return await service(request).batch_manage(payload.task_ids, payload.action)


@router.get("/runs/recent", response_model=list[BrushRun])
async def recent_runs(request: Request, limit: int = Query(default=50, ge=1, le=200)) -> list[BrushRun]:
    return service(request).repository().list_runs(limit=limit)


@router.post("/records/clear", response_model=BrushActionResponse)
async def clear_records(payload: BrushClearRequest, request: Request) -> BrushActionResponse:
    if not payload.confirm:
        raise HTTPException(status_code=422, detail="清空刷流记录前需要确认。")
    if payload.include_active:
        active = service(request).repository().active_tasks()
        if active:
            raise HTTPException(status_code=409, detail="仍有活动刷流任务，不能直接清空其归属记录。请先管理这些任务。")
    deleted = service(request).repository().clear_records(include_active=payload.include_active)
    return BrushActionResponse(ok=True, message=f"已清理 {deleted} 条刷流记录。", affected=deleted)
