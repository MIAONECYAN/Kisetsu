from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


FileRootKind = Literal["download", "brush", "library", "history"]
FileItemKind = Literal["directory", "video", "audio", "subtitle", "image", "archive", "other"]
FileOperationKind = Literal["copy", "move", "delete"]
FileOperationState = Literal["queued", "running", "success", "partial", "failed", "canceled"]


class FileManagerRoot(BaseModel):
    id: str
    name: str
    path: str
    kind: FileRootKind
    sources: list[str] = Field(default_factory=list)
    exists: bool = False
    readable: bool = False
    writable: bool = False


class FileManagerRootResponse(BaseModel):
    roots: list[FileManagerRoot] = Field(default_factory=list)
    read_only: bool = True
    message: str


class FileManagerItem(BaseModel):
    id: str
    root_id: str
    path: str
    parent_path: str
    name: str
    kind: FileItemKind
    is_directory: bool = False
    is_symbolic_link: bool = False
    is_hidden: bool = False
    is_expandable: bool = False
    size_bytes: int | None = None
    modified_at: str | None = None


class FileManagerDirectoryResponse(BaseModel):
    root_id: str
    path: str
    items: list[FileManagerItem] = Field(default_factory=list)
    offset: int = 0
    limit: int = 250
    total: int = 0
    has_more: bool = False


class FileManagerEditSessionRequest(BaseModel):
    confirm: bool = False


class FileManagerEditSession(BaseModel):
    token: str
    expires_at: str
    message: str


class FileManagerLockRequest(BaseModel):
    token: str = Field(min_length=1)


class FileManagerWriteResponse(BaseModel):
    ok: bool = True
    message: str
    item: FileManagerItem | None = None


class FileManagerRenameRequest(BaseModel):
    edit_token: str = Field(min_length=1)
    root_id: str = Field(min_length=1)
    path: str = Field(min_length=1)
    new_name: str = Field(min_length=1, max_length=255)


class FileManagerCreateFolderRequest(BaseModel):
    edit_token: str = Field(min_length=1)
    root_id: str = Field(min_length=1)
    parent_path: str = ""
    name: str = Field(min_length=1, max_length=255)


class FileManagerReference(BaseModel):
    root_id: str = Field(min_length=1)
    path: str = Field(min_length=1)


class FileManagerDeletePreviewRequest(BaseModel):
    edit_token: str = Field(min_length=1)
    sources: list[FileManagerReference] = Field(min_length=1, max_length=100)


class FileManagerDeletePreview(BaseModel):
    token: str
    expires_at: str
    items_total: int
    files_total: int
    directories_total: int
    bytes_total: int
    item_names: list[str] = Field(default_factory=list)
    names_truncated: bool = False
    message: str


class FileManagerDeleteRequest(BaseModel):
    edit_token: str = Field(min_length=1)
    preview_token: str = Field(min_length=1)


class FileManagerOperationRequest(BaseModel):
    edit_token: str = Field(min_length=1)
    kind: FileOperationKind
    sources: list[FileManagerReference] = Field(min_length=1, max_length=100)
    destination_root_id: str = Field(min_length=1)
    destination_path: str = ""


class FileManagerOperationStatus(BaseModel):
    id: str
    kind: FileOperationKind
    status: FileOperationState = "queued"
    items_total: int = 0
    items_completed: int = 0
    bytes_total: int | None = None
    bytes_completed: int = 0
    current_item: str | None = None
    started_at: str
    finished_at: str | None = None
    message: str
    errors: list[str] = Field(default_factory=list)


class FileManagerCancelRequest(BaseModel):
    edit_token: str = Field(min_length=1)
