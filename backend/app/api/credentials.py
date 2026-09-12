from __future__ import annotations

import json

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app.db import Store
from app.dependencies import get_store
from app.secret_config import CONFIG_SECRET_FIELDS, SITE_SECRET_FIELDS
from app.settings import tmdb_api_key


router = APIRouter(prefix="/api/settings")


class CredentialRequest(BaseModel):
    scope: str
    field: str
    item: str | None = None


@router.post("/credential")
def read_credential(request: CredentialRequest, store: Store = Depends(get_store)) -> JSONResponse:
    # Only explicit credential fields can be read; ordinary settings stay redacted.
    scope, field, item = request.scope, request.field, request.item
    if scope == "site_settings" and field in SITE_SECRET_FIELDS and item:
        payload = (store.get_runtime_config(scope) or {}).get(item, {})
        value = payload.get(field)
        if isinstance(value, dict):
            value = json.dumps(value, ensure_ascii=False, indent=2) if value else ""
    elif scope == "ai_settings" and field == "api_key":
        payload = store.get_runtime_config(scope) or {}
        provider = item or payload.get("provider")
        value = (payload.get("provider_profiles") or {}).get(provider, {}).get("api_key")
        if not value and provider == payload.get("provider"):
            value = payload.get("api_key")
    elif scope == "notifications" and field == "device_key" and item is None:
        value = ((store.get_runtime_config(scope) or {}).get("bark") or {}).get(field)
    elif field in CONFIG_SECRET_FIELDS.get(scope, ()) and item is None:
        value = (store.get_runtime_config(scope) or {}).get(field)
        if scope == "metadata" and field == "tmdb_api_key":
            value = tmdb_api_key() or value
    else:
        raise HTTPException(status_code=400, detail="不支持读取此凭证。")
    return JSONResponse({"value": value or ""}, headers={"Cache-Control": "no-store", "Pragma": "no-cache"})
