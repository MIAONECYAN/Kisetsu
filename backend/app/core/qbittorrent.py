from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import re
from contextlib import asynccontextmanager
from typing import Any, Iterable
from urllib.parse import parse_qs, urlparse
from weakref import WeakSet

import httpx

from app.core.downloader import DownloaderAddResult, downloader_url_bypasses_proxy, normalize_transfer_counter
from app.models import QbittorrentConfig


class QbittorrentError(RuntimeError):
    pass


def _btih_hash(value: str) -> str | None:
    parsed = urlparse(value)
    candidates = [
        item.split(":")[-1]
        for item in parse_qs(parsed.query).get("xt", [])
        if item.casefold().startswith("urn:btih:")
    ]
    match = re.search(r"(?i)btih[:=]([a-z2-7]{32}|[a-f0-9]{40})", value)
    if match:
        candidates.append(match.group(1))
    path_match = re.search(r"/([a-f0-9]{40})(?:\.torrent)?(?:$|[/?#])", parsed.path, re.IGNORECASE)
    if path_match:
        candidates.append(path_match.group(1))
    for candidate in candidates:
        normalized = candidate.strip().casefold()
        if re.fullmatch(r"[a-f0-9]{40}", normalized):
            return normalized
        if re.fullmatch(r"[a-z2-7]{32}", normalized):
            try:
                return base64.b32decode(normalized.upper()).hex()
            except (binascii.Error, ValueError):
                continue
    return None


def _bencode_bytes(data: bytes, index: int) -> tuple[bytes, int]:
    colon = data.find(b":", index)
    if colon < 0 or not data[index:colon].isdigit():
        raise ValueError("invalid bencoded byte string")
    length = int(data[index:colon])
    start = colon + 1
    end = start + length
    if end > len(data):
        raise ValueError("truncated bencoded byte string")
    return data[start:end], end


def _bencode_skip(data: bytes, index: int) -> int:
    if index >= len(data):
        raise ValueError("truncated bencode value")
    token = data[index:index + 1]
    if token == b"i":
        end = data.find(b"e", index + 1)
        if end < 0:
            raise ValueError("truncated bencode integer")
        int(data[index + 1:end])
        return end + 1
    if token in {b"l", b"d"}:
        cursor = index + 1
        while cursor < len(data) and data[cursor:cursor + 1] != b"e":
            if token == b"d":
                _, cursor = _bencode_bytes(data, cursor)
            cursor = _bencode_skip(data, cursor)
        if cursor >= len(data):
            raise ValueError("truncated bencode collection")
        return cursor + 1
    if token.isdigit():
        _, end = _bencode_bytes(data, index)
        return end
    raise ValueError("invalid bencode token")


def torrent_info_hash(content: bytes) -> str | None:
    try:
        if not content.startswith(b"d"):
            return None
        cursor = 1
        while cursor < len(content) and content[cursor:cursor + 1] != b"e":
            key, cursor = _bencode_bytes(content, cursor)
            value_start = cursor
            cursor = _bencode_skip(content, cursor)
            if key == b"info":
                return hashlib.sha1(content[value_start:cursor]).hexdigest()
    except (TypeError, ValueError):
        return None
    return None


def describe_qbittorrent_error(exc: BaseException) -> str:
    if isinstance(exc, QbittorrentError):
        return str(exc) or "qBittorrent 操作失败"
    if isinstance(exc, httpx.TimeoutException):
        return "连接 qBittorrent 超时，请检查地址、端口或网络。"
    if isinstance(exc, httpx.ConnectError):
        return "无法连接 qBittorrent，请检查地址和端口。"
    if isinstance(exc, httpx.HTTPStatusError):
        status_code = exc.response.status_code
        if status_code in {401, 403}:
            return "qBittorrent 认证失败，请检查用户名和密码。"
        if status_code == 404:
            return "qBittorrent API 地址不正确，请检查基础 URL。"
        return f"qBittorrent 返回 HTTP {status_code}，请检查服务状态。"
    if isinstance(exc, httpx.RequestError):
        return "qBittorrent 网络请求失败，请检查地址、端口和代理设置。"
    return "qBittorrent 操作失败，请检查服务状态后重试。"


class QbittorrentClient:
    downloader_type = "qbittorrent"

    def __init__(self, config: QbittorrentConfig, client: httpx.AsyncClient | None = None):
        self.config = config
        self._external_client = client
        self._submission_client: httpx.AsyncClient | None = None
        self._authenticated_clients: WeakSet[httpx.AsyncClient] = WeakSet()
        self._api_major_version: int | None = None
        self._version_checked = False

    async def _client(self) -> httpx.AsyncClient:
        if self._external_client is not None:
            return self._external_client
        if self._submission_client is not None:
            return self._submission_client
        return httpx.AsyncClient(
            base_url=self.config.base_url.rstrip("/"),
            timeout=15,
            trust_env=not downloader_url_bypasses_proxy(self.config.base_url),
        )

    def _is_one_shot_client(self) -> bool:
        return self._external_client is None and self._submission_client is None

    @asynccontextmanager
    async def submission_session(self):
        if self._external_client is not None or self._submission_client is not None:
            yield self
            return
        client = httpx.AsyncClient(
            base_url=self.config.base_url.rstrip("/"),
            timeout=15,
            trust_env=not downloader_url_bypasses_proxy(self.config.base_url),
        )
        self._submission_client = client
        try:
            yield self
        finally:
            self._authenticated_clients.discard(client)
            self._submission_client = None
            await client.aclose()

    async def login(self, client: httpx.AsyncClient) -> None:
        if client in self._authenticated_clients:
            return
        response = await client.post(
            "/api/v2/auth/login",
            data={"username": self.config.username, "password": self.config.password},
        )
        response.raise_for_status()
        # qBittorrent returns 204 without a SID when localhost authentication
        # bypass is active. The following API request still verifies access.
        if response.status_code == 204:
            self._authenticated_clients.add(client)
            return
        if response.text.strip().lower() not in {"ok.", "ok"}:
            raise QbittorrentError("qBittorrent 认证失败")
        self._authenticated_clients.add(client)

    @staticmethod
    def _response_type(response: httpx.Response) -> str:
        body = response.text.strip().casefold()
        if body in {"ok", "ok."}:
            return "ok"
        if body in {"fails", "fails."}:
            return "fails"
        if not body:
            return "empty"
        return "unexpected"

    @staticmethod
    def _request_error_type(exc: BaseException) -> str:
        if isinstance(exc, httpx.TimeoutException):
            return "timeout"
        if isinstance(exc, httpx.ConnectError):
            return "connect_error"
        if isinstance(exc, httpx.HTTPStatusError):
            status = exc.response.status_code
            if status == 429:
                return "http_429"
            if status >= 500:
                return "http_5xx"
            return f"http_{status}"
        return "request_error"

    async def test_connection(self) -> str:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            return await self._app_version(client)
        finally:
            if close_client:
                await client.aclose()

    async def add_url(
        self,
        url: str,
        *,
        save_path: str | None = None,
        category: str | None = None,
        tags: Iterable[str] = (),
        lookup_tag: str | None = None,
        paused: bool = False,
    ) -> DownloaderAddResult:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            known_hash = _btih_hash(url)
            existing = await self.find_torrent_by_hash(known_hash, client=client) if known_hash else None
            if existing is not None:
                return self._add_result(existing, duplicate=True)
            data = {
                "urls": url,
                "savepath": save_path or self.config.default_save_path or "",
                "category": category or self.config.default_category or "",
                "tags": ",".join(tags or self.config.default_tags),
                "paused": "true" if paused else "false",
            }
            response_error: BaseException | None = None
            response_type = "request_error"
            try:
                response = await client.post("/api/v2/torrents/add", data=data)
                if response.status_code in {401, 403}:
                    response.raise_for_status()
                response_type = self._response_type(response)
                if not response.is_success:
                    response.raise_for_status()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code in {401, 403}:
                    raise
                response_error = exc
            except httpx.RequestError as exc:
                response_error = exc
            if response_error is not None:
                response_type = self._request_error_type(response_error)

            torrent = await self._reconcile_added_torrent(
                client,
                torrent_hash=known_hash,
                lookup_tag=lookup_tag,
            )
            if torrent is not None:
                return self._add_result(torrent, response_type=response_type)
            return DownloaderAddResult(
                downloader_type="qbittorrent",
                torrent_hash=known_hash,
                confirmation_status="pending_confirmation",
                response_type=response_type,
            )
        finally:
            if close_client:
                await client.aclose()

    async def add_torrent_bytes(
        self,
        content: bytes,
        *,
        filename: str,
        save_path: str | None = None,
        category: str | None = None,
        tags: Iterable[str] = (),
        upload_limit: int | None = None,
        download_limit: int | None = None,
        automatic_management: bool = False,
        first_last_piece_priority: bool = False,
        lookup_tag: str | None = None,
        paused: bool = False,
    ) -> DownloaderAddResult:
        if not content:
            raise QbittorrentError("种子文件内容为空")
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            known_hash = torrent_info_hash(content)
            existing = await self.find_torrent_by_hash(known_hash, client=client) if known_hash else None
            if existing is not None:
                return self._add_result(existing, duplicate=True)
            data = {
                "savepath": save_path or self.config.default_save_path or "",
                "category": category or self.config.default_category or "",
                "tags": ",".join(tags or self.config.default_tags),
                "autoTMM": "true" if automatic_management else "false",
                "firstLastPiecePrio": "true" if first_last_piece_priority else "false",
                "paused": "true" if paused else "false",
            }
            if upload_limit:
                data["upLimit"] = str(upload_limit)
            if download_limit:
                data["dlLimit"] = str(download_limit)
            files = {
                "torrents": (
                    filename or "kisetsu.torrent",
                    content,
                    "application/x-bittorrent",
                )
            }
            response_error: BaseException | None = None
            response_type = "request_error"
            try:
                response = await client.post("/api/v2/torrents/add", data=data, files=files)
                if response.status_code in {401, 403}:
                    response.raise_for_status()
                response_type = self._response_type(response)
                if not response.is_success:
                    response.raise_for_status()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code in {401, 403}:
                    raise
                response_error = exc
            except httpx.RequestError as exc:
                response_error = exc
            if response_error is not None:
                response_type = self._request_error_type(response_error)

            torrent = await self._reconcile_added_torrent(
                client,
                torrent_hash=known_hash,
                lookup_tag=lookup_tag,
            )
            if torrent is not None:
                return self._add_result(torrent, response_type=response_type)
            return DownloaderAddResult(
                downloader_type="qbittorrent",
                torrent_hash=known_hash,
                confirmation_status="pending_confirmation",
                response_type=response_type,
            )
        finally:
            if close_client:
                await client.aclose()

    async def list_torrents(self, *, tag: str | None = None) -> list[dict[str, Any]]:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            params = {"tag": tag} if tag else None
            response = await client.get("/api/v2/torrents/info", params=params)
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, list):
                raise QbittorrentError("qBittorrent 返回的任务列表格式无效")
            return [item for item in payload if isinstance(item, dict)]
        finally:
            if close_client:
                await client.aclose()

    async def list_tags(self) -> set[str]:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            response = await client.get("/api/v2/torrents/tags")
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, list):
                raise QbittorrentError("qBittorrent 返回的标签列表格式无效")
            return {str(tag).strip() for tag in payload if str(tag).strip()}
        finally:
            if close_client:
                await client.aclose()

    async def remove_tags(self, hashes: Iterable[str], tags: Iterable[str]) -> None:
        await self._post_tag_action("/api/v2/torrents/removeTags", hashes=hashes, tags=tags)

    async def delete_tags(self, tags: Iterable[str]) -> None:
        await self._post_tag_action("/api/v2/torrents/deleteTags", tags=tags)

    async def _post_tag_action(
        self,
        path: str,
        *,
        tags: Iterable[str],
        hashes: Iterable[str] = (),
    ) -> None:
        tag_values = [value.strip() for value in tags if value and value.strip()]
        if not tag_values:
            return
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            data = {"tags": ",".join(tag_values)}
            hash_values = [value for value in hashes if value]
            if hash_values:
                data["hashes"] = "|".join(hash_values)
            response = await client.post(path, data=data)
            response.raise_for_status()
        finally:
            if close_client:
                await client.aclose()

    async def task_by_identity(self, result: DownloaderAddResult) -> dict[str, Any] | None:
        if not result.torrent_hash:
            return None
        expected = result.torrent_hash.casefold()
        matches = [
            item for item in await self.list_torrents()
            if str(item.get("hash") or "").casefold() == expected
        ]
        return matches[0] if len(matches) == 1 else None

    @staticmethod
    def _add_result(
        torrent: dict[str, Any],
        *,
        duplicate: bool = False,
        response_type: str | None = None,
    ) -> DownloaderAddResult:
        return DownloaderAddResult(
            downloader_type="qbittorrent",
            torrent_hash=str(torrent.get("hash") or "").casefold() or None,
            torrent_name=str(torrent.get("name") or "") or None,
            duplicate=duplicate,
            confirmation_status="reconciled" if duplicate else "added",
            response_type=response_type,
        )

    async def _reconcile_added_torrent(
        self,
        client: httpx.AsyncClient,
        *,
        torrent_hash: str | None,
        lookup_tag: str | None,
    ) -> dict[str, Any] | None:
        for attempt in range(3):
            torrent = await self.find_torrent_by_hash(torrent_hash, client=client) if torrent_hash else None
            if torrent is None and lookup_tag:
                torrent = await self.find_torrent_by_tag(lookup_tag, client=client, attempts=1)
            if torrent is not None:
                return torrent
            if attempt < 2:
                await asyncio.sleep(0.5 * (attempt + 1))
        return None

    async def find_torrent_by_hash(
        self,
        torrent_hash: str | None,
        *,
        client: httpx.AsyncClient | None = None,
    ) -> dict[str, Any] | None:
        if not torrent_hash:
            return None
        managed_client = client or await self._client()
        close_client = client is None and self._is_one_shot_client()
        try:
            if client is None:
                await self.login(managed_client)
            response = await managed_client.get("/api/v2/torrents/info", params={"hashes": torrent_hash})
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, list):
                raise QbittorrentError("qBittorrent 返回的任务列表格式无效")
            expected_hash = torrent_hash.casefold()
            matches = [
                item
                for item in payload
                if isinstance(item, dict)
                and str(item.get("hash") or "").casefold() == expected_hash
            ]
            if len(matches) > 1:
                raise QbittorrentError("同一 info hash 对应多个 qBittorrent 任务，已停止映射。")
            return matches[0] if len(matches) == 1 else None
        finally:
            if close_client:
                await managed_client.aclose()

    async def find_torrent_hash_by_tag(
        self,
        tag: str,
        *,
        client: httpx.AsyncClient | None = None,
        attempts: int = 3,
    ) -> str | None:
        torrent = await self.find_torrent_by_tag(tag, client=client, attempts=attempts)
        return str(torrent.get("hash") or "") or None if torrent else None

    async def find_torrent_by_tag(
        self,
        tag: str,
        *,
        client: httpx.AsyncClient | None = None,
        attempts: int = 3,
    ) -> dict[str, Any] | None:
        managed_client = client or await self._client()
        close_client = client is None and self._is_one_shot_client()
        try:
            if client is None:
                await self.login(managed_client)
            for attempt in range(max(1, attempts)):
                response = await managed_client.get("/api/v2/torrents/info", params={"tag": tag})
                response.raise_for_status()
                payload = response.json()
                if not isinstance(payload, list):
                    raise QbittorrentError("qBittorrent 返回的任务列表格式无效")
                matches = [item for item in payload if isinstance(item, dict) and item.get("hash")]
                if len(matches) == 1:
                    return matches[0]
                if len(matches) > 1:
                    raise QbittorrentError("刷流任务唯一标签对应多个 qBittorrent 任务，已停止映射。")
                if attempt + 1 < attempts:
                    await asyncio.sleep(0.3 * (attempt + 1))
            return None
        finally:
            if close_client:
                await managed_client.aclose()

    async def transfer_info(self) -> dict[str, Any]:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            response = await client.get("/api/v2/transfer/info")
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, dict):
                raise QbittorrentError("qBittorrent 返回的传输统计格式无效")
            try:
                downloaded_bytes = normalize_transfer_counter(payload.get("alltime_dl"))
                uploaded_bytes = normalize_transfer_counter(payload.get("alltime_ul"))
            except (TypeError, ValueError) as exc:
                raise QbittorrentError("qBittorrent 返回的累计流量格式无效") from exc
            return {
                **payload,
                "downloaded_bytes": downloaded_bytes,
                "uploaded_bytes": uploaded_bytes,
                "download_speed": max(0, int(payload.get("dl_info_speed") or 0)),
                "upload_speed": max(0, int(payload.get("up_info_speed") or 0)),
            }
        finally:
            if close_client:
                await client.aclose()

    async def global_limits(self) -> dict[str, int]:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            download_response, upload_response = await asyncio.gather(
                client.get("/api/v2/transfer/downloadLimit"),
                client.get("/api/v2/transfer/uploadLimit"),
            )
            download_response.raise_for_status()
            upload_response.raise_for_status()
            return {
                "download_limit": max(0, int(download_response.text.strip() or 0)),
                "upload_limit": max(0, int(upload_response.text.strip() or 0)),
            }
        except ValueError as exc:
            raise QbittorrentError("qBittorrent 返回的全局限速格式无效") from exc
        finally:
            if close_client:
                await client.aclose()

    async def set_global_limits(self, *, download_limit: int, upload_limit: int) -> dict[str, int]:
        if download_limit < 0 or upload_limit < 0:
            raise QbittorrentError("qBittorrent 全局限速不能为负数")
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            download_response = await client.post(
                "/api/v2/transfer/setDownloadLimit",
                data={"limit": str(download_limit)},
            )
            download_response.raise_for_status()
            upload_response = await client.post(
                "/api/v2/transfer/setUploadLimit",
                data={"limit": str(upload_limit)},
            )
            upload_response.raise_for_status()
        finally:
            if close_client:
                await client.aclose()
        return await self.global_limits()

    async def torrent_files(self, torrent_hash: str) -> list[dict[str, Any]]:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            response = await client.get("/api/v2/torrents/files", params={"hash": torrent_hash})
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, list):
                raise QbittorrentError("qBittorrent 返回的文件列表格式无效")
            return [item for item in payload if isinstance(item, dict)]
        finally:
            if close_client:
                await client.aclose()

    async def _app_version(self, client: httpx.AsyncClient) -> str:
        response = await client.get("/api/v2/app/version")
        response.raise_for_status()
        version = response.text.strip()
        match = re.match(r"v?(\d+)(?:\.|$)", version, re.IGNORECASE)
        self._api_major_version = int(match.group(1)) if match else None
        self._version_checked = True
        return version

    async def pause_torrents(self, hashes: Iterable[str]) -> None:
        await self._control_torrent_action("stop", "pause", hashes)

    async def resume_torrents(self, hashes: Iterable[str]) -> None:
        await self._control_torrent_action("start", "resume", hashes)

    async def delete_torrents(self, hashes: Iterable[str], *, delete_files: bool = False) -> None:
        await self._post_torrent_action(
            "/api/v2/torrents/delete",
            hashes,
            extra_data={"deleteFiles": "true" if delete_files else "false"},
        )

    async def ensure_permanent_file_deletion(self) -> None:
        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            response = await client.get("/api/v2/app/preferences")
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload, dict):
                raise QbittorrentError("qBittorrent 返回的删除设置格式无效")
            removal_mode = payload.get("torrent_content_remove_option")
            if removal_mode is not None:
                if str(removal_mode).strip().casefold() != "delete":
                    raise QbittorrentError(
                        "qBittorrent 当前会将文件移到回收站；请在 qBittorrent 高级设置中将“Torrent content removing mode”改为永久删除。"
                    )
                return
            version = await self._app_version(client)
            major_match = re.match(r"v?(\d+)(?:\.|$)", version, re.IGNORECASE)
            if major_match and int(major_match.group(1)) < 5:
                return
            raise QbittorrentError("无法确认 qBittorrent 是否会永久删除文件，已取消删除任务和文件。")
        finally:
            if close_client:
                await client.aclose()

    async def reannounce_torrents(self, hashes: Iterable[str]) -> None:
        await self._post_torrent_action("/api/v2/torrents/reannounce", hashes)

    async def _post_torrent_action(
        self,
        path: str,
        hashes: Iterable[str],
        *,
        extra_data: dict[str, str] | None = None,
    ) -> None:
        hash_values = [value for value in hashes if value]
        if not hash_values:
            raise QbittorrentError("未找到可管理的 qBittorrent 任务")

        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            data = {"hashes": "|".join(hash_values)}
            if extra_data:
                data.update(extra_data)
            response = await client.post(path, data=data)
            response.raise_for_status()
        finally:
            if close_client:
                await client.aclose()

    async def _control_torrent_action(
        self,
        modern_action: str,
        legacy_action: str,
        hashes: Iterable[str],
    ) -> None:
        hash_values = [value for value in hashes if value]
        if not hash_values:
            raise QbittorrentError("未找到可管理的 qBittorrent 任务")

        client = await self._client()
        close_client = self._is_one_shot_client()
        try:
            await self.login(client)
            if not self._version_checked:
                await self._app_version(client)

            if self._api_major_version is not None:
                action = modern_action if self._api_major_version >= 5 else legacy_action
                response = await client.post(
                    f"/api/v2/torrents/{action}",
                    data={"hashes": "|".join(hash_values)},
                )
                if response.status_code == 404:
                    raise QbittorrentError("当前 qBittorrent 版本不支持该任务控制接口。")
                response.raise_for_status()
                return

            modern_response = await client.post(
                f"/api/v2/torrents/{modern_action}",
                data={"hashes": "|".join(hash_values)},
            )
            if modern_response.status_code != 404:
                modern_response.raise_for_status()
                return

            legacy_response = await client.post(
                f"/api/v2/torrents/{legacy_action}",
                data={"hashes": "|".join(hash_values)},
            )
            if legacy_response.status_code == 404:
                raise QbittorrentError("当前 qBittorrent 版本不支持该任务控制接口。")
            legacy_response.raise_for_status()
        finally:
            if close_client:
                await client.aclose()
