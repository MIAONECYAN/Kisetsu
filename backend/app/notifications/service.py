from __future__ import annotations

import asyncio
import logging
from pathlib import Path
import re
from weakref import WeakKeyDictionary

from app.db import Store
from app.notifications.models import (
    BarkNotificationSettingsResponse,
    NotificationEvent,
    NotificationSettings,
    NotificationSettingsResponse,
    NotificationTestResponse,
)
from app.notifications.providers import BarkProvider
from app.settings import mask_secret

logger = logging.getLogger("kisetsu.notifications")
_SEND_LOCKS: WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Lock] = WeakKeyDictionary()


def _send_lock() -> asyncio.Lock:
    loop = asyncio.get_running_loop()
    lock = _SEND_LOCKS.get(loop)
    if lock is None:
        lock = asyncio.Lock()
        _SEND_LOCKS[loop] = lock
    return lock


def stored_notification_settings(store: Store) -> NotificationSettings:
    data = store.get_runtime_config("notifications") or {}
    return NotificationSettings(**data)


def notification_settings_response(settings: NotificationSettings) -> NotificationSettingsResponse:
    key = settings.bark.device_key or ""
    masked_key = mask_secret(key) if key else None
    bark_response = BarkNotificationSettingsResponse(
        enabled=settings.bark.enabled,
        server_url=settings.bark.server_url,
        has_device_key=bool(key),
        masked_device_key=masked_key,
        group=settings.bark.group,
        sound=settings.bark.sound,
        icon=settings.bark.icon,
        level=settings.bark.level,
        url=settings.bark.url,
        auto_copy=settings.bark.auto_copy,
    )
    configured = settings.enabled and settings.bark.enabled and bool(key)
    return NotificationSettingsResponse(
        enabled=settings.enabled,
        bark=bark_response,
        events=settings.events,
        show_full_paths=settings.show_full_paths,
        has_bark_device_key=bool(key),
        masked_bark_device_key=masked_key,
        message="Bark 通知已启用" if configured else "通知未启用或 Bark 未配置",
    )


def merge_notification_settings(new_settings: NotificationSettings, existing: NotificationSettings) -> NotificationSettings:
    data = new_settings.model_dump(mode="json")
    if new_settings.bark.clear_device_key:
        data["bark"]["device_key"] = None
    elif not (new_settings.bark.device_key or "").strip():
        data["bark"]["device_key"] = existing.bark.device_key
    else:
        data["bark"]["device_key"] = new_settings.bark.device_key.strip()
    data["bark"]["clear_device_key"] = False
    return NotificationSettings(**data)


def notification_settings_from_payload(payload: dict, existing: NotificationSettings) -> NotificationSettings:
    if "bark" in payload or "events" in payload:
        return merge_notification_settings(NotificationSettings(**payload), existing)

    bark = existing.bark.model_dump(mode="json")
    events = existing.events.model_dump(mode="json")
    data = {
        "enabled": bool(payload.get("notifications_enabled", payload.get("enabled", existing.enabled))),
        "bark": bark,
        "events": events,
        "show_full_paths": bool(payload.get("show_full_paths", existing.show_full_paths)),
    }
    flat_map = {
        "bark_enabled": "enabled",
        "bark_server_url": "server_url",
        "bark_group": "group",
        "bark_sound": "sound",
        "bark_icon": "icon",
        "bark_level": "level",
        "bark_url": "url",
        "bark_auto_copy": "auto_copy",
    }
    for source_key, target_key in flat_map.items():
        if source_key in payload:
            bark[target_key] = payload[source_key]
    if payload.get("clear_bark_device_key") is True:
        bark["device_key"] = None
    else:
        key = payload.get("bark_device_key")
        if isinstance(key, str) and key.strip():
            bark["device_key"] = key.strip()
    if "subscription_notifications_enabled" in payload:
        events["subscription"] = bool(payload["subscription_notifications_enabled"])
    if "download_notifications_enabled" in payload:
        events["download"] = bool(payload["download_notifications_enabled"])
    if "organize_notifications_enabled" in payload:
        events["organize"] = bool(payload["organize_notifications_enabled"])
    bark["clear_device_key"] = False
    return NotificationSettings(**data)


class NotificationService:
    def __init__(self, store: Store):
        self.store = store
        self.providers = {"bark": BarkProvider()}

    async def send(self, event: NotificationEvent, *, dedupe: bool = True) -> NotificationTestResponse:
        settings = stored_notification_settings(self.store)
        if not self._event_enabled(settings, event):
            return NotificationTestResponse(ok=True, provider="none", message="通知已关闭，未发送。")
        provider_name = "bark"
        provider = self.providers[provider_name]
        async with _send_lock():
            if dedupe and self.store.notification_event_sent(event.event_key, provider_name):
                return NotificationTestResponse(ok=True, provider=provider_name, message="事件已通知过，已跳过。")
            record = self.store.add_notification_event(
                event_key=event.event_key,
                event_type=event.event_type,
                provider=provider_name,
                title=event.title,
                payload=event.model_dump(mode="json"),
                status="pending",
            )
            try:
                await provider.send(event, settings)
            except Exception as exc:
                message = self._safe_error(str(exc), settings)
                self.store.update_notification_event(record["id"], status="failed", error_message=message)
                logger.warning("notification failed provider=%s event=%s: %s", provider_name, event.event_type, message)
                return NotificationTestResponse(ok=False, provider=provider_name, message=message)
            self.store.update_notification_event(record["id"], status="sent", sent=True)
            return NotificationTestResponse(ok=True, provider=provider_name, message="通知已发送")

    async def test(self, event: NotificationEvent) -> NotificationTestResponse:
        settings = stored_notification_settings(self.store)
        if not settings.enabled:
            return NotificationTestResponse(ok=False, provider="bark", message="请先启用通知")
        if not settings.bark.enabled:
            return NotificationTestResponse(ok=False, provider="bark", message="请先启用 Bark")
        if not settings.bark.server_url.strip():
            return NotificationTestResponse(ok=False, provider="bark", message="请填写 Bark Server 地址")
        if not (settings.bark.device_key or "").strip():
            return NotificationTestResponse(ok=False, provider="bark", message="请先配置 Bark Device Key")
        return await self.send(event, dedupe=False)

    async def send_best_effort(self, event: NotificationEvent, *, dedupe: bool = True) -> NotificationTestResponse | None:
        try:
            return await self.send(event, dedupe=dedupe)
        except Exception as exc:
            logger.warning("notification best-effort wrapper swallowed error event=%s: %s", event.event_type, exc)
            return None

    def _event_enabled(self, settings: NotificationSettings, event: NotificationEvent) -> bool:
        if not settings.enabled:
            return False
        if event.event_type.startswith("subscription_"):
            return settings.events.subscription
        if event.event_type.startswith("download_"):
            return settings.events.download
        if event.event_type.startswith("organize_"):
            return settings.events.organize
        return True

    def _safe_error(self, message: str, settings: NotificationSettings) -> str:
        key = settings.bark.device_key or ""
        safe = message.replace(key, "••••") if key else message
        safe = re.sub(r"https?://[^\s\"']+", "••••", safe)
        server_url = settings.bark.server_url.strip().rstrip("/")
        if server_url:
            safe = safe.replace(server_url, "Bark 服务")
        return safe


def file_name_only(path: str | None) -> str | None:
    if not path:
        return None
    return Path(path).name or path
