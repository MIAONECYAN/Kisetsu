from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, HTTPException, Query, Request
from fastapi.responses import FileResponse

from app.playlists.bangumi_data import BangumiDataError
from app.playlists.models import (
    PairingDeleteRequest,
    PairingRequest,
    PlaylistCreatePreviewRequest,
    PlaylistCreatePreviewResponse,
    PlaylistCreateRequest,
    PlaylistCreateResponse,
    PlaylistQuarterOption,
    PlaylistQuarterResponse,
    PlaylistSettingsResponse,
    PlaylistSettingsUpdate,
    PlexConnectionResponse,
    PlexPairing,
    PlexPlaylistDetail,
    PlexPlaylistSummary,
    PlexShow,
    PlexShowHierarchy,
)
from app.playlists.service import PlaylistService, PlaylistServiceError


router = APIRouter(prefix="/api/playlists", tags=["playlists"])


def service(request: Request) -> PlaylistService:
    value = getattr(request.app.state, "playlists", None)
    if not isinstance(value, PlaylistService):
        raise HTTPException(status_code=503, detail="播放列表服务尚未启动。")
    return value


def raise_service_error(exc: Exception) -> None:
    if isinstance(exc, PlaylistServiceError):
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
    if isinstance(exc, BangumiDataError):
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    raise exc


@router.get("/settings", response_model=PlaylistSettingsResponse)
async def get_settings(request: Request) -> PlaylistSettingsResponse:
    return service(request).settings()


@router.put("/settings", response_model=PlaylistSettingsResponse)
async def update_settings(payload: PlaylistSettingsUpdate, request: Request) -> PlaylistSettingsResponse:
    return service(request).update_settings(payload)


@router.post("/connection-test", response_model=PlexConnectionResponse)
async def connection_test(request: Request) -> PlexConnectionResponse:
    try:
        return await service(request).test_connection()
    except Exception as exc:
        raise_service_error(exc)


@router.get("/quarters", response_model=list[PlaylistQuarterOption])
async def quarters(request: Request, refresh: bool = False) -> list[PlaylistQuarterOption]:
    try:
        return await service(request).quarter_options(force=refresh)
    except Exception as exc:
        raise_service_error(exc)


@router.get("/quarters/{year}/{month}", response_model=PlaylistQuarterResponse)
async def quarter(year: int, month: int, request: Request, refresh: bool = False) -> PlaylistQuarterResponse:
    try:
        return await service(request).quarter(year, month, force=refresh)
    except Exception as exc:
        raise_service_error(exc)


@router.post("/quarters/{year}/{month}/warm-posters")
async def warm_posters(year: int, month: int, request: Request, background_tasks: BackgroundTasks) -> dict[str, bool]:
    background_tasks.add_task(service(request).warm_posters, year, month)
    return {"ok": True}


@router.get("/posters/{item_key}", include_in_schema=False)
async def poster(item_key: str, request: Request) -> FileResponse:
    try:
        path = await service(request).poster(item_key)
    except Exception as exc:
        raise_service_error(exc)
    if not path:
        raise HTTPException(status_code=404, detail="海报暂不可用。")
    return FileResponse(path)


@router.get("/plex/shows", response_model=list[PlexShow])
async def plex_shows(request: Request, query: str = Query(default="", max_length=200)) -> list[PlexShow]:
    try:
        return await service(request).search_plex(query)
    except Exception as exc:
        raise_service_error(exc)


@router.get("/plex/shows/{rating_key}/hierarchy", response_model=PlexShowHierarchy)
async def hierarchy(rating_key: str, request: Request) -> PlexShowHierarchy:
    try:
        return await service(request).hierarchy(rating_key)
    except Exception as exc:
        raise_service_error(exc)


@router.post("/pairings", response_model=PlexPairing)
async def pair(payload: PairingRequest, request: Request) -> PlexPairing:
    try:
        return await service(request).pair(payload)
    except Exception as exc:
        raise_service_error(exc)


@router.post("/pairings/remove")
async def unpair(payload: PairingDeleteRequest, request: Request) -> dict[str, bool]:
    try:
        return {"ok": await service(request).unpair(payload.item_key)}
    except Exception as exc:
        raise_service_error(exc)


@router.post("/pairings/rematch")
async def rematch(payload: PairingDeleteRequest, request: Request) -> dict[str, bool]:
    try:
        return {"ok": await service(request).rematch(payload.item_key)}
    except Exception as exc:
        raise_service_error(exc)


@router.get("/existing", response_model=list[PlexPlaylistSummary])
async def existing(request: Request) -> list[PlexPlaylistSummary]:
    try:
        return await service(request).playlists()
    except Exception as exc:
        raise_service_error(exc)


@router.get("/existing/{rating_key}/poster", include_in_schema=False)
async def existing_poster(rating_key: str, request: Request) -> FileResponse:
    try:
        path = await service(request).playlist_poster(rating_key)
    except Exception as exc:
        raise_service_error(exc)
    if not path:
        raise HTTPException(status_code=404, detail="播放列表封面暂不可用。")
    return FileResponse(path, headers={"Cache-Control": "public, max-age=86400"})


@router.get("/existing/{rating_key}/items/{item_rating_key}/poster", include_in_schema=False)
async def existing_item_poster(
    rating_key: str,
    item_rating_key: str,
    request: Request,
) -> FileResponse:
    try:
        path = await service(request).playlist_item_poster(rating_key, item_rating_key)
    except Exception as exc:
        raise_service_error(exc)
    if not path:
        raise HTTPException(status_code=404, detail="播放列表视频封面暂不可用。")
    return FileResponse(path, headers={"Cache-Control": "public, max-age=86400"})


@router.get("/existing/{rating_key}", response_model=PlexPlaylistDetail)
async def existing_detail(rating_key: str, request: Request) -> PlexPlaylistDetail:
    try:
        return await service(request).playlist_detail(rating_key)
    except Exception as exc:
        raise_service_error(exc)


@router.post("/create-preview", response_model=PlaylistCreatePreviewResponse)
async def create_preview(payload: PlaylistCreatePreviewRequest, request: Request) -> PlaylistCreatePreviewResponse:
    try:
        return await service(request).preview(payload)
    except Exception as exc:
        raise_service_error(exc)


@router.post("/create", response_model=PlaylistCreateResponse)
async def create(payload: PlaylistCreateRequest, request: Request) -> PlaylistCreateResponse:
    try:
        return await service(request).create(payload)
    except Exception as exc:
        raise_service_error(exc)
