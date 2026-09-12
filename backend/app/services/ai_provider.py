from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse, urlunparse

import httpx


@dataclass(frozen=True)
class AIProviderSpec:
    provider: str
    label: str
    default_base_url: str | None
    default_model: str | None
    append_v1_to_root: bool
    request_timeout_seconds: float


# Verified against the providers' official documentation on 2026-08-30.
AI_PROVIDER_SPECS: dict[str, AIProviderSpec] = {
    "openai_compatible": AIProviderSpec(
        provider="openai_compatible",
        label="OpenAI-compatible",
        default_base_url=None,
        default_model=None,
        append_v1_to_root=True,
        request_timeout_seconds=60,
    ),
    "xai": AIProviderSpec(
        provider="xai",
        label="xAI",
        default_base_url="https://api.x.ai/v1",
        default_model="grok-4.6",
        append_v1_to_root=True,
        request_timeout_seconds=180,
    ),
    "deepseek": AIProviderSpec(
        provider="deepseek",
        label="DeepSeek",
        default_base_url="https://api.deepseek.com",
        default_model="deepseek-v4-flash",
        append_v1_to_root=False,
        request_timeout_seconds=120,
    ),
}


@dataclass(frozen=True)
class AIProviderFailure(Exception):
    code: str
    message: str
    detail: str

    def __str__(self) -> str:
        return self.message


def provider_spec(provider: str) -> AIProviderSpec | None:
    return AI_PROVIDER_SPECS.get(provider)


def provider_label(provider: str) -> str:
    if provider == "none":
        return "不使用 AI"
    spec = provider_spec(provider)
    return spec.label if spec else "AI 服务"


def provider_default_base_url(provider: str) -> str | None:
    spec = provider_spec(provider)
    return spec.default_base_url if spec else None


def provider_default_model(provider: str) -> str | None:
    spec = provider_spec(provider)
    return spec.default_model if spec else None


def normalize_ai_base_url(provider: str, base_url: str | None) -> str | None:
    spec = provider_spec(provider)
    candidate = str(base_url or "").strip() or (spec.default_base_url if spec else None)
    if not candidate:
        return None

    parsed = urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password:
        return None

    path = parsed.path.rstrip("/")
    for suffix in ("/chat/completions", "/models"):
        if path.endswith(suffix):
            path = path[: -len(suffix)].rstrip("/")
            break
    if not path and spec and spec.append_v1_to_root:
        path = "/v1"

    normalized = parsed._replace(path=path, params="", query="", fragment="")
    return urlunparse(normalized).rstrip("/")


def ai_endpoint_url(provider: str, base_url: str | None, endpoint: str) -> str | None:
    api_base = normalize_ai_base_url(provider, base_url)
    if not api_base:
        return None
    clean_endpoint = endpoint.strip("/")
    if api_base.rstrip("/").endswith(f"/{clean_endpoint}"):
        return api_base.rstrip("/")
    return f"{api_base.rstrip('/')}/{clean_endpoint}"


def ai_request_timeout(provider: str) -> httpx.Timeout:
    spec = provider_spec(provider)
    total = spec.request_timeout_seconds if spec else 60
    return httpx.Timeout(total, connect=15)


def build_chat_completion_payload(provider: str, model: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": 0,
        "response_format": {"type": "json_object"},
    }
    if provider == "deepseek":
        # DeepSeek V4 enables thinking by default. This short extraction task needs
        # deterministic JSON, and its official docs say temperature is ignored in
        # thinking mode, so explicitly use non-thinking mode.
        payload["thinking"] = {"type": "disabled"}
        payload["max_tokens"] = 2048
    return payload


def _redact_provider_detail(value: str) -> str:
    compact = " ".join(str(value).split())[:300]
    compact = re.sub(r"(?i)bearer\s+[A-Za-z0-9._~+/-]+", "Bearer [redacted]", compact)
    compact = re.sub(r"(?i)(?:sk|xai)-[A-Za-z0-9_-]{8,}", "[redacted]", compact)
    return compact


def _response_error_fields(response: httpx.Response) -> tuple[str, str]:
    try:
        payload = response.json()
    except (ValueError, json.JSONDecodeError):
        return "", ""
    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict):
        message = str(error.get("message") or "")
        code = str(error.get("code") or error.get("type") or "")
        return _redact_provider_detail(message), _redact_provider_detail(code)
    if isinstance(error, str):
        return _redact_provider_detail(error), ""
    message = payload.get("message") if isinstance(payload, dict) else None
    return _redact_provider_detail(str(message or "")), ""


def failure_from_response(provider: str, response: httpx.Response) -> AIProviderFailure | None:
    status = response.status_code
    if status < 400:
        return None
    label = provider_label(provider)
    provider_message, provider_code = _response_error_fields(response)
    searchable = f"{provider_message} {provider_code}".casefold()

    if status == 401:
        code, message, detail = "AI_AUTH_FAILED", "API Key 无效", f"{label} 拒绝了当前 API Key。"
    elif status == 403:
        code, message, detail = "AI_PERMISSION_DENIED", "AI 访问被拒绝", f"当前账号无权访问所选 {label} 模型或接口。"
    elif status == 404 and "model" in searchable:
        code, message, detail = "AI_MODEL_NOT_FOUND", "模型不可用", f"所选 {label} 模型不存在或当前账号不可访问。"
    elif status == 404:
        code, message, detail = "AI_ENDPOINT_NOT_FOUND", "AI 接口地址错误", f"{label} 未找到当前 API 端点，请检查 Base URL。"
    elif status == 429:
        code, message, detail = "AI_RATE_LIMITED", "AI 请求过于频繁", f"{label} 已触发限流，请稍后重试。"
    elif status in {400, 422} and "model" in searchable:
        code, message, detail = "AI_MODEL_NOT_FOUND", "模型不可用", f"所选 {label} 模型无效或不支持当前请求。"
    elif status in {400, 422}:
        code, message, detail = "AI_REQUEST_INVALID", "AI 请求参数不受支持", f"{label} 拒绝了当前请求格式。"
    elif status >= 500:
        code, message, detail = "AI_SERVICE_UNAVAILABLE", "AI 服务暂时不可用", f"{label} 返回 HTTP {status}，请稍后重试。"
    else:
        code, message, detail = "AI_REQUEST_FAILED", "AI 请求失败", f"{label} 返回 HTTP {status}。"

    if provider_message and status not in {401, 403}:
        detail = f"{detail} 服务信息：{provider_message}"
    return AIProviderFailure(code=code, message=message, detail=detail)


def failure_from_request_error(provider: str, error: httpx.RequestError) -> AIProviderFailure:
    label = provider_label(provider)
    if isinstance(error, httpx.ConnectTimeout):
        return AIProviderFailure("AI_CONNECT_TIMEOUT", "连接 AI 服务超时", f"连接 {label} 超时，请检查网络或 Base URL。")
    if isinstance(error, httpx.ReadTimeout):
        return AIProviderFailure("AI_RESPONSE_TIMEOUT", "AI 生成超时", f"{label} 已连接，但没有在限定时间内返回结果。")
    if isinstance(error, httpx.ConnectError):
        lower = str(error).casefold()
        if "ssl" in lower or "certificate" in lower:
            return AIProviderFailure("AI_TLS_FAILED", "AI 安全连接失败", f"无法验证 {label} 的 TLS 证书。")
        if "name or service" in lower or "nodename nor servname" in lower or "resolve" in lower:
            return AIProviderFailure("AI_DNS_FAILED", "无法解析 AI 服务地址", f"无法解析 {label} 的 Base URL。")
        return AIProviderFailure("AI_CONNECTION_FAILED", "无法连接 AI 服务", f"无法连接 {label}，请检查网络和 Base URL。")
    return AIProviderFailure("AI_NETWORK_FAILED", "AI 网络请求失败", f"与 {label} 通信时连接中断。")


def extract_chat_completion_content(response: httpx.Response) -> dict[str, Any]:
    try:
        payload = response.json()
        content = payload["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise AIProviderFailure("AI_RESPONSE_INVALID", "AI 返回内容无法解析", "AI 响应缺少标准 Chat Completions 内容。") from exc

    if isinstance(content, dict):
        return content
    if not isinstance(content, str) or not content.strip():
        raise AIProviderFailure("AI_RESPONSE_EMPTY", "AI 返回内容为空", "AI 没有返回可用的结构化结果。")

    candidate = content.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", candidate, flags=re.I | re.S)
    if fenced:
        candidate = fenced.group(1).strip()
    try:
        data = json.loads(candidate)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        raise AIProviderFailure("AI_RESPONSE_INVALID", "AI 返回内容无法解析", "AI 未按结构化 JSON 返回。") from exc
    if not isinstance(data, dict):
        raise AIProviderFailure("AI_RESPONSE_INVALID", "AI 返回内容无法解析", "AI 未返回结构化 JSON 对象。")
    return data


def extract_model_items(response: httpx.Response) -> list[dict[str, Any]]:
    try:
        payload = response.json()
    except (ValueError, json.JSONDecodeError) as exc:
        raise AIProviderFailure("AI_RESPONSE_INVALID", "模型列表无法解析", "AI 服务没有返回有效 JSON。") from exc
    raw_models = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(raw_models, list):
        raise AIProviderFailure("AI_RESPONSE_INVALID", "模型列表无法解析", "AI 服务没有返回标准模型列表。")
    return [item for item in raw_models if isinstance(item, dict) and (item.get("id") or item.get("name"))]
