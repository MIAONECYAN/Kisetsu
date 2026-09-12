from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Mapping
from typing import Any
from urllib.parse import parse_qs, urlparse


_TITLE_SEPARATOR = re.compile(r"\s*(?:/|／|\||｜|;|；)\s*")
_MIKAN_PATH = re.compile(r"/(?:Home/)?Bangumi/(\d+)(?:/|$)", flags=re.I)
_MIKAN_IDENTITY = re.compile(r"mikan:bangumi:(\d+)", flags=re.I)


def normalized_identity_text(value: str | None) -> str:
    normalized = unicodedata.normalize("NFKC", value or "").casefold()
    return re.sub(r"\s+", " ", normalized).strip()


def title_identity_keys(values: Iterable[str | None]) -> set[str]:
    keys: set[str] = set()
    for value in values:
        for part in _TITLE_SEPARATOR.split(value or ""):
            key = normalized_identity_text(part).replace(" ", "")
            if key:
                keys.add(key)
    return keys


def mikan_bangumi_id_from_value(value: str | None) -> str | None:
    raw_value = (value or "").strip()
    if not raw_value:
        return None

    identity_match = _MIKAN_IDENTITY.fullmatch(raw_value)
    if identity_match:
        return identity_match.group(1)

    parsed = urlparse(raw_value)
    path_match = _MIKAN_PATH.search(parsed.path or raw_value)
    if path_match:
        return path_match.group(1)

    query = parse_qs(parsed.query)
    for key, values in query.items():
        if key.casefold() not in {"bangumiid", "bangumi_id"}:
            continue
        candidate = str(values[0]).strip() if values else ""
        if candidate.isdigit():
            return candidate
    return None


def subscription_mikan_bangumi_ids(value: Mapping[str, Any]) -> set[str]:
    return {
        item
        for item in (
            mikan_bangumi_id_from_value(str(value.get("mikan_bangumi_url") or "")),
            mikan_bangumi_id_from_value(str(value.get("source_url") or "")),
            mikan_bangumi_id_from_value(str(value.get("identity_key") or "")),
        )
        if item is not None
    }
