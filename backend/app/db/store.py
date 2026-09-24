from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from app.db.secrets import SecretStore
from app.secret_config import (
    config_secret_namespace,
    merge_result_payload,
    merge_sensitive_config,
    merge_subscription_payload,
    split_result_payload,
    split_sensitive_config,
    split_subscription_payload,
)
from app.settings import secrets_database_path


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


SUBSCRIPTION_REFRESH_RETENTION_DAYS = 7
SUBSCRIPTION_REFRESH_WARNING_LIMIT = 24
SUBSCRIPTION_REFRESH_WARNING_LENGTH = 500


def _compact_refresh_warnings(warnings: list[str]) -> list[str]:
    compact = [" ".join(str(item).split())[:SUBSCRIPTION_REFRESH_WARNING_LENGTH] for item in warnings]
    compact = [item for item in compact if item]
    if len(compact) <= SUBSCRIPTION_REFRESH_WARNING_LIMIT:
        return compact
    head_count = SUBSCRIPTION_REFRESH_WARNING_LIMIT - 2
    omitted = len(compact) - head_count - 1
    return [*compact[:head_count], f"另有 {omitted} 条重复或逐资源诊断未长期保存。", compact[-1]]


class Store:
    def __init__(self, path: str | Path, secret_path: str | Path | None = None):
        self.path = Path(path)
        self.secrets = SecretStore(secret_path or secrets_database_path(self.path))

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def init(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS config (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS subscriptions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  data TEXT NOT NULL,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  created_at TEXT NOT NULL,
                  updated_at TEXT
                );

                CREATE TABLE IF NOT EXISTS download_history (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  fingerprint TEXT NOT NULL UNIQUE,
                  title TEXT NOT NULL,
                  source TEXT NOT NULL,
                  download_url TEXT,
                  qbittorrent_hash TEXT,
                  downloader_type TEXT NOT NULL DEFAULT 'qbittorrent',
                  remote_task_id TEXT,
                  torrent_name TEXT,
                  save_path TEXT,
                  subscription_id INTEGER,
                  status TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS subscription_matches (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  subscription_id INTEGER NOT NULL,
                  fingerprint TEXT NOT NULL,
                  result TEXT NOT NULL,
                  parsed_title TEXT NOT NULL,
                  status TEXT NOT NULL,
                  first_seen_at TEXT NOT NULL,
                  last_seen_at TEXT NOT NULL,
                  UNIQUE(subscription_id, fingerprint)
                );

                CREATE TABLE IF NOT EXISTS subscription_refresh_history (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  subscription_id INTEGER NOT NULL,
                  matched_count INTEGER NOT NULL DEFAULT 0,
                  added_count INTEGER NOT NULL DEFAULT 0,
                  skipped_count INTEGER NOT NULL DEFAULT 0,
                  error_count INTEGER NOT NULL DEFAULT 0,
                  warnings TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS metadata_bindings (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  target_type TEXT NOT NULL,
                  target_id TEXT NOT NULL,
                  bangumi_id TEXT,
                  tmdb_id TEXT,
                  data TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS plex_mappings (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  subject_key TEXT NOT NULL UNIQUE,
                  show_name TEXT NOT NULL,
                  show_year INTEGER,
                  season_number INTEGER NOT NULL,
                  episode_offset INTEGER NOT NULL DEFAULT 0,
                  special_episode_numbers TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT
                );

                CREATE TABLE IF NOT EXISTS playlist_pairings (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  item_key TEXT NOT NULL,
                  machine_id TEXT NOT NULL,
                  library_id TEXT NOT NULL,
                  plex_rating_key TEXT NOT NULL,
                  source TEXT NOT NULL,
                  score REAL NOT NULL DEFAULT 0,
                  reason TEXT NOT NULL,
                  data TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  UNIQUE(item_key, machine_id, library_id)
                );

                CREATE TABLE IF NOT EXISTS scrape_cache (
                  key TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  value TEXT NOT NULL,
                  expires_at TEXT,
                  updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organize_previews (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  request TEXT NOT NULL,
                  preview TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organize_history (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  source_path TEXT NOT NULL,
                  destination_path TEXT NOT NULL,
                  status TEXT NOT NULL,
                  message TEXT NOT NULL,
                  preview TEXT NOT NULL,
                  qbittorrent_task_deleted INTEGER NOT NULL DEFAULT 0,
                  delete_files_from_qbittorrent INTEGER NOT NULL DEFAULT 0,
                  cleanup_attempted INTEGER NOT NULL DEFAULT 0,
                  cleanup_status TEXT,
                  cleanup_path TEXT,
                  cleanup_message TEXT,
                  subscription_id INTEGER,
                  subscription_season INTEGER,
                  resource_explicit_season INTEGER,
                  effective_season INTEGER,
                  season_source TEXT,
                  manual_override INTEGER NOT NULL DEFAULT 0,
                  override_reason TEXT,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS organize_targets (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  path TEXT NOT NULL,
                  media_type TEXT NOT NULL,
                  is_default INTEGER NOT NULL DEFAULT 0,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  created_at TEXT NOT NULL,
                  updated_at TEXT
                );

                CREATE TABLE IF NOT EXISTS notification_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  event_key TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  title TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  status TEXT NOT NULL,
                  error_message TEXT,
                  created_at TEXT NOT NULL,
                  sent_at TEXT
                );
                """
            )
            self._ensure_column(conn, "download_history", "qbittorrent_hash", "TEXT")
            self._ensure_column(conn, "download_history", "downloader_type", "TEXT NOT NULL DEFAULT 'qbittorrent'")
            self._ensure_column(conn, "download_history", "remote_task_id", "TEXT")
            self._ensure_column(conn, "download_history", "torrent_name", "TEXT")
            self._ensure_column(conn, "download_history", "save_path", "TEXT")
            self._ensure_column(conn, "organize_history", "qbittorrent_task_deleted", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "organize_history", "delete_files_from_qbittorrent", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "organize_history", "cleanup_attempted", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "organize_history", "cleanup_status", "TEXT")
            self._ensure_column(conn, "organize_history", "cleanup_path", "TEXT")
            self._ensure_column(conn, "organize_history", "cleanup_message", "TEXT")
            self._ensure_column(conn, "organize_history", "subscription_id", "INTEGER")
            self._ensure_column(conn, "organize_history", "subscription_season", "INTEGER")
            self._ensure_column(conn, "organize_history", "resource_explicit_season", "INTEGER")
            self._ensure_column(conn, "organize_history", "effective_season", "INTEGER")
            self._ensure_column(conn, "organize_history", "season_source", "TEXT")
            self._ensure_column(conn, "organize_history", "manual_override", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "organize_history", "override_reason", "TEXT")
            conn.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_events_sent_key
                ON notification_events(event_key, provider)
                WHERE status = 'sent'
                """
            )
            conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_playlist_pairings_server_library
                ON playlist_pairings(machine_id, library_id)
                """
            )
        self.secrets.init()
        self.prune_transient_history()

    def prune_transient_history(
        self,
        *,
        now: datetime | None = None,
        batch_size: int = 1_000,
    ) -> dict[str, int]:
        cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=SUBSCRIPTION_REFRESH_RETENTION_DAYS)
        deleted = 0
        limit = max(1, batch_size)
        while True:
            with self.connect() as conn:
                rows = conn.execute(
                    "SELECT id FROM subscription_refresh_history WHERE created_at < ? ORDER BY id LIMIT ?",
                    (cutoff.isoformat(), limit),
                ).fetchall()
                ids = [int(row["id"]) for row in rows]
                if ids:
                    placeholders = ", ".join("?" for _ in ids)
                    cursor = conn.execute(
                        f"DELETE FROM subscription_refresh_history WHERE id IN ({placeholders})",
                        ids,
                    )
                    deleted += cursor.rowcount
            if len(ids) < limit:
                break
        with self.connect() as conn:
            conn.execute("PRAGMA optimize")
        return {"subscription_refresh_history_deleted": deleted}

    def _ensure_column(self, conn: sqlite3.Connection, table_name: str, column_name: str, column_type: str) -> None:
        columns = {row["name"] for row in conn.execute(f"PRAGMA table_info({table_name})").fetchall()}
        if column_name not in columns:
            conn.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {column_type}")

    def _set_public_config(self, key: str, value: dict[str, Any]) -> None:
        payload = json.dumps(value, ensure_ascii=False)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO config(key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
                """,
                (key, payload, utc_now_iso()),
            )

    def set_config(self, key: str, value: dict[str, Any]) -> None:
        public, secrets = split_sensitive_config(key, value)
        if secrets:
            self.set_runtime_config(key, value)
            return
        self._set_public_config(key, public)

    def get_config(self, key: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
        if not row:
            return None
        return json.loads(row["value"])

    def set_automation_interval(self, interval_seconds: int) -> None:
        if type(interval_seconds) is not int or not 1 <= interval_seconds <= 86400:
            raise ValueError("interval_seconds must be between 1 and 86400")
        # Lock before reading so a field-only update preserves concurrent settings writes.
        with self.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT value FROM config WHERE key = ?", ("automation_settings",)).fetchone()
            settings = json.loads(row["value"]) if row else {}
            settings["auto_refresh_interval_seconds"] = interval_seconds
            conn.execute(
                "INSERT INTO config(key, value, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                ("automation_settings", json.dumps(settings, ensure_ascii=False), utc_now_iso()),
            )

    def get_runtime_config(self, key: str) -> dict[str, Any] | None:
        public = self.get_config(key)
        secrets = self.secrets.namespace(config_secret_namespace(key))
        if public is None and not secrets:
            return None
        return merge_sensitive_config(key, public or {}, secrets)

    def set_runtime_config(self, key: str, value: dict[str, Any]) -> None:
        public, secrets = split_sensitive_config(key, value)
        namespace = config_secret_namespace(key)
        previous = self.secrets.namespace(namespace)
        self.secrets.replace_namespace(namespace, secrets)
        try:
            self._set_public_config(key, public)
        except Exception:
            self.secrets.replace_namespace(namespace, previous)
            raise

    def upsert_playlist_pairing(
        self,
        *,
        item_key: str,
        machine_id: str,
        library_id: str,
        plex_rating_key: str,
        source: str,
        score: float,
        reason: str,
        data: dict[str, Any],
    ) -> dict[str, Any]:
        now = utc_now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO playlist_pairings(
                  item_key, machine_id, library_id, plex_rating_key,
                  source, score, reason, data, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_key, machine_id, library_id) DO UPDATE SET
                  plex_rating_key=excluded.plex_rating_key,
                  source=excluded.source,
                  score=excluded.score,
                  reason=excluded.reason,
                  data=excluded.data,
                  updated_at=excluded.updated_at
                """,
                (
                    item_key,
                    machine_id,
                    library_id,
                    plex_rating_key,
                    source,
                    score,
                    reason,
                    json.dumps(data, ensure_ascii=False),
                    now,
                    now,
                ),
            )
            row = conn.execute(
                """
                SELECT * FROM playlist_pairings
                WHERE item_key = ? AND machine_id = ? AND library_id = ?
                """,
                (item_key, machine_id, library_id),
            ).fetchone()
        return self._decode_playlist_pairing(row)

    def upsert_playlist_pairings(self, pairings: list[dict[str, Any]]) -> None:
        if not pairings:
            return
        now = utc_now_iso()
        values = [
            (
                str(pairing["item_key"]),
                str(pairing["machine_id"]),
                str(pairing["library_id"]),
                str(pairing["plex_rating_key"]),
                str(pairing["source"]),
                float(pairing["score"]),
                str(pairing["reason"]),
                json.dumps(pairing.get("data") or {}, ensure_ascii=False),
                now,
                now,
            )
            for pairing in pairings
        ]
        with self.connect() as conn:
            conn.executemany(
                """
                INSERT INTO playlist_pairings(
                  item_key, machine_id, library_id, plex_rating_key,
                  source, score, reason, data, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_key, machine_id, library_id) DO UPDATE SET
                  plex_rating_key=excluded.plex_rating_key,
                  source=excluded.source,
                  score=excluded.score,
                  reason=excluded.reason,
                  data=excluded.data,
                  updated_at=excluded.updated_at
                """,
                values,
            )

    def list_playlist_pairings(self, machine_id: str, library_id: str) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM playlist_pairings
                WHERE machine_id = ? AND library_id = ?
                ORDER BY item_key
                """,
                (machine_id, library_id),
            ).fetchall()
        return [self._decode_playlist_pairing(row) for row in rows]

    def delete_playlist_pairing(self, item_key: str, machine_id: str, library_id: str) -> bool:
        with self.connect() as conn:
            cursor = conn.execute(
                """
                DELETE FROM playlist_pairings
                WHERE item_key = ? AND machine_id = ? AND library_id = ?
                """,
                (item_key, machine_id, library_id),
            )
        return cursor.rowcount > 0

    @staticmethod
    def _decode_playlist_pairing(row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["data"] = json.loads(value["data"])
        return value

    def add_notification_event(
        self,
        *,
        event_key: str,
        event_type: str,
        provider: str,
        title: str,
        payload: dict[str, Any],
        status: str,
        error_message: str | None = None,
    ) -> dict[str, Any]:
        with self.connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO notification_events(event_key, event_type, provider, title, payload, status, error_message, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event_key,
                    event_type,
                    provider,
                    title,
                    json.dumps(payload, ensure_ascii=False),
                    status,
                    error_message,
                    utc_now_iso(),
                ),
            )
            row = conn.execute("SELECT * FROM notification_events WHERE id = ?", (int(cur.lastrowid),)).fetchone()
        return self._decode_notification_event(row)

    def notification_event_sent(self, event_key: str, provider: str) -> bool:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM notification_events WHERE event_key = ? AND provider = ? AND status = 'sent' LIMIT 1",
                (event_key, provider),
            ).fetchone()
        return row is not None

    def update_notification_event(
        self,
        event_id: int,
        *,
        status: str,
        error_message: str | None = None,
        sent: bool = False,
    ) -> dict[str, Any] | None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE notification_events SET status = ?, error_message = ?, sent_at = ? WHERE id = ?",
                (status, error_message, utc_now_iso() if sent else None, event_id),
            )
            row = conn.execute("SELECT * FROM notification_events WHERE id = ?", (event_id,)).fetchone()
        return self._decode_notification_event(row) if row else None

    def list_notification_events(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM notification_events ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [self._decode_notification_event(row) for row in rows]

    def _decode_notification_event(self, row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data["payload"] = json.loads(data["payload"])
        return data

    def delete_config(self, key: str) -> bool:
        with self.connect() as conn:
            cur = conn.execute("DELETE FROM config WHERE key = ?", (key,))
        self.secrets.delete_namespace(config_secret_namespace(key))
        return cur.rowcount > 0

    def create_organize_target(self, data: dict[str, Any]) -> dict[str, Any]:
        now = utc_now_iso()
        payload = dict(data)
        with self.connect() as conn:
            has_targets = conn.execute("SELECT 1 FROM organize_targets LIMIT 1").fetchone() is not None
            is_default = bool(payload.get("is_default")) or not has_targets
            if is_default:
                conn.execute("UPDATE organize_targets SET is_default = 0")
            cur = conn.execute(
                """
                INSERT INTO organize_targets(name, path, media_type, is_default, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    payload["name"],
                    payload["path"],
                    payload.get("media_type") or "anime",
                    1 if is_default else 0,
                    1 if payload.get("enabled", True) else 0,
                    now,
                ),
            )
            target_id = int(cur.lastrowid)
        payload["id"] = target_id
        payload["is_default"] = is_default
        payload["enabled"] = bool(payload.get("enabled", True))
        payload["created_at"] = now
        payload["updated_at"] = None
        return payload

    def list_organize_targets(self, include_disabled: bool = True) -> list[dict[str, Any]]:
        with self.connect() as conn:
            if include_disabled:
                rows = conn.execute(
                    "SELECT * FROM organize_targets ORDER BY is_default DESC, enabled DESC, id ASC"
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM organize_targets
                    WHERE enabled = 1
                    ORDER BY is_default DESC, id ASC
                    """
                ).fetchall()
        return [self._decode_organize_target(row) for row in rows]

    def get_organize_target(self, target_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM organize_targets WHERE id = ?", (target_id,)).fetchone()
        return self._decode_organize_target(row) if row else None

    def default_organize_target(self) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM organize_targets
                WHERE enabled = 1
                ORDER BY is_default DESC, id ASC
                LIMIT 1
                """
            ).fetchone()
        return self._decode_organize_target(row) if row else None

    def update_organize_target(self, target_id: int, data: dict[str, Any]) -> dict[str, Any] | None:
        existing = self.get_organize_target(target_id)
        if not existing:
            return None
        now = utc_now_iso()
        payload = dict(data)
        is_default = bool(payload.get("is_default"))
        with self.connect() as conn:
            if is_default:
                conn.execute("UPDATE organize_targets SET is_default = 0")
            conn.execute(
                """
                UPDATE organize_targets
                SET name = ?, path = ?, media_type = ?, is_default = ?, enabled = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    payload["name"],
                    payload["path"],
                    payload.get("media_type") or "anime",
                    1 if is_default else 0,
                    1 if payload.get("enabled", True) else 0,
                    now,
                    target_id,
                ),
            )
        payload["id"] = target_id
        payload["is_default"] = is_default
        payload["enabled"] = bool(payload.get("enabled", True))
        payload["created_at"] = existing["created_at"]
        payload["updated_at"] = now
        return payload

    def delete_organize_target(self, target_id: int) -> bool:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM organize_targets WHERE id = ?", (target_id,)).fetchone()
            if row is None:
                return False
            was_default = bool(row["is_default"])
            conn.execute("DELETE FROM organize_targets WHERE id = ?", (target_id,))
            if was_default:
                replacement = conn.execute(
                    """
                    SELECT id FROM organize_targets
                    WHERE enabled = 1
                    ORDER BY id ASC
                    LIMIT 1
                    """
                ).fetchone()
                if replacement is not None:
                    conn.execute(
                        "UPDATE organize_targets SET is_default = 1 WHERE id = ?",
                        (replacement["id"],),
                    )
            return True

    def set_default_organize_target(self, target_id: int) -> dict[str, Any] | None:
        target = self.get_organize_target(target_id)
        if not target:
            return None
        with self.connect() as conn:
            conn.execute("UPDATE organize_targets SET is_default = 0")
            conn.execute(
                "UPDATE organize_targets SET is_default = 1, enabled = 1, updated_at = ? WHERE id = ?",
                (utc_now_iso(), target_id),
            )
        return self.get_organize_target(target_id)

    def _decode_organize_target(self, row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data["is_default"] = bool(data["is_default"])
        data["enabled"] = bool(data["enabled"])
        return data

    def create_subscription(self, data: dict[str, Any]) -> dict[str, Any]:
        now = utc_now_iso()
        payload = self._normalize_subscription_data(data)
        public, secrets = split_subscription_payload(payload)
        enabled = 1 if payload.get("enabled", True) else 0
        with self.connect() as conn:
            cur = conn.execute(
                "INSERT INTO subscriptions(name, data, enabled, created_at) VALUES (?, ?, ?, ?)",
                (payload["name"], json.dumps(public, ensure_ascii=False), enabled, now),
            )
            subscription_id = int(cur.lastrowid)
        namespace = self._subscription_secret_namespace(subscription_id)
        try:
            self.secrets.replace_namespace(namespace, secrets)
        except Exception:
            with self.connect() as conn:
                conn.execute("DELETE FROM subscriptions WHERE id = ?", (subscription_id,))
            raise
        payload["id"] = subscription_id
        payload["created_at"] = now
        payload["updated_at"] = None
        return payload

    def list_subscriptions(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute("SELECT * FROM subscriptions ORDER BY id DESC").fetchall()
        namespaces = {
            int(row["id"]): self._subscription_secret_namespace(int(row["id"])) for row in rows
        }
        secrets = self.secrets.namespaces(namespaces.values())
        subscriptions: list[dict[str, Any]] = []
        for row in rows:
            namespace = namespaces[int(row["id"])]
            subscriptions.append(self._decode_subscription(row, secrets.get(namespace, {})))
        return subscriptions

    def get_subscription(self, subscription_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
        if not row:
            return None
        return self._decode_subscription(row)

    def update_subscription(self, subscription_id: int, data: dict[str, Any]) -> dict[str, Any] | None:
        existing = self.get_subscription(subscription_id)
        if not existing:
            return None
        now = utc_now_iso()
        payload = self._normalize_subscription_data(data)
        public, secrets = split_subscription_payload(payload)
        enabled = 1 if payload.get("enabled", True) else 0
        namespace = self._subscription_secret_namespace(subscription_id)
        previous = self.secrets.namespace(namespace)
        self.secrets.replace_namespace(namespace, secrets)
        try:
            with self.connect() as conn:
                conn.execute(
                    """
                    UPDATE subscriptions
                    SET name = ?, data = ?, enabled = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (
                        payload["name"],
                        json.dumps(public, ensure_ascii=False),
                        enabled,
                        now,
                        subscription_id,
                    ),
                )
        except Exception:
            self.secrets.replace_namespace(namespace, previous)
            raise
        payload["id"] = subscription_id
        payload["created_at"] = existing["created_at"]
        payload["updated_at"] = now
        return payload

    def _normalize_subscription_data(self, data: dict[str, Any]) -> dict[str, Any]:
        payload = dict(data)
        raw_episode_start = payload.get("episode_start")
        try:
            episode_start = int(raw_episode_start)
        except (TypeError, ValueError):
            episode_start = 1
        payload["episode_start"] = episode_start if episode_start >= 1 else 1
        return payload

    @staticmethod
    def _subscription_secret_namespace(subscription_id: int) -> str:
        return f"subscription:{subscription_id}"

    @staticmethod
    def _history_secret_namespace(fingerprint: str) -> str:
        return f"download-history:{fingerprint}"

    @staticmethod
    def _match_secret_namespace(subscription_id: int, fingerprint: str) -> str:
        return f"subscription-match:{subscription_id}:{fingerprint}"

    def _decode_subscription(
        self, row: sqlite3.Row, secret_values: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        public = json.loads(row["data"])
        secrets = (
            secret_values
            if secret_values is not None
            else self.secrets.namespace(self._subscription_secret_namespace(int(row["id"])))
        )
        data = self._normalize_subscription_data(merge_subscription_payload(public, secrets))
        data["id"] = row["id"]
        data["enabled"] = bool(row["enabled"])
        data["created_at"] = row["created_at"]
        data["updated_at"] = row["updated_at"]
        return data

    def delete_subscription(self, subscription_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            existing = conn.execute("SELECT id FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
            if existing is None:
                return None

            match_rows = conn.execute(
                "SELECT id, fingerprint, result, parsed_title FROM subscription_matches WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            history_rows = conn.execute(
                "SELECT fingerprint FROM download_history WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            resource_target_ids = [f"subscription-match:{row['id']}" for row in match_rows]
            match_titles = self._titles_from_match_rows(match_rows)
            organize_preview_ids = self._organize_preview_ids_for_titles(conn, match_titles)
            organize_history_ids = self._organize_history_ids_for_subscription(conn, subscription_id)

            subscription_deleted = conn.execute("DELETE FROM subscriptions WHERE id = ?", (subscription_id,))
            matches_deleted = conn.execute("DELETE FROM subscription_matches WHERE subscription_id = ?", (subscription_id,))
            refreshes_deleted = conn.execute("DELETE FROM subscription_refresh_history WHERE subscription_id = ?", (subscription_id,))
            subscription_metadata_deleted = conn.execute(
                """
                DELETE FROM metadata_bindings
                WHERE target_type = ? AND target_id = ?
                """,
                ("subscription", str(subscription_id)),
            )
            resource_metadata_deleted = 0
            if resource_target_ids:
                placeholders = ",".join("?" for _ in resource_target_ids)
                cur = conn.execute(
                    f"""
                    DELETE FROM metadata_bindings
                    WHERE target_type = ? AND target_id IN ({placeholders})
                    """,
                    ("resource", *resource_target_ids),
                )
                resource_metadata_deleted = max(cur.rowcount, 0)
            download_history_deleted = self._delete_download_history_for_subscription(conn, subscription_id)
            counts = {
                "subscriptions_deleted": max(subscription_deleted.rowcount, 0),
                "subscription_matches_deleted": max(matches_deleted.rowcount, 0),
                "subscription_refreshes_deleted": max(refreshes_deleted.rowcount, 0),
                "metadata_bindings_deleted": max(subscription_metadata_deleted.rowcount, 0) + resource_metadata_deleted,
                "organize_previews_deleted": self._delete_rows_by_ids(conn, "organize_previews", organize_preview_ids),
                "organize_history_deleted": self._delete_rows_by_ids(conn, "organize_history", organize_history_ids),
                "download_history_deleted": download_history_deleted,
            }
        namespaces = [self._subscription_secret_namespace(subscription_id)]
        namespaces.extend(
            self._match_secret_namespace(subscription_id, str(row["fingerprint"])) for row in match_rows
        )
        namespaces.extend(self._history_secret_namespace(str(row["fingerprint"])) for row in history_rows)
        self.secrets.delete_namespaces(namespaces)
        return counts

    def history_exists(self, fingerprint: str) -> bool:
        with self.connect() as conn:
            row = conn.execute("SELECT 1 FROM download_history WHERE fingerprint = ?", (fingerprint,)).fetchone()
        return row is not None

    def get_history_by_fingerprint(self, fingerprint: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM download_history WHERE fingerprint = ?", (fingerprint,)).fetchone()
        return self._decode_history(row) if row is not None else None

    def get_history(self, history_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM download_history WHERE id = ?", (history_id,)).fetchone()
        return self._decode_history(row) if row is not None else None

    def add_history(
        self,
        *,
        fingerprint: str,
        title: str,
        source: str,
        download_url: str | None,
        status: str,
        subscription_id: int | None = None,
        qbittorrent_hash: str | None = None,
        downloader_type: str = "qbittorrent",
        remote_task_id: str | None = None,
        torrent_name: str | None = None,
        save_path: str | None = None,
    ) -> int:
        namespace = self._history_secret_namespace(fingerprint)
        previous = self.secrets.namespace(namespace)
        if download_url:
            self.secrets.set_many({namespace: {"download_url": download_url}})
        try:
            with self.connect() as conn:
                conn.execute(
                    """
                    INSERT INTO download_history
                      (fingerprint, title, source, download_url, qbittorrent_hash, downloader_type, remote_task_id, torrent_name, save_path, subscription_id, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(fingerprint) DO UPDATE SET
                      title=excluded.title,
                      source=excluded.source,
                      download_url=NULL,
                      qbittorrent_hash=COALESCE(excluded.qbittorrent_hash, download_history.qbittorrent_hash),
                      downloader_type=COALESCE(excluded.downloader_type, download_history.downloader_type),
                      remote_task_id=COALESCE(excluded.remote_task_id, download_history.remote_task_id),
                      torrent_name=COALESCE(excluded.torrent_name, download_history.torrent_name),
                      save_path=COALESCE(excluded.save_path, download_history.save_path),
                      subscription_id=COALESCE(excluded.subscription_id, download_history.subscription_id),
                      status=excluded.status
                    """,
                    (
                        fingerprint,
                        title,
                        source,
                        None,
                        qbittorrent_hash,
                        downloader_type,
                        remote_task_id,
                        torrent_name,
                        save_path,
                        subscription_id,
                        status,
                        utc_now_iso(),
                    ),
                )
                row = conn.execute(
                    "SELECT id FROM download_history WHERE fingerprint = ?",
                    (fingerprint,),
                ).fetchone()
        except Exception:
            if download_url:
                self.secrets.replace_namespace(namespace, previous)
            raise
        return int(row["id"])

    def list_history(self, subscription_id: int | None = None, limit: int = 200) -> list[dict[str, Any]]:
        with self.connect() as conn:
            if subscription_id is None:
                rows = conn.execute(
                    "SELECT * FROM download_history ORDER BY id DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM download_history
                    WHERE subscription_id = ?
                    ORDER BY id DESC
                    LIMIT ?
                    """,
                    (subscription_id, limit),
                ).fetchall()
        namespaces = {
            str(row["fingerprint"]): self._history_secret_namespace(str(row["fingerprint"]))
            for row in rows
        }
        secrets = self.secrets.namespaces(namespaces.values())
        return [
            self._decode_history(row, secrets.get(namespaces[str(row["fingerprint"])], {}))
            for row in rows
        ]

    def update_history_status(self, history_id: int, status: str) -> bool:
        with self.connect() as conn:
            cur = conn.execute(
                "UPDATE download_history SET status = ? WHERE id = ?",
                (status, history_id),
            )
            return cur.rowcount > 0

    def update_history_qbittorrent_task(
        self,
        history_id: int,
        *,
        qbittorrent_hash: str | None = None,
        torrent_name: str | None = None,
        save_path: str | None = None,
        downloader_type: str | None = None,
        remote_task_id: str | None = None,
    ) -> bool:
        with self.connect() as conn:
            cur = conn.execute(
                """
                UPDATE download_history
                SET qbittorrent_hash = COALESCE(?, qbittorrent_hash),
                    downloader_type = COALESCE(?, downloader_type),
                    remote_task_id = COALESCE(?, remote_task_id),
                    torrent_name = COALESCE(?, torrent_name),
                    save_path = COALESCE(?, save_path)
                WHERE id = ?
                """,
                (qbittorrent_hash, downloader_type, remote_task_id, torrent_name, save_path, history_id),
            )
            return cur.rowcount > 0

    def delete_history(self, history_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM download_history WHERE id = ?", (history_id,)).fetchone()
            if row is None:
                return None
            conn.execute("DELETE FROM download_history WHERE id = ?", (history_id,))
            self._reset_match_statuses_for_history_rows(conn, [row])
        decoded = self._decode_history(row)
        self.secrets.delete_namespace(self._history_secret_namespace(str(row["fingerprint"])))
        return decoded

    def clear_download_history(self, subscription_id: int | None = None) -> int:
        with self.connect() as conn:
            if subscription_id is None:
                rows = conn.execute("SELECT * FROM download_history").fetchall()
                conn.execute("DELETE FROM download_history")
            else:
                rows = conn.execute(
                    "SELECT * FROM download_history WHERE subscription_id = ?",
                    (subscription_id,),
                ).fetchall()
                conn.execute(
                    "DELETE FROM download_history WHERE subscription_id = ?",
                    (subscription_id,),
                )
            self._reset_match_statuses_for_history_rows(conn, rows)
        self.secrets.delete_namespaces(
            [self._history_secret_namespace(str(row["fingerprint"])) for row in rows]
        )
        return len(rows)

    def _decode_history(
        self, row: sqlite3.Row, secret_values: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        data = dict(row)
        secrets = (
            secret_values
            if secret_values is not None
            else self.secrets.namespace(self._history_secret_namespace(str(row["fingerprint"])))
        )
        if "download_url" in secrets:
            data["download_url"] = secrets["download_url"]
        return data

    def clear_subscription_refresh_history(self, subscription_id: int) -> int:
        with self.connect() as conn:
            return self._delete_subscription_refreshes(conn, subscription_id)

    def clear_subscription_match_history(self, subscription_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            existing = conn.execute("SELECT id FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
            if existing is None:
                return None
            match_rows = conn.execute(
                "SELECT id, fingerprint FROM subscription_matches WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            resource_target_ids = [f"subscription-match:{row['id']}" for row in match_rows]
            counts = {
                "subscription_matches_deleted": self._delete_subscription_matches(conn, subscription_id),
                "metadata_bindings_deleted": self._delete_resource_metadata_bindings(conn, resource_target_ids),
            }
        self.secrets.delete_namespaces(
            [self._match_secret_namespace(subscription_id, str(row["fingerprint"])) for row in match_rows]
        )
        return counts

    def clear_subscription_recognition(self, subscription_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            existing = conn.execute("SELECT id FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
            if existing is None:
                return None
            match_rows = conn.execute(
                "SELECT id FROM subscription_matches WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            target_pairs = [("subscription", str(subscription_id))]
            target_pairs.extend(("resource", f"subscription-match:{row['id']}") for row in match_rows)
            subject_keys = self._metadata_subject_keys_for_targets(conn, target_pairs)
            resource_target_ids = [target_id for target_type, target_id in target_pairs if target_type == "resource"]
            subscription_deleted = self._delete_subscription_metadata_binding(conn, subscription_id)
            resource_deleted = self._delete_resource_metadata_bindings(conn, resource_target_ids)
            return {
                "metadata_bindings_deleted": subscription_deleted + resource_deleted,
                "organize_previews_deleted": 0,
                "organize_history_deleted": 0,
                "subscription_matches_deleted": 0,
                "download_history_deleted": 0,
                "subscription_refreshes_deleted": 0,
                "plex_mappings_deleted": self._delete_plex_mappings(conn, subject_keys),
            }

    def clear_subscription_organize_records(self, subscription_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            existing = conn.execute("SELECT id FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
            if existing is None:
                return None
            match_rows = conn.execute(
                "SELECT id, result, parsed_title FROM subscription_matches WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            match_titles = self._titles_from_match_rows(match_rows)
            organize_preview_ids = self._organize_preview_ids_for_titles(conn, match_titles)
            organize_history_ids = self._organize_history_ids_for_subscription(conn, subscription_id)
            return {
                "organize_previews_deleted": self._delete_rows_by_ids(conn, "organize_previews", organize_preview_ids),
                "organize_history_deleted": self._delete_rows_by_ids(conn, "organize_history", organize_history_ids),
            }

    def delete_episode_download_record(self, subscription_id: int, match_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM subscription_matches
                WHERE subscription_id = ? AND id = ?
                """,
                (subscription_id, match_id),
            ).fetchone()
            if row is None:
                return None
            history_rows = conn.execute(
                """
                SELECT * FROM download_history
                WHERE subscription_id = ? AND fingerprint = ?
                """,
                (subscription_id, row["fingerprint"]),
            ).fetchall()
            conn.execute(
                """
                DELETE FROM download_history
                WHERE subscription_id = ? AND fingerprint = ?
                """,
                (subscription_id, row["fingerprint"]),
            )
            self._reset_match_statuses_for_history_rows(conn, history_rows)
            counts = {"download_history_deleted": len(history_rows)}
        self.secrets.delete_namespaces(
            [self._history_secret_namespace(str(item["fingerprint"])) for item in history_rows]
        )
        return counts

    def delete_episode_organize_records(self, subscription_id: int, match_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT id, fingerprint, result, parsed_title FROM subscription_matches
                WHERE subscription_id = ? AND id = ?
                """,
                (subscription_id, match_id),
            ).fetchone()
            if row is None:
                return None
            titles = self._titles_from_match_rows([row])
            organize_preview_ids = self._organize_preview_ids_for_titles(conn, titles)
            organize_history_ids = self._organize_history_ids_for_subscription(
                conn,
                subscription_id,
                fingerprints=[row["fingerprint"]],
            )
            return {
                "organize_previews_deleted": self._delete_rows_by_ids(conn, "organize_previews", organize_preview_ids),
                "organize_history_deleted": self._delete_rows_by_ids(conn, "organize_history", organize_history_ids),
            }

    def reset_episode_state(self, subscription_id: int, match_id: int) -> dict[str, int] | None:
        download_counts = self.delete_episode_download_record(subscription_id, match_id)
        if download_counts is None:
            return None
        organize_counts = self.delete_episode_organize_records(subscription_id, match_id) or {}
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE subscription_matches
                SET status = ?
                WHERE subscription_id = ? AND id = ?
                """,
                ("new", subscription_id, match_id),
            )
        return {
            "download_history_deleted": download_counts.get("download_history_deleted", 0),
            "organize_previews_deleted": organize_counts.get("organize_previews_deleted", 0),
            "organize_history_deleted": organize_counts.get("organize_history_deleted", 0),
        }

    def reset_subscription_state(self, subscription_id: int) -> dict[str, int] | None:
        with self.connect() as conn:
            existing = conn.execute("SELECT id FROM subscriptions WHERE id = ?", (subscription_id,)).fetchone()
            if existing is None:
                return None

            match_rows = conn.execute(
                """
                SELECT id, fingerprint, result, parsed_title
                FROM subscription_matches
                WHERE subscription_id = ?
                """,
                (subscription_id,),
            ).fetchall()
            history_rows = conn.execute(
                "SELECT fingerprint FROM download_history WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
            resource_target_ids = [f"subscription-match:{row['id']}" for row in match_rows]
            match_titles = self._titles_from_match_rows(match_rows)
            organize_preview_ids = self._organize_preview_ids_for_titles(conn, match_titles)
            organize_history_ids = self._organize_history_ids_for_subscription(
                conn,
                subscription_id,
                fingerprints=[row["fingerprint"] for row in match_rows],
            )

            counts = {
                "download_history_deleted": self._delete_download_history_for_subscription(conn, subscription_id),
                "subscription_matches_deleted": self._delete_subscription_matches(conn, subscription_id),
                "subscription_refreshes_deleted": self._delete_subscription_refreshes(conn, subscription_id),
                "metadata_bindings_deleted": self._delete_resource_metadata_bindings(conn, resource_target_ids),
                "organize_previews_deleted": self._delete_rows_by_ids(conn, "organize_previews", organize_preview_ids),
                "organize_history_deleted": self._delete_rows_by_ids(conn, "organize_history", organize_history_ids),
            }
        namespaces = [
            self._match_secret_namespace(subscription_id, str(row["fingerprint"])) for row in match_rows
        ]
        namespaces.extend(self._history_secret_namespace(str(row["fingerprint"])) for row in history_rows)
        self.secrets.delete_namespaces(namespaces)
        return counts

    def clear_all_history_state(self) -> dict[str, int]:
        with self.connect() as conn:
            history_rows = conn.execute("SELECT fingerprint FROM download_history").fetchall()
            match_rows = conn.execute(
                "SELECT subscription_id, fingerprint FROM subscription_matches"
            ).fetchall()
            counts = {
                "download_history_deleted": self._delete_all_rows(conn, "download_history"),
                "subscription_matches_deleted": self._delete_all_rows(conn, "subscription_matches"),
                "subscription_refreshes_deleted": self._delete_all_rows(conn, "subscription_refresh_history"),
                "metadata_bindings_deleted": self._delete_subscription_match_metadata_bindings(conn),
                "organize_previews_deleted": self._delete_all_rows(conn, "organize_previews"),
                "organize_history_deleted": self._delete_all_rows(conn, "organize_history"),
            }
        namespaces = [self._history_secret_namespace(str(row["fingerprint"])) for row in history_rows]
        namespaces.extend(
            self._match_secret_namespace(int(row["subscription_id"]), str(row["fingerprint"]))
            for row in match_rows
        )
        self.secrets.delete_namespaces(namespaces)
        return counts

    def clear_organize_history(self) -> dict[str, int]:
        with self.connect() as conn:
            counts = {
                "organize_previews_deleted": self._delete_all_rows(conn, "organize_previews"),
                "organize_history_deleted": self._delete_all_rows(conn, "organize_history"),
            }
        return counts

    def count_failed_organize_history(self, subscription_id: int | None = None) -> int:
        with self.connect() as conn:
            if subscription_id is None:
                row = conn.execute(
                    "SELECT COUNT(*) AS count FROM organize_history WHERE status = 'error'"
                ).fetchone()
            else:
                row = conn.execute(
                    "SELECT COUNT(*) AS count FROM organize_history WHERE status = 'error' AND subscription_id = ?",
                    (subscription_id,),
                ).fetchone()
        return int(row["count"] if row else 0)

    def delete_failed_organize_history(self, subscription_id: int | None = None) -> int:
        with self.connect() as conn:
            if subscription_id is None:
                cur = conn.execute("DELETE FROM organize_history WHERE status = 'error'")
            else:
                cur = conn.execute(
                    "DELETE FROM organize_history WHERE status = 'error' AND subscription_id = ?",
                    (subscription_id,),
                )
        return max(cur.rowcount, 0)

    def _reset_match_statuses_for_history_rows(self, conn: sqlite3.Connection, rows: list[sqlite3.Row]) -> None:
        for row in rows:
            subscription_id = row["subscription_id"]
            if subscription_id is None:
                continue
            conn.execute(
                """
                UPDATE subscription_matches
                SET status = ?
                WHERE subscription_id = ? AND fingerprint = ?
                """,
                ("new", subscription_id, row["fingerprint"]),
            )

    def _delete_download_history_for_subscription(self, conn: sqlite3.Connection, subscription_id: int) -> int:
        cur = conn.execute("DELETE FROM download_history WHERE subscription_id = ?", (subscription_id,))
        return max(cur.rowcount, 0)

    def _delete_subscription_matches(self, conn: sqlite3.Connection, subscription_id: int) -> int:
        cur = conn.execute("DELETE FROM subscription_matches WHERE subscription_id = ?", (subscription_id,))
        return max(cur.rowcount, 0)

    def _delete_subscription_refreshes(self, conn: sqlite3.Connection, subscription_id: int) -> int:
        cur = conn.execute("DELETE FROM subscription_refresh_history WHERE subscription_id = ?", (subscription_id,))
        return max(cur.rowcount, 0)

    def _delete_resource_metadata_bindings(self, conn: sqlite3.Connection, target_ids: list[str]) -> int:
        if not target_ids:
            return 0
        placeholders = ",".join("?" for _ in target_ids)
        cur = conn.execute(
            f"""
            DELETE FROM metadata_bindings
            WHERE target_type = ? AND target_id IN ({placeholders})
            """,
            ("resource", *target_ids),
        )
        return max(cur.rowcount, 0)

    def _delete_subscription_metadata_binding(self, conn: sqlite3.Connection, subscription_id: int) -> int:
        cur = conn.execute(
            """
            DELETE FROM metadata_bindings
            WHERE target_type = ? AND target_id = ?
            """,
            ("subscription", str(subscription_id)),
        )
        return max(cur.rowcount, 0)

    def _metadata_subject_keys_for_targets(self, conn: sqlite3.Connection, target_pairs: list[tuple[str, str]]) -> list[str]:
        subject_keys: list[str] = []
        for target_type, target_id in target_pairs:
            rows = conn.execute(
                """
                SELECT bangumi_id, tmdb_id
                FROM metadata_bindings
                WHERE target_type = ? AND target_id = ?
                """,
                (target_type, target_id),
            ).fetchall()
            for row in rows:
                if row["bangumi_id"]:
                    subject_keys.append(f"bangumi:{row['bangumi_id']}")
                if row["tmdb_id"]:
                    subject_keys.append(f"tmdb:{row['tmdb_id']}")
        return sorted(set(subject_keys))

    def _delete_plex_mappings(self, conn: sqlite3.Connection, subject_keys: list[str]) -> int:
        if not subject_keys:
            return 0
        placeholders = ",".join("?" for _ in subject_keys)
        cur = conn.execute(f"DELETE FROM plex_mappings WHERE subject_key IN ({placeholders})", subject_keys)
        return max(cur.rowcount, 0)

    def _delete_subscription_match_metadata_bindings(self, conn: sqlite3.Connection) -> int:
        cur = conn.execute(
            """
            DELETE FROM metadata_bindings
            WHERE target_type = ? AND target_id LIKE ?
            """,
            ("resource", "subscription-match:%"),
        )
        return max(cur.rowcount, 0)

    def _delete_all_rows(self, conn: sqlite3.Connection, table_name: str) -> int:
        cur = conn.execute(f"DELETE FROM {table_name}")
        return max(cur.rowcount, 0)

    def _delete_rows_by_ids(self, conn: sqlite3.Connection, table_name: str, row_ids: list[int]) -> int:
        if not row_ids:
            return 0
        placeholders = ",".join("?" for _ in row_ids)
        cur = conn.execute(f"DELETE FROM {table_name} WHERE id IN ({placeholders})", row_ids)
        return max(cur.rowcount, 0)

    def _titles_from_match_rows(self, rows: list[sqlite3.Row]) -> list[str]:
        titles: list[str] = []
        for row in rows:
            with_title_payloads = (row["result"], row["parsed_title"])
            for payload in with_title_payloads:
                try:
                    data = json.loads(payload)
                except (TypeError, ValueError):
                    continue
                for key in ("title", "original_title"):
                    value = data.get(key)
                    if isinstance(value, str) and value.strip():
                        titles.append(value.strip())
        return sorted(set(titles), key=str.casefold)

    def _organize_preview_ids_for_titles(self, conn: sqlite3.Connection, titles: list[str]) -> list[int]:
        if not titles:
            return []
        rows = conn.execute("SELECT id, request, preview FROM organize_previews").fetchall()
        return [
            int(row["id"])
            for row in rows
            if self._json_payload_mentions_titles([row["request"], row["preview"]], titles)
        ]

    def _organize_history_ids_for_titles(self, conn: sqlite3.Connection, titles: list[str]) -> list[int]:
        if not titles:
            return []
        rows = conn.execute("SELECT id, source_path, destination_path, preview FROM organize_history").fetchall()
        ids: list[int] = []
        for row in rows:
            payloads = [row["preview"], json.dumps({"source_path": row["source_path"], "destination_path": row["destination_path"]}, ensure_ascii=False)]
            if self._json_payload_mentions_titles(payloads, titles):
                ids.append(int(row["id"]))
        return ids

    def _organize_history_ids_for_subscription(
        self,
        conn: sqlite3.Connection,
        subscription_id: int,
        *,
        fingerprints: list[str] | None = None,
    ) -> list[int]:
        ids = {
            int(row["id"])
            for row in conn.execute(
                "SELECT id FROM organize_history WHERE subscription_id = ?",
                (subscription_id,),
            ).fetchall()
        }
        legacy_rows = conn.execute(
            """
            SELECT id, source_path, destination_path, preview
            FROM organize_history
            WHERE subscription_id IS NULL
            """
        ).fetchall()
        fingerprint_values = [item for item in (fingerprints or []) if item]
        if fingerprint_values:
            for row in legacy_rows:
                payloads = [
                    row["preview"],
                    json.dumps({"source_path": row["source_path"], "destination_path": row["destination_path"]}, ensure_ascii=False),
                ]
                if self._json_payload_mentions_titles(payloads, fingerprint_values):
                    ids.add(int(row["id"]))
        return sorted(ids)

    def _json_payload_mentions_titles(self, payloads: list[str], titles: list[str]) -> bool:
        haystack_parts: list[str] = []
        for payload in payloads:
            try:
                decoded = json.loads(payload)
                haystack_parts.append(json.dumps(decoded, ensure_ascii=False).casefold())
            except (TypeError, ValueError):
                haystack_parts.append(str(payload).casefold())
        haystack = "\n".join(haystack_parts)
        return any(title.casefold() in haystack for title in titles)

    def upsert_subscription_match(
        self,
        *,
        subscription_id: int,
        fingerprint: str,
        result: dict[str, Any],
        parsed_title: dict[str, Any],
        status: str,
    ) -> dict[str, Any]:
        now = utc_now_iso()
        public, secrets = split_result_payload(result)
        namespace = self._match_secret_namespace(subscription_id, fingerprint)
        previous = self.secrets.namespace(namespace)
        self.secrets.replace_namespace(namespace, secrets)
        try:
            with self.connect() as conn:
                conn.execute(
                    """
                    INSERT INTO subscription_matches(
                      subscription_id, fingerprint, result, parsed_title, status, first_seen_at, last_seen_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(subscription_id, fingerprint) DO UPDATE SET
                      result=excluded.result,
                      parsed_title=excluded.parsed_title,
                      status=excluded.status,
                      last_seen_at=excluded.last_seen_at
                    """,
                    (
                        subscription_id,
                        fingerprint,
                        json.dumps(public, ensure_ascii=False),
                        json.dumps(parsed_title, ensure_ascii=False),
                        status,
                        now,
                        now,
                    ),
                )
                row = conn.execute(
                    "SELECT * FROM subscription_matches WHERE subscription_id = ? AND fingerprint = ?",
                    (subscription_id, fingerprint),
                ).fetchone()
        except Exception:
            self.secrets.replace_namespace(namespace, previous)
            raise
        return self._decode_subscription_match(row)

    def list_subscription_matches(self, subscription_id: int, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM subscription_matches
                WHERE subscription_id = ?
                ORDER BY last_seen_at DESC, id DESC
                LIMIT ?
                """,
                (subscription_id, limit),
            ).fetchall()
        namespaces = {
            str(row["fingerprint"]): self._match_secret_namespace(
                subscription_id, str(row["fingerprint"])
            )
            for row in rows
        }
        secrets = self.secrets.namespaces(namespaces.values())
        return [
            self._decode_subscription_match(
                row, secrets.get(namespaces[str(row["fingerprint"])], {})
            )
            for row in rows
        ]

    def get_subscription_match(self, subscription_id: int, match_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM subscription_matches
                WHERE subscription_id = ? AND id = ?
                """,
                (subscription_id, match_id),
            ).fetchone()
        return self._decode_subscription_match(row) if row else None

    def update_subscription_match_status(self, subscription_id: int, fingerprint: str, status: str) -> bool:
        with self.connect() as conn:
            cur = conn.execute(
                """
                UPDATE subscription_matches
                SET status = ?, last_seen_at = ?
                WHERE subscription_id = ? AND fingerprint = ?
                """,
                (status, utc_now_iso(), subscription_id, fingerprint),
            )
            return cur.rowcount > 0

    def _decode_subscription_match(
        self, row: sqlite3.Row, secret_values: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        data = dict(row)
        public = json.loads(data["result"])
        secrets = (
            secret_values
            if secret_values is not None
            else self.secrets.namespace(
                self._match_secret_namespace(
                    int(data["subscription_id"]), str(data["fingerprint"])
                )
            )
        )
        data["result"] = merge_result_payload(public, secrets)
        data["parsed_title"] = json.loads(data["parsed_title"])
        return data

    def add_subscription_refresh_history(
        self,
        *,
        subscription_id: int,
        matched_count: int,
        added_count: int,
        skipped_count: int,
        error_count: int,
        warnings: list[str],
    ) -> dict[str, Any]:
        with self.connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO subscription_refresh_history(
                  subscription_id, matched_count, added_count, skipped_count, error_count, warnings, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    subscription_id,
                    matched_count,
                    added_count,
                    skipped_count,
                    error_count,
                    json.dumps(_compact_refresh_warnings(warnings), ensure_ascii=False),
                    utc_now_iso(),
                ),
            )
            refresh_id = int(cur.lastrowid)
            row = conn.execute(
                "SELECT * FROM subscription_refresh_history WHERE id = ?",
                (refresh_id,),
            ).fetchone()
        if refresh_id % 250 == 0:
            self.prune_transient_history()
        return self._decode_subscription_refresh_history(row)

    def list_subscription_refresh_history(self, subscription_id: int, limit: int = 50) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM subscription_refresh_history
                WHERE subscription_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (subscription_id, limit),
            ).fetchall()
        return [self._decode_subscription_refresh_history(row) for row in rows]

    def _decode_subscription_refresh_history(self, row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data["warnings"] = json.loads(data["warnings"])
        return data

    def add_metadata_binding(self, data: dict[str, Any]) -> int:
        with self.connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO metadata_bindings(target_type, target_id, bangumi_id, tmdb_id, data, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    data["target_type"],
                    data["target_id"],
                    data.get("bangumi_id"),
                    data.get("tmdb_id"),
                    json.dumps(data, ensure_ascii=False),
                    utc_now_iso(),
                ),
            )
            return int(cur.lastrowid)

    def bind_subscription_metadata(
        self,
        subscription_id: int,
        data: dict[str, Any],
        *,
        metadata_source: str,
        metadata_episode_count: int | None,
    ) -> int | None:
        """Append the audit row and update metadata-derived subscription fields atomically."""
        now = utc_now_iso()
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM subscriptions WHERE id = ?",
                (subscription_id,),
            ).fetchone()
            if row is None:
                return None

            subscription_data = self._normalize_subscription_data(json.loads(row["data"]))
            current_total = subscription_data.get("total_episodes")
            valid_metadata_count = (
                isinstance(metadata_episode_count, int)
                and not isinstance(metadata_episode_count, bool)
                and metadata_episode_count > 0
            )
            if valid_metadata_count and (
                not isinstance(current_total, int) or metadata_episode_count >= current_total
            ):
                subscription_data["metadata_episode_count"] = metadata_episode_count
                if not isinstance(current_total, int) or metadata_episode_count > current_total:
                    subscription_data["total_episodes"] = metadata_episode_count
                    subscription_data["total_episodes_source"] = metadata_source

            cur = conn.execute(
                """
                INSERT INTO metadata_bindings(target_type, target_id, bangumi_id, tmdb_id, data, created_at)
                VALUES ('subscription', ?, ?, ?, ?, ?)
                """,
                (
                    str(subscription_id),
                    data.get("bangumi_id"),
                    data.get("tmdb_id"),
                    json.dumps(data, ensure_ascii=False),
                    now,
                ),
            )
            conn.execute(
                """
                UPDATE subscriptions
                SET data = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    json.dumps(subscription_data, ensure_ascii=False),
                    now,
                    subscription_id,
                ),
            )
            return int(cur.lastrowid)

    def list_metadata_bindings(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM metadata_bindings ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [self._decode_metadata_binding(row) for row in rows]

    def list_metadata_bindings_for_target(
        self,
        target_type: str,
        target_id: str,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM metadata_bindings
                WHERE target_type = ? AND target_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (target_type, target_id, limit),
            ).fetchall()
        return [self._decode_metadata_binding(row) for row in rows]

    def _decode_metadata_binding(self, row: sqlite3.Row) -> dict[str, Any]:
        data = json.loads(row["data"])
        return {
            "id": row["id"],
            "target_type": row["target_type"],
            "target_id": row["target_id"],
            "bangumi_id": row["bangumi_id"],
            "tmdb_id": row["tmdb_id"],
            "selected_title": data.get("selected_title"),
            "original_title": data.get("original_title"),
            "chinese_title": data.get("chinese_title"),
            "aliases": data.get("aliases") or [],
            "summary": data.get("summary"),
            "poster_url": data.get("poster_url"),
            "backdrop_url": data.get("backdrop_url"),
            "poster_local_url": data.get("poster_local_url"),
            "local_poster_path": data.get("local_poster_path"),
            "poster_cached_at": data.get("poster_cached_at"),
            "poster_palette": data.get("poster_palette"),
            "air_date": data.get("air_date"),
            "total_episodes": data.get("total_episodes"),
            "media_type": data.get("media_type"),
            "episode_titles": data.get("episode_titles") or {},
            "rating": data.get("rating"),
            "tags": data.get("tags") or [],
            "season_number": data.get("season_number"),
            "episode_count": data.get("episode_count"),
            "external_ids": data.get("external_ids") or {},
            "notes": data.get("notes"),
            "created_at": row["created_at"],
        }

    def upsert_plex_mapping(self, data: dict[str, Any]) -> int:
        now = utc_now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO plex_mappings(
                  subject_key, show_name, show_year, season_number, episode_offset,
                  special_episode_numbers, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(subject_key) DO UPDATE SET
                  show_name=excluded.show_name,
                  show_year=excluded.show_year,
                  season_number=excluded.season_number,
                  episode_offset=excluded.episode_offset,
                  special_episode_numbers=excluded.special_episode_numbers,
                  updated_at=excluded.updated_at
                """,
                (
                    data["subject_key"],
                    data["show_name"],
                    data.get("show_year"),
                    data["season_number"],
                    data.get("episode_offset", 0),
                    json.dumps(data.get("special_episode_numbers", {}), ensure_ascii=False),
                    now,
                    now,
                ),
            )
            row = conn.execute(
                "SELECT id FROM plex_mappings WHERE subject_key = ?",
                (data["subject_key"],),
            ).fetchone()
            return int(row["id"])

    def list_plex_mappings(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM plex_mappings ORDER BY updated_at DESC, created_at DESC, id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [self._decode_plex_mapping(row) for row in rows]

    def get_plex_mapping(self, subject_key: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM plex_mappings WHERE subject_key = ?",
                (subject_key,),
            ).fetchone()
        return self._decode_plex_mapping(row) if row else None

    def _decode_plex_mapping(self, row: sqlite3.Row) -> dict[str, Any]:
        mapping = {
            "subject_key": row["subject_key"],
            "show_name": row["show_name"],
            "show_year": row["show_year"],
            "season_number": row["season_number"],
            "episode_offset": row["episode_offset"],
            "special_episode_numbers": json.loads(row["special_episode_numbers"]),
        }
        return {
            "id": row["id"],
            "mapping": mapping,
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def add_organize_preview(self, request: dict[str, Any], preview: dict[str, Any]) -> dict[str, Any]:
        now = utc_now_iso()
        with self.connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO organize_previews(request, preview, created_at)
                VALUES (?, ?, ?)
                """,
                (
                    json.dumps(request, ensure_ascii=False),
                    json.dumps(preview, ensure_ascii=False),
                    now,
                ),
            )
            preview_id = int(cur.lastrowid)
            row = conn.execute(
                "SELECT * FROM organize_previews WHERE id = ?",
                (preview_id,),
            ).fetchone()
        return self._decode_organize_preview(row)

    def list_organize_previews(self, limit: int = 50) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM organize_previews ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [self._decode_organize_preview(row) for row in rows]

    def get_organize_preview(self, preview_id: int) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM organize_previews WHERE id = ?",
                (preview_id,),
            ).fetchone()
        return self._decode_organize_preview(row) if row else None

    def _decode_organize_preview(self, row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data["request"] = json.loads(data["request"])
        data["preview"] = json.loads(data["preview"])
        data["preview"]["preview_id"] = data["id"]
        return data

    def add_organize_history(
        self,
        *,
        source_path: str,
        destination_path: str,
        status: str,
        message: str,
        preview: dict[str, Any],
        qbittorrent_task_deleted: bool = False,
        delete_files_from_qbittorrent: bool = False,
        cleanup_attempted: bool = False,
        cleanup_status: str | None = None,
        cleanup_path: str | None = None,
        cleanup_message: str | None = None,
        subscription_id: int | None = None,
        subscription_season: int | None = None,
        resource_explicit_season: int | None = None,
        effective_season: int | None = None,
        season_source: str | None = None,
        manual_override: bool = False,
        override_reason: str | None = None,
    ) -> dict[str, Any]:
        with self.connect() as conn:
            # Serialize the read-before-write idempotency check across workers.
            conn.execute("BEGIN IMMEDIATE")
            if status in {"moved", "skipped"}:
                previous = conn.execute(
                    """
                    SELECT * FROM organize_history
                    WHERE source_path = ? AND destination_path = ? AND subscription_id IS ?
                      AND status IN ('moved', 'skipped')
                    ORDER BY id DESC LIMIT 1
                    """,
                    (source_path, destination_path, subscription_id),
                ).fetchone()
                if previous is not None:
                    existing = self._decode_organize_history(previous)
                    existing["deduplicated"] = True
                    return existing
            if status == "error":
                previous = conn.execute(
                    """
                    SELECT * FROM organize_history
                    WHERE source_path = ? AND destination_path = ? AND subscription_id IS ?
                    ORDER BY id DESC LIMIT 1
                    """,
                    (source_path, destination_path, subscription_id),
                ).fetchone()
                if previous is not None and previous["status"] == "error" and previous["message"] == message:
                    existing = self._decode_organize_history(previous)
                    existing["deduplicated"] = True
                    return existing
            cur = conn.execute(
                """
                INSERT INTO organize_history(
                  source_path, destination_path, status, message, preview,
                  qbittorrent_task_deleted, delete_files_from_qbittorrent,
                  cleanup_attempted, cleanup_status, cleanup_path, cleanup_message,
                  subscription_id,
                  subscription_season, resource_explicit_season, effective_season,
                  season_source, manual_override, override_reason,
                  created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    source_path,
                    destination_path,
                    status,
                    message,
                    json.dumps(preview, ensure_ascii=False),
                    1 if qbittorrent_task_deleted else 0,
                    1 if delete_files_from_qbittorrent else 0,
                    1 if cleanup_attempted else 0,
                    cleanup_status,
                    cleanup_path,
                    cleanup_message,
                    subscription_id,
                    subscription_season,
                    resource_explicit_season,
                    effective_season,
                    season_source,
                    1 if manual_override else 0,
                    override_reason,
                    utc_now_iso(),
                ),
            )
            history_id = int(cur.lastrowid)
            row = conn.execute(
                "SELECT * FROM organize_history WHERE id = ?",
                (history_id,),
            ).fetchone()
        return self._decode_organize_history(row)

    def list_organize_history(
        self,
        limit: int = 200,
        *,
        subscription_id: int | None = None,
    ) -> list[dict[str, Any]]:
        with self.connect() as conn:
            if subscription_id is None:
                rows = conn.execute(
                    "SELECT * FROM organize_history ORDER BY id DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM organize_history
                    WHERE subscription_id = ?
                    ORDER BY id DESC
                    LIMIT ?
                    """,
                    (subscription_id, limit),
                ).fetchall()
        return [self._decode_organize_history(row) for row in rows]

    def successful_organize_history(
        self,
        *,
        source_path: str,
        destination_path: str,
        subscription_id: int | None,
    ) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM organize_history
                WHERE source_path = ? AND destination_path = ? AND subscription_id IS ?
                  AND status IN ('moved', 'skipped')
                ORDER BY id DESC LIMIT 1
                """,
                (source_path, destination_path, subscription_id),
            ).fetchone()
        return self._decode_organize_history(row) if row is not None else None

    def latest_successful_organize_times(self) -> dict[int, str]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT COALESCE(o.subscription_id, h.subscription_id) AS subscription_id,
                       MAX(o.created_at) AS completed_at
                FROM organize_history o
                LEFT JOIN download_history h ON h.id = json_extract(o.preview, '$.download_record_id')
                WHERE o.status = 'moved' AND COALESCE(o.subscription_id, h.subscription_id) IS NOT NULL
                GROUP BY COALESCE(o.subscription_id, h.subscription_id)
                """
            ).fetchall()
        return {int(row["subscription_id"]): row["completed_at"] for row in rows}

    def _decode_organize_history(self, row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data["preview"] = json.loads(data["preview"])
        data["qbittorrent_task_deleted"] = bool(data.get("qbittorrent_task_deleted", 0))
        data["delete_files_from_qbittorrent"] = bool(data.get("delete_files_from_qbittorrent", 0))
        data["cleanup_attempted"] = bool(data.get("cleanup_attempted", 0))
        data["manual_override"] = bool(data.get("manual_override", 0))
        return data
