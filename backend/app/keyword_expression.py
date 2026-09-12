from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterable


class KeywordExpressionError(ValueError):
    pass


@dataclass(frozen=True)
class KeywordClause:
    terms: tuple[str, ...]
    grouped: bool = False

    @property
    def serialized(self) -> str:
        if self.grouped:
            return f"({', '.join(self.terms)})"
        return self.terms[0]


def _syntax_character(value: str) -> str:
    return {
        "，": ",",
        "（": "(",
        "）": ")",
    }.get(value, value)


def _split_top_level(value: str) -> list[str]:
    segments: list[str] = []
    start = 0
    depth = 0
    for index, raw_character in enumerate(value):
        character = _syntax_character(raw_character)
        if character == "(":
            depth += 1
        elif character == ")":
            if depth == 0:
                raise KeywordExpressionError("存在多余的右括号。")
            depth -= 1
        elif character == "," and depth == 0:
            segment = value[start:index].strip()
            if not segment:
                raise KeywordExpressionError("关键词条件之间不能有空项。")
            segments.append(segment)
            start = index + 1
    if depth != 0:
        raise KeywordExpressionError("括号未闭合。")
    final_segment = value[start:].strip()
    if not final_segment:
        raise KeywordExpressionError("关键词条件之间不能有空项。")
    segments.append(final_segment)
    return segments


def _parse_clause(value: str) -> KeywordClause:
    clause = value.strip()
    if not clause:
        raise KeywordExpressionError("关键词条件不能为空。")
    if _syntax_character(clause[0]) != "(":
        return KeywordClause(terms=(clause,))
    if _syntax_character(clause[-1]) != ")":
        raise KeywordExpressionError("括号组后不能附加其他内容。")
    inner = clause[1:-1].strip()
    if not inner:
        raise KeywordExpressionError("括号组不能为空。")
    if any(_syntax_character(character) in {"(", ")"} for character in inner):
        raise KeywordExpressionError("暂不支持嵌套括号。")
    terms = tuple(part.strip() for part in inner.replace("，", ",").split(","))
    if any(not term for term in terms):
        raise KeywordExpressionError("括号组内不能有空关键词。")
    return KeywordClause(terms=terms, grouped=True)


def parse_keyword_expression(value: str) -> tuple[KeywordClause, ...]:
    expression = value.strip()
    if not expression:
        return ()
    return tuple(_parse_clause(segment) for segment in _split_top_level(expression))


def parse_keyword_expression_items(values: Iterable[str]) -> tuple[KeywordClause, ...]:
    clauses: list[KeywordClause] = []
    for value in values:
        if not isinstance(value, str):
            raise KeywordExpressionError("关键词必须是文本。")
        clauses.extend(parse_keyword_expression(value))
    return tuple(clauses)


def normalize_keyword_expression_items(values: Iterable[str]) -> list[str]:
    return [clause.serialized for clause in parse_keyword_expression_items(values)]


def keyword_expression_matches(values: Iterable[str], matcher: Callable[[str], bool]) -> bool:
    clauses = parse_keyword_expression_items(values)
    return any(all(matcher(term) for term in clause.terms) for clause in clauses)
