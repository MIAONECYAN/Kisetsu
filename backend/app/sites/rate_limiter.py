from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import logging
import random
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

import httpx

logger = logging.getLogger("kisetsu.site_rate_limiter")

GLOBAL_MAX_CONCURRENT_SITE_REQUESTS = 4


@dataclass(frozen=True)
class SiteRateLimitPolicy:
    min_interval_ms: int = 1500
    jitter_ms: int = 400
    max_concurrent_requests: int = 1
    timeout_seconds: float = 15
    backoff_seconds: float = 8
    max_retries: int = 1


DEFAULT_SITE_RATE_LIMIT_POLICY = SiteRateLimitPolicy()
SITE_RATE_LIMIT_POLICIES: dict[str, SiteRateLimitPolicy] = {
    "dmhy": SiteRateLimitPolicy(min_interval_ms=3500, jitter_ms=1500, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=8, max_retries=1),
    "mikan": SiteRateLimitPolicy(min_interval_ms=1500, jitter_ms=600, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=8, max_retries=1),
    "nyaa": SiteRateLimitPolicy(min_interval_ms=1500, jitter_ms=600, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=8, max_retries=1),
    "mteam": SiteRateLimitPolicy(min_interval_ms=2500, jitter_ms=900, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=10, max_retries=1),
    "soulvoice": SiteRateLimitPolicy(min_interval_ms=3000, jitter_ms=1200, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=12, max_retries=1),
    "hddolby": SiteRateLimitPolicy(min_interval_ms=2500, jitter_ms=900, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=10, max_retries=1),
    "opencd": SiteRateLimitPolicy(min_interval_ms=2000, jitter_ms=900, max_concurrent_requests=1, timeout_seconds=15, backoff_seconds=12, max_retries=1),
}


def rate_limit_policy_for_site(site_id: str) -> SiteRateLimitPolicy:
    return SITE_RATE_LIMIT_POLICIES.get(site_id, DEFAULT_SITE_RATE_LIMIT_POLICY)


@dataclass
class SiteRateLimitEvent:
    site_id: str
    url: str
    rate_limiter_key: str
    wait_ms: int
    jitter_ms: int
    status_code: int | None
    duration_ms: int | None
    action: str
    message: str
    started_at: str | None = None


def sanitized_url(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


class SiteRateLimiter:
    def __init__(self, *, global_max_concurrent: int = GLOBAL_MAX_CONCURRENT_SITE_REQUESTS) -> None:
        self._global_semaphore = asyncio.Semaphore(global_max_concurrent)
        self._site_semaphores: dict[str, asyncio.Semaphore] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        self._last_started_at: dict[str, float] = {}
        self._events: dict[str, deque[SiteRateLimitEvent]] = defaultdict(lambda: deque(maxlen=200))
        self._guard = asyncio.Lock()

    async def _site_semaphore(self, key: str, max_concurrent: int) -> asyncio.Semaphore:
        async with self._guard:
            if key not in self._site_semaphores:
                self._site_semaphores[key] = asyncio.Semaphore(max(1, max_concurrent))
            if key not in self._locks:
                self._locks[key] = asyncio.Lock()
            return self._site_semaphores[key]

    async def wait_for_slot(self, site_id: str, url: str, policy: SiteRateLimitPolicy) -> tuple[str, int, int]:
        domain = urlsplit(url).netloc or site_id
        key = f"{site_id}:{domain}"
        semaphore = await self._site_semaphore(key, policy.max_concurrent_requests)
        global_acquired = False
        site_acquired = False
        try:
            await self._global_semaphore.acquire()
            global_acquired = True
            await semaphore.acquire()
            site_acquired = True
            jitter_ms = random.randint(0, max(0, policy.jitter_ms)) if policy.jitter_ms > 0 else 0
            wait_ms = 0
            async with self._locks[key]:
                now = time.monotonic()
                last_started = self._last_started_at.get(key)
                if last_started is not None:
                    elapsed_ms = int((now - last_started) * 1000)
                    wait_ms = max(0, policy.min_interval_ms - elapsed_ms) + jitter_ms
                self._record(
                    SiteRateLimitEvent(
                        site_id=site_id,
                        url=sanitized_url(url),
                        rate_limiter_key=key,
                        wait_ms=wait_ms,
                        jitter_ms=jitter_ms,
                        status_code=None,
                        duration_ms=None,
                        action="wait",
                        message=f"{site_id} 已自动控制请求速度：进入统一限速队列，等待 {wait_ms} ms",
                    )
                )
                if wait_ms > 0:
                    await asyncio.sleep(wait_ms / 1000)
                self._last_started_at[key] = time.monotonic()
            return key, wait_ms, jitter_ms
        except BaseException:
            # asyncio.CancelledError inherits from BaseException. A page-level
            # timeout may cancel this coroutine while it is waiting for the
            # site slot or spacing sleep, so release only the slots acquired.
            if site_acquired:
                semaphore.release()
            if global_acquired:
                self._global_semaphore.release()
            raise

    async def release_slot(self, key: str) -> None:
        semaphore = self._site_semaphores[key]
        semaphore.release()
        self._global_semaphore.release()

    async def backoff(self, site_id: str, url: str, policy: SiteRateLimitPolicy, *, reason: str) -> None:
        domain = urlsplit(url).netloc or site_id
        key = f"{site_id}:{domain}"
        wait_ms = int(policy.backoff_seconds * 1000)
        self._record(
            SiteRateLimitEvent(
                site_id=site_id,
                url=sanitized_url(url),
                rate_limiter_key=key,
                wait_ms=wait_ms,
                jitter_ms=0,
                status_code=None,
                duration_ms=None,
                action="backoff",
                message=f"{site_id} 触发访问保护，暂停 {wait_ms} ms 后重试：{reason}",
            )
        )
        await asyncio.sleep(policy.backoff_seconds)

    def _record(self, event: SiteRateLimitEvent) -> None:
        self._events[event.site_id].append(event)
        logger.debug(
            "site request %s site_id=%s key=%s url=%s started_at=%s wait_ms=%s jitter_ms=%s status_code=%s duration_ms=%s",
            event.action,
            event.site_id,
            event.rate_limiter_key,
            event.url,
            event.started_at,
            event.wait_ms,
            event.jitter_ms,
            event.status_code,
            event.duration_ms,
        )

    def record_response(
        self,
        *,
        site_id: str,
        url: str,
        key: str,
        wait_ms: int,
        jitter_ms: int,
        status_code: int | None,
        duration_ms: int,
        started_at: str,
    ) -> None:
        self._record(
            SiteRateLimitEvent(
                site_id=site_id,
                url=sanitized_url(url),
                rate_limiter_key=key,
                wait_ms=wait_ms,
                jitter_ms=jitter_ms,
                status_code=status_code,
                duration_ms=duration_ms,
                action="response",
                message=f"{site_id} 请求完成：HTTP {status_code or '-'}，耗时 {duration_ms} ms",
                started_at=started_at,
            )
        )

    def drain_events(self, site_id: str) -> list[SiteRateLimitEvent]:
        events = list(self._events.get(site_id, []))
        self._events[site_id].clear()
        return events


site_rate_limiter = SiteRateLimiter()


class RateLimitedHttpClient:
    def __init__(self, limiter: SiteRateLimiter | None = None) -> None:
        self.limiter = limiter or site_rate_limiter

    async def request(
        self,
        site_id: str,
        url: str,
        policy: SiteRateLimitPolicy,
        *,
        method: str = "GET",
        headers: dict[str, str] | None = None,
        params: dict | None = None,
        data: dict | None = None,
        json: dict | None = None,
        timeout: float | None = None,
        raise_for_status: bool = True,
    ) -> httpx.Response:
        headers = headers or {
            "User-Agent": "Mozilla/5.0 Kisetsu/0.1 local client",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
        }
        last_status_error: httpx.HTTPStatusError | None = None
        for attempt in range(policy.max_retries + 1):
            key, wait_ms, jitter_ms = await self.limiter.wait_for_slot(site_id, url, policy)
            started_at = datetime.now(timezone.utc).isoformat()
            started = time.monotonic()
            status_code: int | None = None
            should_backoff = False
            try:
                async with httpx.AsyncClient(headers=headers, timeout=timeout or policy.timeout_seconds, follow_redirects=True) as client:
                    request_kwargs = {}
                    if params is not None:
                        request_kwargs["params"] = params
                    if data is not None:
                        request_kwargs["data"] = data
                    if json is not None:
                        request_kwargs["json"] = json
                    response = await client.request(method, url, **request_kwargs)
                    status_code = response.status_code
                    if raise_for_status:
                        response.raise_for_status()
                    if status_code in {403, 429} and attempt < policy.max_retries:
                        should_backoff = True
                    else:
                        return response
            except httpx.HTTPStatusError as exc:
                status_code = exc.response.status_code
                if status_code in {403, 429} and attempt < policy.max_retries:
                    last_status_error = exc
                    should_backoff = True
                else:
                    raise
            finally:
                duration_ms = int((time.monotonic() - started) * 1000)
                self.limiter.record_response(
                    site_id=site_id,
                    url=url,
                    key=key,
                    wait_ms=wait_ms,
                    jitter_ms=jitter_ms,
                    status_code=status_code,
                    duration_ms=duration_ms,
                    started_at=started_at,
                )
                await self.limiter.release_slot(key)
            if should_backoff:
                await self.limiter.backoff(site_id, url, policy, reason=f"HTTP {status_code}")
                continue
        if last_status_error is not None:
            raise last_status_error
        raise RuntimeError("站点请求失败，请稍后重试。")

    async def fetch_text(self, site_id: str, url: str, policy: SiteRateLimitPolicy, headers: dict[str, str] | None = None) -> str:
        response = await self.request(site_id, url, policy, headers=headers)
        return response.text


def drain_rate_limit_events(site_id: str) -> list[SiteRateLimitEvent]:
    return site_rate_limiter.drain_events(site_id)
