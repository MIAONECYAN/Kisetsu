from __future__ import annotations

from datetime import datetime
from typing import Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, field_validator, model_validator


DEFAULT_BANGUMI_DATA_CDN = "https://unpkg.com/bangumi-data@0.3/dist/data.json"


def validated_http_url(value: str, *, label: str, allow_empty: bool = False) -> str:
    cleaned = value.strip().rstrip("/")
    if allow_empty and not cleaned:
        return ""
    parsed = urlparse(cleaned)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"{label}必须是有效的 HTTP 或 HTTPS 地址。")
    if parsed.username or parsed.password:
        raise ValueError(f"{label}不能包含用户名或密码。")
    if parsed.fragment:
        raise ValueError(f"{label}不能包含片段标识。")
    if any(segment in {".", ".."} for segment in parsed.path.split("/")):
        raise ValueError(f"{label}不能包含路径穿越片段。")
    if label.startswith("Plex") and (parsed.query or parsed.path not in {"", "/"}):
        raise ValueError(f"{label}只能填写服务器根地址。")
    return cleaned


class PlaylistSettingsUpdate(BaseModel):
    server_url: str = ""
    token: str | None = None
    clear_token: bool = False
    library_id: str | None = None
    cdn_url: str = DEFAULT_BANGUMI_DATA_CDN

    @model_validator(mode="after")
    def normalize(self) -> PlaylistSettingsUpdate:
        self.server_url = validated_http_url(self.server_url, label="Plex Server 地址", allow_empty=True)
        self.cdn_url = validated_http_url(self.cdn_url, label="bangumi-data CDN 地址")
        self.token = self.token.strip() if self.token and self.token.strip() else None
        self.library_id = self.library_id.strip() if self.library_id and self.library_id.strip() else None
        return self


class PlaylistSettingsResponse(BaseModel):
    server_url: str = ""
    token_configured: bool = False
    token_masked: str | None = None
    library_id: str | None = None
    library_title: str | None = None
    cdn_url: str = DEFAULT_BANGUMI_DATA_CDN


class PlexLibrary(BaseModel):
    id: str
    title: str
    type: str


class PlexConnectionResponse(BaseModel):
    ok: bool
    message: str
    version: str | None = None
    machine_identifier: str | None = None
    libraries: list[PlexLibrary] = Field(default_factory=list)


class PlaylistSiteLink(BaseModel):
    site: str
    title: str
    kind: Literal["info", "onair", "resource"]
    url: str


class PlaylistQuarterOption(BaseModel):
    year: int
    month: Literal[1, 4, 7, 10]
    count: int

    @property
    def id(self) -> str:
        return f"{self.year}-{self.month:02d}"


class PlexPairing(BaseModel):
    item_key: str
    plex_rating_key: str
    title: str
    year: int | None = None
    source: Literal["external_id", "title", "manual"]
    score: float = 0
    reason: str
    valid: bool = True
    updated_at: datetime | None = None


class PlaylistQuarterItem(BaseModel):
    key: str
    title: str
    original_title: str
    aliases: list[str] = Field(default_factory=list)
    media_type: str
    begin: datetime
    broadcast: str | None = None
    bangumi_id: str | None = None
    external_ids: dict[str, str] = Field(default_factory=dict)
    links: list[PlaylistSiteLink] = Field(default_factory=list)
    poster_url: str | None = None
    pairing: PlexPairing | None = None
    match_state: Literal["matched", "unmatched", "ambiguous", "stale"] = "unmatched"
    match_reason: str | None = None


class PlaylistQuarterResponse(BaseModel):
    year: int
    month: Literal[1, 4, 7, 10]
    title: str
    items: list[PlaylistQuarterItem] = Field(default_factory=list)
    cached_at: datetime
    source_version: str | None = None
    stale: bool = False
    warning: str | None = None
    attribution: str = "番组数据来源：bangumi-data（CC BY 4.0）"


class PlexShow(BaseModel):
    rating_key: str
    title: str
    original_title: str | None = None
    year: int | None = None
    library_id: str
    library_title: str | None = None
    guids: list[str] = Field(default_factory=list)
    season_count: int | None = None


class PlexEpisode(BaseModel):
    rating_key: str
    title: str
    season_number: int
    episode_number: int
    duration_ms: int | None = None
    playable: bool = True


class PlexSeason(BaseModel):
    rating_key: str
    title: str
    season_number: int
    episodes: list[PlexEpisode] = Field(default_factory=list)


class PlexShowHierarchy(BaseModel):
    show: PlexShow
    seasons: list[PlexSeason] = Field(default_factory=list)


class PairingRequest(BaseModel):
    item_key: str
    plex_rating_key: str


class PairingDeleteRequest(BaseModel):
    item_key: str


class PlexPlaylistSummary(BaseModel):
    rating_key: str
    title: str
    item_count: int = 0
    duration_ms: int | None = None
    updated_at: datetime | None = None
    poster_url: str | None = None
    artwork_path: str | None = Field(default=None, exclude=True, repr=False)


class PlexPlaylistItem(BaseModel):
    rating_key: str
    title: str
    show_title: str | None = None
    season_number: int | None = None
    episode_number: int | None = None
    duration_ms: int | None = None
    poster_url: str | None = None
    artwork_path: str | None = Field(default=None, exclude=True, repr=False)


class PlexPlaylistDetail(BaseModel):
    playlist: PlexPlaylistSummary
    items: list[PlexPlaylistItem] = Field(default_factory=list)


class PlaylistSelection(BaseModel):
    item_key: str
    episode_rating_key: str


class PlaylistCreatePreviewRequest(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    year: int
    month: Literal[1, 4, 7, 10]
    selections: list[PlaylistSelection] = Field(min_length=1, max_length=500)

    @field_validator("title")
    @classmethod
    def normalize_title(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("请输入播放列表名称。")
        return cleaned


class PlaylistCreatePreviewItem(BaseModel):
    item_key: str
    anime_title: str
    plex_show_title: str | None = None
    episode_rating_key: str | None = None
    season_number: int | None = None
    episode_number: int | None = None
    episode_title: str | None = None
    duplicate: bool = False
    valid: bool = True
    reason: str | None = None


class PlaylistCreatePreviewResponse(BaseModel):
    confirmation_token: str
    expires_at: datetime
    title: str
    selected_count: int
    episode_count: int
    items: list[PlaylistCreatePreviewItem] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    can_create: bool


class PlaylistCreateRequest(BaseModel):
    confirmation_token: str
    confirm: bool = False


class PlaylistCreateResponse(BaseModel):
    ok: bool
    message: str
    playlist: PlexPlaylistSummary | None = None
