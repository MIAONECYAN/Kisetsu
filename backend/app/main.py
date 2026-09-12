from __future__ import annotations

import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from typing import Any

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.routes import background_sync_download_history, configure_automation_service, router
from app.api.credentials import router as credentials_router
from app.automation import AutomationService
from app.brush.routes import router as brush_router
from app.brush.service import BrushService
from app.dependencies import get_store, init_store
from app.file_manager import FileManagerService
from app.file_manager.routes import router as file_manager_router
from app.playlists import PlaylistService
from app.playlists.routes import router as playlist_router
from app.models import HealthResponse
from app.resource_diagnostics import resource_diagnostics
from app.settings import environment_value, prepare_data_directory
from app.task_state_scheduler import TaskStateScheduler


STARTED_AT = datetime.now(timezone.utc)


def _error_payload(message: str, *, code: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"detail": message, "message": message}
    if code:
        payload["code"] = code
    return payload


def _http_error_payload(exc: StarletteHTTPException) -> dict[str, Any]:
    if isinstance(exc.detail, str) and exc.detail.strip():
        return _error_payload(exc.detail)
    if isinstance(exc.detail, dict):
        message = exc.detail.get("message") or exc.detail.get("detail") or "请求处理失败，请检查输入后重试。"
        code = exc.detail.get("code")
        return _error_payload(str(message), code=str(code) if code else None)
    return _error_payload("请求处理失败，请检查输入后重试。")


def create_app() -> FastAPI:
    data_directory_status = prepare_data_directory()
    if data_directory_status == "copied":
        print("Kisetsu 数据已复制到项目根 data/；旧 backend/data/ 已保留为备份。")
    init_store()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.automation = configure_automation_service(AutomationService(get_store))
        app.state.brush = BrushService(get_store)
        app.state.file_manager = FileManagerService(get_store)
        app.state.playlists = PlaylistService(get_store())
        await app.state.automation.restore_from_store()
        await app.state.brush.restore_from_store()
        app.state.task_state = TaskStateScheduler(
            get_store,
            app.state.brush,
            background_sync_download_history,
        )
        await app.state.task_state.start()
        try:
            yield
        finally:
            await app.state.task_state.shutdown()
            await app.state.file_manager.shutdown()
            await app.state.automation.shutdown()
            await app.state.brush.shutdown()

    app = FastAPI(title="Kisetsu", version="0.1.0", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["http://127.0.0.1", "http://localhost"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(_request, _exc: RequestValidationError) -> JSONResponse:
        message = "请求参数无效，请检查必填字段和格式。"
        for error in _exc.errors():
            ctx_error = (error.get("ctx") or {}).get("error")
            candidate = str(ctx_error or error.get("msg") or "")
            if any(marker in candidate for marker in ("请选择", "请输入", "起始集数", "INVALID_ORGANIZE_POLICY")):
                message = candidate.replace("Value error, ", "")
                break
        return JSONResponse(status_code=422, content=_error_payload(message))

    @app.exception_handler(StarletteHTTPException)
    async def http_exception_handler(_request, exc: StarletteHTTPException) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=_http_error_payload(exc))

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(_request, _exc: Exception) -> JSONResponse:
        message = "后端内部错误，请查看日志后重试。"
        return JSONResponse(status_code=500, content=_error_payload(message))

    @app.get("/api/health", response_model=HealthResponse)
    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        database_status = "ok"
        qbittorrent_configured = False
        transmission_configured = False
        try:
            store = get_store()
            store.list_subscriptions()
            config = store.get_runtime_config("qbittorrent")
            if isinstance(config, dict):
                qbittorrent_configured = bool(config.get("base_url") and config.get("username") and config.get("password"))
            transmission = store.get_runtime_config("transmission")
            if isinstance(transmission, dict):
                transmission_configured = bool(transmission.get("base_url"))
        except Exception:
            database_status = "error"
        port_value = environment_value("KISETSU_BACKEND_PORT", "ANIMEPILOT_BACKEND_PORT")
        try:
            port = int(port_value) if port_value else None
        except ValueError:
            port = None
        return HealthResponse(
            time=datetime.now(timezone.utc),
            port=port,
            database_status=database_status,
            qbittorrent_configured=qbittorrent_configured,
            transmission_configured=transmission_configured,
            started_at=STARTED_AT,
            pid=os.getpid(),
        )

    @app.get("/api/diagnostics/resources", include_in_schema=False)
    def resources() -> dict[str, Any]:
        return resource_diagnostics(get_store())

    app.include_router(router)
    app.include_router(credentials_router)
    app.include_router(brush_router)
    app.include_router(file_manager_router)
    app.include_router(playlist_router)
    return app


app = create_app()
