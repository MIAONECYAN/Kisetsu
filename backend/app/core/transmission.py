from __future__ import annotations

import base64
import math
from typing import Any, Iterable
from urllib.parse import urlparse

import httpx

from app.core.downloader import DownloaderAddResult, DownloaderTask, downloader_url_bypasses_proxy, normalize_transfer_counter
from app.models import TransmissionConfig


class TransmissionError(RuntimeError):
    pass


def normalize_transmission_url(value: str) -> tuple[str, str]:
    cleaned = (value or "").strip()
    if not cleaned:
        cleaned = "http://127.0.0.1:9091"
    if "://" not in cleaned:
        cleaned = f"http://{cleaned}"
    parsed = urlparse(cleaned)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise TransmissionError("Transmission RPC 地址无效")
    path = parsed.path.rstrip("/")
    if not path:
        path = "/transmission/rpc"
    elif not path.endswith("/transmission/rpc"):
        path = f"{path}/transmission/rpc"
    base_url = f"{parsed.scheme}://{parsed.netloc}"
    return base_url, path


def describe_transmission_error(exc: BaseException) -> str:
    if isinstance(exc, TransmissionError):
        return str(exc) or "Transmission 操作失败"
    if isinstance(exc, httpx.TimeoutException):
        return "连接 Transmission 超时，请检查地址、端口或网络。"
    if isinstance(exc, httpx.ConnectError):
        return "无法连接 Transmission，请检查地址和端口。"
    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status in {401, 403}:
            return "Transmission 认证失败，请检查用户名和密码。"
        if status == 404:
            return "Transmission RPC 地址不正确。"
        return f"Transmission 返回 HTTP {status}，请检查服务状态。"
    if isinstance(exc, httpx.RequestError):
        return "Transmission 网络请求失败，请检查地址、端口和代理设置。"
    return "Transmission 操作失败，请检查服务状态后重试。"


class TransmissionClient:
    downloader_type = "transmission"
    TORRENT_FIELDS = [
        "id", "hashString", "name", "status", "percentDone", "rateDownload", "rateUpload",
        "eta", "downloadDir", "totalSize", "downloadedEver", "uploadedEver", "uploadRatio",
        "secondsSeeding", "files", "fileStats", "labels", "peersConnected", "peersSendingToUs", "peersGettingFromUs",
    ]

    def __init__(self, config: TransmissionConfig, client: httpx.AsyncClient | None = None):
        self.config = config
        self.base_url, self.rpc_path = normalize_transmission_url(config.base_url)
        self._external_client = client
        self._session_id: str | None = None

    async def _client(self) -> httpx.AsyncClient:
        if self._external_client is not None:
            return self._external_client
        auth = httpx.BasicAuth(self.config.username, self.config.password) if self.config.username or self.config.password else None
        return httpx.AsyncClient(
            base_url=self.base_url,
            auth=auth,
            timeout=15,
            trust_env=not downloader_url_bypasses_proxy(self.base_url),
        )

    async def _rpc(self, method: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        client = await self._client()
        close_client = self._external_client is None
        try:
            headers = {"X-Transmission-Session-Id": self._session_id} if self._session_id else {}
            response = await client.post(self.rpc_path, json={"method": method, "arguments": arguments or {}}, headers=headers)
            if response.status_code == 409:
                session_id = response.headers.get("X-Transmission-Session-Id")
                if not session_id:
                    raise TransmissionError("Transmission 会话协商失败：响应缺少 Session ID。")
                self._session_id = session_id
                response = await client.post(
                    self.rpc_path,
                    json={"method": method, "arguments": arguments or {}},
                    headers={"X-Transmission-Session-Id": session_id},
                )
                if response.status_code == 409:
                    raise TransmissionError("Transmission 会话协商失败，请检查反向代理或 RPC 设置。")
            response.raise_for_status()
            try:
                payload = response.json()
            except ValueError as exc:
                raise TransmissionError("Transmission 返回的 RPC 数据无法解析。") from exc
            if not isinstance(payload, dict):
                raise TransmissionError("Transmission 返回的 RPC 数据格式无效。")
            result = str(payload.get("result") or "")
            if result != "success":
                lowered = result.casefold()
                if "unauthorized" in lowered or "authentication" in lowered:
                    raise TransmissionError("Transmission 认证失败，请检查用户名和密码。")
                raise TransmissionError(f"Transmission RPC 调用失败：{result or '未知错误'}")
            output = payload.get("arguments") or {}
            return output if isinstance(output, dict) else {}
        finally:
            if close_client:
                await client.aclose()

    async def session_info(self) -> dict[str, Any]:
        return await self._rpc("session-get")

    async def test_connection(self) -> str:
        info = await self.session_info()
        return str(info.get("version") or info.get("rpc-version") or "未知")

    @staticmethod
    def _state(status: int, progress: float = 0) -> str:
        if status == 0:
            return "pausedUP" if progress >= 0.999 else "pausedDL"
        return {
            1: "checkingUP",
            2: "checkingUP",
            3: "queuedDL",
            4: "downloading",
            5: "queuedUP",
            6: "uploading",
        }.get(status, "unknown")

    @classmethod
    def _task(cls, item: dict[str, Any]) -> DownloaderTask:
        raw_files = item.get("files") if isinstance(item.get("files"), list) else []
        raw_file_stats = item.get("fileStats") if isinstance(item.get("fileStats"), list) else []
        files = [
            {
                "name": str(file.get("name") or ""),
                "size": int(file.get("length") or 0),
                "progress": (int(file.get("bytesCompleted") or 0) / int(file.get("length") or 1)),
                "wanted": bool(raw_file_stats[index].get("wanted", True))
                if index < len(raw_file_stats) and isinstance(raw_file_stats[index], dict)
                else True,
                "priority": int(raw_file_stats[index].get("priority") or 0)
                if index < len(raw_file_stats) and isinstance(raw_file_stats[index], dict)
                else 0,
            }
            for index, file in enumerate(raw_files)
            if isinstance(file, dict)
        ]
        tags = [str(value) for value in (item.get("labels") or []) if str(value).strip()]
        return DownloaderTask(
            downloader_type="transmission",
            remote_id=str(item.get("id")) if item.get("id") is not None else None,
            torrent_hash=str(item.get("hashString") or "") or None,
            name=str(item.get("name") or "") or None,
            state=cls._state(int(item.get("status") or 0), float(item.get("percentDone") or 0)),
            progress=float(item.get("percentDone") or 0),
            download_speed=int(item.get("rateDownload") or 0),
            upload_speed=int(item.get("rateUpload") or 0),
            eta=int(item.get("eta")) if item.get("eta") is not None else None,
            ratio=float(item.get("uploadRatio") or 0),
            seeding_time=int(item.get("secondsSeeding") or 0),
            downloaded=int(item.get("downloadedEver") or 0),
            uploaded=int(item.get("uploadedEver") or 0),
            total_size=int(item.get("totalSize") or 0),
            save_path=str(item.get("downloadDir") or "") or None,
            tags=tags,
            files=files,
            raw={
                "num_seeds": int(item.get("peersSendingToUs") or 0),
                "num_leechs": int(item.get("peersGettingFromUs") or 0),
            },
        )

    async def list_torrents(self, *, tag: str | None = None) -> list[dict[str, Any]]:
        payload = await self._rpc("torrent-get", {"fields": self.TORRENT_FIELDS})
        rows = payload.get("torrents") or []
        tasks = [self._task(item) for item in rows if isinstance(item, dict)]
        if tag:
            tasks = [task for task in tasks if tag in task.tags]
        return [task.as_legacy_dict() for task in tasks]

    async def _add(self, arguments: dict[str, Any], tags: Iterable[str]) -> DownloaderAddResult:
        labels = [str(tag).strip() for tag in tags if str(tag).strip()]
        if labels:
            arguments["labels"] = labels
        try:
            payload = await self._rpc("torrent-add", arguments)
        except TransmissionError as exc:
            if labels and "invalid argument" in str(exc).casefold():
                arguments.pop("labels", None)
                payload = await self._rpc("torrent-add", arguments)
            else:
                raise
        duplicate = isinstance(payload.get("torrent-duplicate"), dict)
        item = payload.get("torrent-added") or payload.get("torrent-duplicate") or {}
        if not isinstance(item, dict):
            raise TransmissionError("Transmission 未返回新增任务标识。")
        remote_id = str(item.get("id")) if item.get("id") is not None else None
        torrent_hash = str(item.get("hashString") or "").casefold() or None
        if remote_id is None and torrent_hash is None:
            raise TransmissionError("Transmission 未返回新增任务标识。")
        return DownloaderAddResult(
            downloader_type="transmission",
            remote_task_id=remote_id,
            torrent_hash=torrent_hash,
            torrent_name=str(item.get("name") or "") or None,
            duplicate=duplicate,
        )

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
        if not url:
            raise TransmissionError("下载地址为空")
        arguments: dict[str, Any] = {"filename": url, "paused": paused}
        target = save_path or self.config.default_save_path
        if target:
            arguments["download-dir"] = target
        return await self._add(arguments, tags or self.config.default_labels)

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
            raise TransmissionError("种子文件内容为空")
        arguments: dict[str, Any] = {"metainfo": base64.b64encode(content).decode("ascii"), "paused": paused}
        target = save_path or self.config.default_save_path
        if target:
            arguments["download-dir"] = target
        result = await self._add(arguments, tags or self.config.default_labels)
        if result.task_identifier and (upload_limit or download_limit):
            limits: dict[str, Any] = {"ids": [result.task_identifier]}
            if upload_limit:
                limits.update({"uploadLimited": True, "uploadLimit": math.ceil(upload_limit / 1000)})
            if download_limit:
                limits.update({"downloadLimited": True, "downloadLimit": math.ceil(download_limit / 1000)})
            await self._rpc("torrent-set", limits)
        return result

    async def task_by_identity(self, result: DownloaderAddResult) -> dict[str, Any] | None:
        identifier: int | str | None = None
        if result.remote_task_id and result.remote_task_id.isdigit():
            identifier = int(result.remote_task_id)
        elif result.torrent_hash:
            identifier = result.torrent_hash
        if identifier is None:
            return None
        payload = await self._rpc("torrent-get", {"ids": [identifier], "fields": self.TORRENT_FIELDS})
        rows = payload.get("torrents") or []
        if len(rows) != 1 or not isinstance(rows[0], dict):
            return None
        return self._task(rows[0]).as_legacy_dict()

    async def torrent_files(self, torrent_id: str) -> list[dict[str, Any]]:
        payload = await self._rpc("torrent-get", {"ids": [torrent_id], "fields": ["files", "fileStats"]})
        rows = payload.get("torrents") or []
        if not rows:
            return []
        task = self._task(rows[0])
        return task.files

    async def _action(self, method: str, torrent_ids: Iterable[str], **arguments: Any) -> None:
        ids = [int(value) if str(value).isdigit() else value for value in torrent_ids if value]
        if not ids:
            raise TransmissionError("未找到可管理的 Transmission 任务")
        await self._rpc(method, {"ids": ids, **arguments})

    async def pause_torrents(self, torrent_ids: Iterable[str]) -> None:
        await self._action("torrent-stop", torrent_ids)

    async def resume_torrents(self, torrent_ids: Iterable[str]) -> None:
        await self._action("torrent-start", torrent_ids)

    async def delete_torrents(self, torrent_ids: Iterable[str], *, delete_files: bool = False) -> None:
        await self._action("torrent-remove", torrent_ids, **{"delete-local-data": delete_files})

    async def reannounce_torrents(self, torrent_ids: Iterable[str]) -> None:
        await self._action("torrent-reannounce", torrent_ids)

    async def transfer_info(self) -> dict[str, Any]:
        payload = await self._rpc("session-stats")
        cumulative = payload.get("cumulative-stats")
        if not isinstance(cumulative, dict):
            cumulative = {}
        try:
            downloaded_bytes = normalize_transfer_counter(cumulative.get("downloadedBytes"))
            uploaded_bytes = normalize_transfer_counter(cumulative.get("uploadedBytes"))
        except (TypeError, ValueError) as exc:
            raise TransmissionError("Transmission 返回的累计流量格式无效") from exc
        return {
            "dl_info_speed": int(payload.get("downloadSpeed") or 0),
            "up_info_speed": int(payload.get("uploadSpeed") or 0),
            "download_speed": max(0, int(payload.get("downloadSpeed") or 0)),
            "upload_speed": max(0, int(payload.get("uploadSpeed") or 0)),
            "downloaded_bytes": downloaded_bytes,
            "uploaded_bytes": uploaded_bytes,
        }

    async def global_limits(self) -> dict[str, int]:
        info = await self.session_info()
        return {
            "download_limit": int(info.get("speed-limit-down") or 0) * 1000 if info.get("speed-limit-down-enabled") else 0,
            "upload_limit": int(info.get("speed-limit-up") or 0) * 1000 if info.get("speed-limit-up-enabled") else 0,
        }

    async def set_global_limits(self, *, download_limit: int, upload_limit: int) -> dict[str, int]:
        if download_limit < 0 or upload_limit < 0:
            raise TransmissionError("Transmission 全局限速不能为负数")
        await self._rpc(
            "session-set",
            {
                "speed-limit-down-enabled": download_limit > 0,
                "speed-limit-down": max(0, math.ceil(download_limit / 1000)),
                "speed-limit-up-enabled": upload_limit > 0,
                "speed-limit-up": max(0, math.ceil(upload_limit / 1000)),
            },
        )
        return await self.global_limits()
