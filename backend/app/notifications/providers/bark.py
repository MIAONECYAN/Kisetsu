from __future__ import annotations

import asyncio
from typing import Any
from weakref import WeakKeyDictionary

import httpx

from app.notifications.models import NotificationEvent, NotificationSettings
from app.notifications.providers.base import NotificationProvider


_DELIVERY_LOCKS: WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Lock] = WeakKeyDictionary()


def _delivery_lock() -> asyncio.Lock:
    loop = asyncio.get_running_loop()
    lock = _DELIVERY_LOCKS.get(loop)
    if lock is None:
        lock = asyncio.Lock()
        _DELIVERY_LOCKS[loop] = lock
    return lock


class BarkProvider(NotificationProvider):
    name = "bark"

    def __init__(self, *, client: httpx.AsyncClient | None = None, sleep=asyncio.sleep):
        self._external_client = client
        self._sleep = sleep

    async def send(self, event: NotificationEvent, settings: NotificationSettings) -> None:
        bark = settings.bark
        if not settings.enabled or not bark.enabled:
            return
        device_key = (bark.device_key or "").strip()
        if not device_key:
            raise ValueError("Bark Device Key 未配置")

        payload: dict[str, Any] = {
            "title": event.title,
            "body": event.body,
            "device_key": device_key,
            "group": bark.group or "Kisetsu",
        }
        optional = {
            "icon": event.poster_url or bark.icon,
            "url": event.url or bark.url,
            "sound": bark.sound,
            "level": bark.level,
            "automaticallyCopy": "1" if bark.auto_copy else None,
        }
        payload.update({key: value for key, value in optional.items() if value not in (None, "")})

        server_url = bark.server_url.rstrip("/")
        client = self._external_client or httpx.AsyncClient(timeout=10)
        try:
            async with _delivery_lock():
                for attempt in range(3):
                    try:
                        response = await client.post(f"{server_url}/push", json=payload)
                    except httpx.TimeoutException:
                        if attempt < 2:
                            await self._sleep(0.5 * (attempt + 1))
                            continue
                        raise ValueError("Bark 请求超时") from None
                    except httpx.RequestError:
                        if attempt < 2:
                            await self._sleep(0.5 * (attempt + 1))
                            continue
                        raise ValueError("Bark 连接失败") from None

                    if response.status_code == 429 or response.status_code >= 500:
                        if attempt < 2:
                            await self._sleep(self._retry_delay(response, attempt))
                            continue
                        body = self._safe_body(response, device_key)
                        raise ValueError(f"Bark 返回 HTTP {response.status_code}：{body}")
                    if response.status_code >= 400:
                        body = self._safe_body(response, device_key)
                        raise ValueError(f"Bark 返回 HTTP {response.status_code}：{body}")
                    self._validate_business_response(response, device_key)
                    return
        finally:
            if self._external_client is None:
                await client.aclose()

    @staticmethod
    def _retry_delay(response: httpx.Response, attempt: int) -> float:
        value = response.headers.get("Retry-After", "").strip()
        try:
            return min(max(float(value), 0.0), 5.0)
        except ValueError:
            return 0.5 * (attempt + 1)

    @staticmethod
    def _safe_body(response: httpx.Response, device_key: str) -> str:
        body = response.text[:200].replace(device_key, "••••").strip()
        return body or "空响应"

    @classmethod
    def _validate_business_response(cls, response: httpx.Response, device_key: str) -> None:
        try:
            payload = response.json()
        except ValueError:
            raise ValueError("Bark 返回无法解析的业务响应") from None
        if not isinstance(payload, dict):
            raise ValueError("Bark 返回无效的业务响应")
        raw_code = payload.get("code", payload.get("status"))
        try:
            code = int(raw_code)
        except (TypeError, ValueError):
            code = None
        if code == 200 or (code is None and payload.get("success") is True):
            return
        message = str(payload.get("message") or payload.get("error") or "业务请求未被接受")
        message = message[:160].replace(device_key, "••••")
        raise ValueError(f"Bark 业务响应失败：{message}")
