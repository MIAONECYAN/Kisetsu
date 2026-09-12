from __future__ import annotations

from abc import ABC, abstractmethod

import httpx

from app.models import MetadataCandidate


class MetadataAdapterError(RuntimeError):
    pass


def describe_metadata_error(exc: BaseException) -> str:
    if isinstance(exc, MetadataAdapterError):
        return str(exc) or "元数据源返回错误"
    if isinstance(exc, httpx.TimeoutException):
        return "元数据源请求超时，请稍后重试。"
    if isinstance(exc, httpx.ConnectError):
        return "无法连接元数据源，请检查网络或代理设置。"
    if isinstance(exc, httpx.HTTPStatusError):
        status_code = exc.response.status_code
        if status_code in {401, 403}:
            return "元数据源拒绝访问，请检查 API Key 或访问权限。"
        if status_code == 404:
            return "元数据源没有找到对应资源。"
        return f"元数据源返回 HTTP {status_code}，请稍后重试。"
    if isinstance(exc, httpx.RequestError):
        return "元数据源网络请求失败，请检查网络或代理设置。"
    return "元数据源请求失败，请稍后重试或检查配置。"


class BaseMetadataAdapter(ABC):
    source: str

    @abstractmethod
    async def search(self, query: str, year: int | None = None, media_type: str = "anime") -> list[MetadataCandidate]:
        raise NotImplementedError
