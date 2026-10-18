from __future__ import annotations

import re


_RULE = re.compile(r"\s*(\d+)\s*-\s*(\d+)\s*\Z")


def parse_season_rewrite(value: str | None) -> dict[int, int]:
    if not value or not value.strip():
        return {}
    rules: dict[int, int] = {}
    for item in value.split(","):
        match = _RULE.fullmatch(item)
        if match is None:
            raise ValueError("Season Rewrite 格式应为 2-1, 3-1；请使用英文逗号分隔")
        source, target = (int(part) for part in match.groups())
        if source < 1 or target < 1:
            raise ValueError("Season Rewrite 的原季度和目标季度必须大于 0")
        if source in rules and rules[source] != target:
            raise ValueError(f"Season {source} 不能改写到两个不同的季度")
        rules[source] = target
    return rules


def normalize_season_rewrite(value: str | None) -> str:
    return ", ".join(f"{source}-{target}" for source, target in parse_season_rewrite(value).items())


def rewritten_season(original: int | None, value: str | None) -> int | None:
    if original is None:
        return None
    return parse_season_rewrite(value).get(original, original)
