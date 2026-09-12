from __future__ import annotations

from typing import Any

from app.core.downloader import DownloaderClient, DownloaderError
from app.core.qbittorrent import QbittorrentClient, describe_qbittorrent_error
from app.core.transmission import TransmissionClient, describe_transmission_error
from app.db import Store
from app.models import DownloaderRoutingSettings, QbittorrentConfig, TransmissionConfig


def stored_qbittorrent_config(store: Store) -> QbittorrentConfig | None:
    payload = store.get_runtime_config("qbittorrent")
    if not payload:
        return None
    data = dict(payload)
    data.pop("password_configured", None)
    data.pop("clear_password", None)
    return QbittorrentConfig(**data)


def stored_transmission_config(store: Store) -> TransmissionConfig | None:
    payload = store.get_runtime_config("transmission")
    if not payload:
        return None
    data = dict(payload)
    data.pop("password_configured", None)
    data.pop("clear_password", None)
    return TransmissionConfig(**data)


def stored_downloader_routing(store: Store) -> DownloaderRoutingSettings:
    payload = store.get_config("downloader_routing") or {}
    return DownloaderRoutingSettings(**payload)


def downloader_client(store: Store, downloader_type: str) -> DownloaderClient:
    if downloader_type == "qbittorrent":
        config = stored_qbittorrent_config(store)
        if config is None or not config.base_url or not config.username or not config.password:
            raise DownloaderError("qBittorrent 尚未配置")
        return QbittorrentClient(config)
    if downloader_type == "transmission":
        config = stored_transmission_config(store)
        if config is None or not config.base_url:
            raise DownloaderError("Transmission 尚未配置")
        return TransmissionClient(config)
    raise DownloaderError("未知下载器类型")


def downloader_configured(store: Store, downloader_type: str) -> bool:
    try:
        downloader_client(store, downloader_type)
        return True
    except DownloaderError:
        return False


def describe_downloader_error(downloader_type: str, exc: BaseException) -> str:
    if isinstance(exc, DownloaderError):
        return str(exc)
    if downloader_type == "transmission":
        return describe_transmission_error(exc)
    return describe_qbittorrent_error(exc)


def downloader_display_name(downloader_type: str) -> str:
    return "Transmission" if downloader_type == "transmission" else "qBittorrent"


def public_downloader_config(config: QbittorrentConfig | TransmissionConfig) -> dict[str, Any]:
    payload = config.model_dump(mode="json")
    payload["password_configured"] = bool(config.password)
    payload["password"] = ""
    payload["clear_password"] = False
    return payload


def merge_downloader_secret(
    incoming: QbittorrentConfig | TransmissionConfig,
    existing: QbittorrentConfig | TransmissionConfig | None,
) -> QbittorrentConfig | TransmissionConfig:
    payload = incoming.model_dump(mode="json")
    clear_password = bool(payload.pop("clear_password", False))
    payload.pop("password_configured", None)
    if clear_password:
        payload["password"] = ""
    elif not str(payload.get("password") or "") and existing is not None:
        payload["password"] = existing.password
    return type(incoming)(**payload)
