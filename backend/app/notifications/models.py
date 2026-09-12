from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator


NotificationEventType = Literal[
    "subscription_metadata_bound",
    "subscription_new_resource",
    "subscription_refresh_failed",
    "download_started",
    "download_batch_summary",
    "download_completed",
    "download_failed",
    "organize_completed",
    "organize_failed",
    "organize_needs_review",
    "brush_task_added",
    "brush_task_deleted",
    "brush_error",
]


class BarkNotificationSettings(BaseModel):
    enabled: bool = False
    server_url: str = "https://api.day.app"
    device_key: str | None = None
    clear_device_key: bool = False
    group: str = "Kisetsu"
    sound: str | None = None
    icon: str | None = None
    level: Literal["active", "timeSensitive", "passive"] = "active"
    url: str | None = None
    auto_copy: bool = False

    @field_validator("server_url")
    @classmethod
    def normalize_server_url(cls, value: str) -> str:
        cleaned = (value or "").strip().rstrip("/")
        return cleaned or "https://api.day.app"


class NotificationEventSettings(BaseModel):
    subscription: bool = True
    download: bool = True
    organize: bool = True


class NotificationSettings(BaseModel):
    enabled: bool = False
    bark: BarkNotificationSettings = Field(default_factory=BarkNotificationSettings)
    events: NotificationEventSettings = Field(default_factory=NotificationEventSettings)
    show_full_paths: bool = False


class BarkNotificationSettingsResponse(BaseModel):
    enabled: bool = False
    server_url: str = "https://api.day.app"
    has_device_key: bool = False
    masked_device_key: str | None = None
    group: str = "Kisetsu"
    sound: str | None = None
    icon: str | None = None
    level: Literal["active", "timeSensitive", "passive"] = "active"
    url: str | None = None
    auto_copy: bool = False


class NotificationSettingsResponse(BaseModel):
    enabled: bool = False
    bark: BarkNotificationSettingsResponse = Field(default_factory=BarkNotificationSettingsResponse)
    events: NotificationEventSettings = Field(default_factory=NotificationEventSettings)
    show_full_paths: bool = False
    has_bark_device_key: bool = False
    masked_bark_device_key: str | None = None
    message: str = "通知未启用"


class NotificationEvent(BaseModel):
    event_key: str
    event_type: NotificationEventType
    title: str
    body: str
    anime_title: str | None = None
    poster_url: str | None = None
    url: str | None = None
    subscription_id: int | None = None
    download_record_id: int | None = None
    organize_record_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None
    episode_title: str | None = None
    resource_title: str | None = None
    torrent_title: str | None = None
    size_bytes: int | None = Field(default=None, ge=0)
    download_source: str | None = None
    site_name: str | None = None
    downloader_type: str | None = None
    organized_file_name: str | None = None
    error_message: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class NotificationTestRequest(BaseModel):
    provider: Literal["bark"] = "bark"
    title: str | None = None
    body: str | None = None


class NotificationTestResponse(BaseModel):
    ok: bool
    provider: str = "bark"
    message: str
