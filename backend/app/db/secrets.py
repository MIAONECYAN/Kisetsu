from __future__ import annotations

import json
import os
import sqlite3
from collections.abc import Iterable, Iterator, Mapping
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SECRET_SCHEMA_VERSION = 1


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class SecretStore:
    """A deliberately small sidecar database for authentication material."""

    def __init__(self, path: str | Path):
        self.path = Path(path)

    def _prepare_path(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if os.name == "posix":
            if not self.path.exists():
                descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
                os.close(descriptor)
            os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        self._prepare_path()
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()
            if os.name == "posix" and self.path.exists():
                os.chmod(self.path, 0o600)

    def init(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS secret_meta (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS secrets (
                  namespace TEXT NOT NULL,
                  field TEXT NOT NULL,
                  value TEXT NOT NULL,
                  version INTEGER NOT NULL DEFAULT 1,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(namespace, field)
                );
                """
            )
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(secrets)").fetchall()}
            if "version" not in columns:
                conn.execute("ALTER TABLE secrets ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
            conn.execute(
                """
                INSERT INTO secret_meta(key, value, updated_at)
                VALUES ('schema_version', ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
                """,
                (str(SECRET_SCHEMA_VERSION), _utc_now_iso()),
            )

    def get(self, namespace: str, field: str, default: Any = None) -> Any:
        self.init()
        with self.connect() as conn:
            row = conn.execute(
                "SELECT value FROM secrets WHERE namespace = ? AND field = ?",
                (namespace, field),
            ).fetchone()
        if row is None:
            return default
        return json.loads(row["value"])

    def namespace(self, namespace: str) -> dict[str, Any]:
        self.init()
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT field, value FROM secrets WHERE namespace = ? ORDER BY field",
                (namespace,),
            ).fetchall()
        return {str(row["field"]): json.loads(row["value"]) for row in rows}

    def namespaces(self, namespaces: Iterable[str]) -> dict[str, dict[str, Any]]:
        names = list(dict.fromkeys(str(value) for value in namespaces))
        if not names:
            return {}
        self.init()
        result: dict[str, dict[str, Any]] = {}
        with self.connect() as conn:
            for offset in range(0, len(names), 400):
                chunk = names[offset : offset + 400]
                placeholders = ",".join("?" for _ in chunk)
                rows = conn.execute(
                    f"SELECT namespace, field, value FROM secrets WHERE namespace IN ({placeholders})",
                    chunk,
                ).fetchall()
                for row in rows:
                    result.setdefault(str(row["namespace"]), {})[str(row["field"])] = json.loads(
                        row["value"]
                    )
        return result

    def list_namespaces(self) -> list[str]:
        self.init()
        with self.connect() as conn:
            rows = conn.execute("SELECT DISTINCT namespace FROM secrets ORDER BY namespace").fetchall()
        return [str(row["namespace"]) for row in rows]

    def replace_namespace(self, namespace: str, values: Mapping[str, Any]) -> None:
        self.init()
        with self.connect() as conn:
            conn.execute("DELETE FROM secrets WHERE namespace = ?", (namespace,))
            self._insert_values(conn, namespace, values)

    def set_many(self, entries: Mapping[str, Mapping[str, Any]]) -> None:
        self.init()
        with self.connect() as conn:
            for namespace, values in entries.items():
                for field, value in values.items():
                    conn.execute(
                        """
                        INSERT INTO secrets(namespace, field, value, version, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(namespace, field)
                        DO UPDATE SET value=excluded.value, version=excluded.version, updated_at=excluded.updated_at
                        """,
                        (
                            namespace,
                            field,
                            json.dumps(value, ensure_ascii=False),
                            SECRET_SCHEMA_VERSION,
                            _utc_now_iso(),
                        ),
                    )

    def delete_namespace(self, namespace: str) -> None:
        self.init()
        with self.connect() as conn:
            conn.execute("DELETE FROM secrets WHERE namespace = ?", (namespace,))

    def delete_namespaces(self, namespaces: list[str]) -> None:
        if not namespaces:
            return
        self.init()
        with self.connect() as conn:
            conn.executemany("DELETE FROM secrets WHERE namespace = ?", [(value,) for value in namespaces])

    def get_meta(self, key: str) -> str | None:
        self.init()
        with self.connect() as conn:
            row = conn.execute("SELECT value FROM secret_meta WHERE key = ?", (key,)).fetchone()
        return str(row["value"]) if row else None

    def set_meta(self, key: str, value: str) -> None:
        self.init()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO secret_meta(key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
                """,
                (key, value, _utc_now_iso()),
            )

    @staticmethod
    def _insert_values(conn: sqlite3.Connection, namespace: str, values: Mapping[str, Any]) -> None:
        now = _utc_now_iso()
        conn.executemany(
            "INSERT INTO secrets(namespace, field, value, version, updated_at) VALUES (?, ?, ?, ?, ?)",
            [
                (namespace, field, json.dumps(value, ensure_ascii=False), SECRET_SCHEMA_VERSION, now)
                for field, value in values.items()
            ],
        )
