from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field
from typing import Any, Iterable, Protocol, runtime_checkable
from urllib.parse import urlparse


def normalize_transfer_counter(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError("boolean is not a transfer counter")
    if isinstance(value, float) and not value.is_integer():
        raise ValueError("fractional transfer counter")
    counter = int(value)
    if counter < 0:
        raise ValueError("negative transfer counter")
    return counter


def downloader_url_bypasses_proxy(value: str) -> bool:
    parsed = urlparse((value or "").strip())
    host = (parsed.hostname or "").strip().casefold()
    if not host:
        return False
    if host == "localhost" or host.endswith(".local") or "." not in host:
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


@dataclass(slots=True)
class DownloaderAddResult:
    downloader_type: str
    remote_task_id: str | None = None
    torrent_hash: str | None = None
    torrent_name: str | None = None
    content_size: int | None = None
    duplicate: bool = False
    confirmation_status: str = "added"
    response_type: str | None = None

    @property
    def task_identifier(self) -> str | None:
        return self.remote_task_id or self.torrent_hash

    @property
    def pending_confirmation(self) -> bool:
        return self.confirmation_status == "pending_confirmation"


@dataclass(slots=True)
class DownloaderTask:
    downloader_type: str
    remote_id: str | None = None
    torrent_hash: str | None = None
    name: str | None = None
    state: str | None = None
    progress: float | None = None
    download_speed: int = 0
    upload_speed: int = 0
    eta: int | None = None
    ratio: float = 0
    seeding_time: int = 0
    downloaded: int = 0
    uploaded: int = 0
    total_size: int = 0
    save_path: str | None = None
    tags: list[str] = field(default_factory=list)
    files: list[dict[str, Any]] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)

    def as_legacy_dict(self) -> dict[str, Any]:
        data = dict(self.raw)
        data.update(
            {
                "downloader_type": self.downloader_type,
                "remote_id": self.remote_id,
                "hash": self.torrent_hash,
                "name": self.name,
                "state": self.state,
                "progress": self.progress,
                "dlspeed": self.download_speed,
                "upspeed": self.upload_speed,
                "eta": self.eta,
                "ratio": self.ratio,
                "seeding_time": self.seeding_time,
                "downloaded": self.downloaded,
                "uploaded": self.uploaded,
                "total_size": self.total_size,
                "save_path": self.save_path,
                "tags": ",".join(self.tags),
                "files": self.files,
            }
        )
        return data


@runtime_checkable
class DownloaderClient(Protocol):
    downloader_type: str

    async def test_connection(self) -> str: ...

    async def add_url(
        self,
        url: str,
        *,
        save_path: str | None = None,
        category: str | None = None,
        tags: Iterable[str] = (),
        lookup_tag: str | None = None,
        paused: bool = False,
    ) -> DownloaderAddResult: ...

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
    ) -> DownloaderAddResult: ...

    async def list_torrents(self, *, tag: str | None = None) -> list[dict[str, Any]]: ...
    async def task_by_identity(self, result: DownloaderAddResult) -> dict[str, Any] | None: ...
    async def torrent_files(self, torrent_id: str) -> list[dict[str, Any]]: ...
    async def pause_torrents(self, torrent_ids: Iterable[str]) -> None: ...
    async def resume_torrents(self, torrent_ids: Iterable[str]) -> None: ...
    async def delete_torrents(self, torrent_ids: Iterable[str], *, delete_files: bool = False) -> None: ...
    async def transfer_info(self) -> dict[str, Any]: ...
    async def global_limits(self) -> dict[str, int]: ...
    async def set_global_limits(self, *, download_limit: int, upload_limit: int) -> dict[str, int]: ...


class DownloaderError(RuntimeError):
    pass
