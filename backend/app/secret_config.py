from __future__ import annotations

from copy import deepcopy
from typing import Any
from urllib.parse import parse_qsl, urlparse


CONFIG_SECRET_FIELDS: dict[str, tuple[str, ...]] = {
    "qbittorrent": ("username", "password"),
    "transmission": ("username", "password"),
    "metadata": ("tmdb_api_key",),
    "ai_settings": ("api_key",),
    "playlist_settings": ("token",),
}
SITE_SECRET_FIELDS = (
    "api_key",
    "cookie",
    "passkey",
    "authorization",
    "rss_url",
    "request_headers",
)
AUTH_QUERY_MARKERS = {
    "api_key",
    "apikey",
    "auth",
    "authkey",
    "authorization",
    "downhash",
    "key",
    "passkey",
    "secret",
    "signature",
    "sign",
    "token",
    "uid",
}
PRIVATE_RSS_PLACEHOLDER = "[private RSS source]"


def config_secret_namespace(key: str) -> str:
    return f"config:{key}"


def value_is_present(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (dict, list, tuple, set)):
        return bool(value)
    return True


def split_sensitive_config(key: str, payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    public = deepcopy(payload)
    secrets: dict[str, Any] = {}
    for field in CONFIG_SECRET_FIELDS.get(key, ()):
        value = public.pop(field, None)
        if value_is_present(value):
            secrets[field] = value
        public[field] = "" if key in {"qbittorrent", "transmission"} else None

    if key == "ai_settings":
        profiles = dict(public.get("provider_profiles") or {})
        for provider, raw_profile in list(profiles.items()):
            if not isinstance(raw_profile, dict):
                continue
            profile = dict(raw_profile)
            value = profile.pop("api_key", None)
            if value_is_present(value):
                secrets[f"provider_profiles.{provider}.api_key"] = value
            profile["api_key"] = None
            profiles[provider] = profile
        public["provider_profiles"] = profiles

    if key == "notifications":
        bark = dict(public.get("bark") or {})
        value = bark.pop("device_key", None)
        bark.pop("clear_device_key", None)
        if value_is_present(value):
            secrets["bark.device_key"] = value
        bark["device_key"] = None
        public["bark"] = bark

    if key == "site_settings":
        for site_id, raw in list(public.items()):
            if not isinstance(raw, dict):
                continue
            site = dict(raw)
            for field in SITE_SECRET_FIELDS:
                value = site.pop(field, None)
                if value_is_present(value):
                    secrets[f"{site_id}.{field}"] = value
                site[field] = {} if field == "request_headers" else None
            public[site_id] = site
    return public, secrets


def merge_sensitive_config(key: str, public: dict[str, Any], secrets: dict[str, Any]) -> dict[str, Any]:
    merged = deepcopy(public)
    for field in CONFIG_SECRET_FIELDS.get(key, ()):
        if field in secrets:
            merged[field] = secrets[field]

    if key == "ai_settings":
        profiles = dict(merged.get("provider_profiles") or {})
        for composite, value in secrets.items():
            prefix, separator, provider_and_field = composite.partition(".")
            if prefix != "provider_profiles" or not separator:
                continue
            provider, separator, field = provider_and_field.partition(".")
            if not separator or field != "api_key":
                continue
            profile = dict(profiles.get(provider) or {})
            profile["api_key"] = value
            profiles[provider] = profile
        merged["provider_profiles"] = profiles

    if key == "notifications" and "bark.device_key" in secrets:
        bark = dict(merged.get("bark") or {})
        bark["device_key"] = secrets["bark.device_key"]
        merged["bark"] = bark

    if key == "site_settings":
        for composite, value in secrets.items():
            site_id, separator, field = composite.partition(".")
            if not separator or field not in SITE_SECRET_FIELDS:
                continue
            site = dict(merged.get(site_id) or {})
            site[field] = value
            merged[site_id] = site
    return merged


def url_contains_authentication(value: str | None) -> bool:
    candidate = str(value or "").strip()
    if not candidate:
        return False
    try:
        parsed = urlparse(candidate)
    except ValueError:
        return False
    if parsed.username or parsed.password:
        return True
    query_names = {name.casefold() for name, _ in parse_qsl(parsed.query, keep_blank_values=True)}
    return bool(query_names.intersection(AUTH_QUERY_MARKERS))


def split_subscription_payload(payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    public = deepcopy(payload)
    secrets: dict[str, Any] = {}
    source_type = str(public.get("source_type") or "keyword")
    rss_urls = public.get("rss_urls") or []
    if rss_urls:
        secrets["rss_urls"] = rss_urls
        public["rss_urls"] = []
    for field in ("keyword", "source_url", "mikan_bangumi_url"):
        value = public.get(field)
        if not value_is_present(value):
            continue
        if field == "keyword" and value == PRIVATE_RSS_PLACEHOLDER:
            continue
        if (source_type == "rss" and field in {"keyword", "source_url"}) or url_contains_authentication(str(value)):
            secrets[field] = value
            public[field] = PRIVATE_RSS_PLACEHOLDER if field == "keyword" else None
    return public, secrets


def merge_subscription_payload(public: dict[str, Any], secrets: dict[str, Any]) -> dict[str, Any]:
    merged = deepcopy(public)
    merged.update(secrets)
    return merged


def split_result_payload(payload: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    public = deepcopy(payload)
    secrets: dict[str, Any] = {}
    for field in ("download_url", "torrent_url"):
        value = public.pop(field, None)
        if value_is_present(value):
            secrets[field] = value
        public[field] = None
    for field in ("detail_url", "source_url"):
        value = public.get(field)
        if value_is_present(value) and url_contains_authentication(str(value)):
            secrets[field] = value
            public[field] = None
    return public, secrets


def merge_result_payload(public: dict[str, Any], secrets: dict[str, Any]) -> dict[str, Any]:
    merged = deepcopy(public)
    merged.update(secrets)
    return merged
