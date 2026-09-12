from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from app.brush.models import BrushRun, BrushTask
from app.db import Store


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class BrushRepository:
    def __init__(self, store: Store):
        self.store = store

    def init(self) -> None:
        with self.store.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS brush_tasks (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  task_key TEXT NOT NULL UNIQUE,
                  site_id TEXT NOT NULL,
                  site_name TEXT NOT NULL,
                  group_id TEXT,
                  group_name TEXT,
                  resource_id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  subtitle TEXT,
                  size_bytes INTEGER,
                  qbittorrent_hash TEXT,
                  downloader_type TEXT NOT NULL DEFAULT 'qbittorrent',
                  remote_task_id TEXT,
                  unique_tag TEXT NOT NULL UNIQUE,
                  category TEXT NOT NULL,
                  save_path TEXT NOT NULL,
                  status TEXT NOT NULL,
                  progress REAL NOT NULL DEFAULT 0,
                  download_speed INTEGER NOT NULL DEFAULT 0,
                  upload_speed INTEGER NOT NULL DEFAULT 0,
                  downloaded INTEGER NOT NULL DEFAULT 0,
                  uploaded INTEGER NOT NULL DEFAULT 0,
                  ratio REAL NOT NULL DEFAULT 0,
                  seeding_time INTEGER NOT NULL DEFAULT 0,
                  added_at TEXT NOT NULL,
                  completed_at TEXT,
                  last_activity_at TEXT,
                  last_checked_at TEXT,
                  deleted_at TEXT,
                  cleanup_reason TEXT,
                  error_message TEXT,
                  rule_snapshot TEXT NOT NULL,
                  torrent_tags TEXT NOT NULL,
                  UNIQUE(site_id, resource_id)
                );

                CREATE TABLE IF NOT EXISTS brush_runs (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  run_type TEXT NOT NULL,
                  status TEXT NOT NULL,
                  started_at TEXT NOT NULL,
                  finished_at TEXT,
                  candidates_count INTEGER NOT NULL DEFAULT 0,
                  added_count INTEGER NOT NULL DEFAULT 0,
                  checked_count INTEGER NOT NULL DEFAULT 0,
                  deleted_count INTEGER NOT NULL DEFAULT 0,
                  skipped_count INTEGER NOT NULL DEFAULT 0,
                  error_count INTEGER NOT NULL DEFAULT 0,
                  summary TEXT,
                  details TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_brush_tasks_status ON brush_tasks(status);
                CREATE INDEX IF NOT EXISTS idx_brush_tasks_hash ON brush_tasks(qbittorrent_hash);
                CREATE INDEX IF NOT EXISTS idx_brush_runs_started ON brush_runs(started_at DESC);
                """
            )
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(brush_tasks)").fetchall()}
            if "downloader_type" not in columns:
                conn.execute("ALTER TABLE brush_tasks ADD COLUMN downloader_type TEXT NOT NULL DEFAULT 'qbittorrent'")
            if "remote_task_id" not in columns:
                conn.execute("ALTER TABLE brush_tasks ADD COLUMN remote_task_id TEXT")
            if "group_id" not in columns:
                conn.execute("ALTER TABLE brush_tasks ADD COLUMN group_id TEXT")
            if "group_name" not in columns:
                conn.execute("ALTER TABLE brush_tasks ADD COLUMN group_name TEXT")

    @staticmethod
    def _task(row) -> BrushTask:
        data = dict(row)
        data["rule_snapshot"] = json.loads(data.get("rule_snapshot") or "{}")
        data["torrent_tags"] = json.loads(data.get("torrent_tags") or "[]")
        return BrushTask(**data)

    @staticmethod
    def _run(row) -> BrushRun:
        data = dict(row)
        stored = json.loads(data.get("details") or "[]")
        if isinstance(stored, dict):
            data["details"] = stored.get("messages") or []
            data.update(stored.get("diagnostics") or {})
        else:
            data["details"] = stored if isinstance(stored, list) else []
        return BrushRun(**data)

    def task_exists(self, site_id: str, resource_id: str) -> bool:
        with self.store.connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM brush_tasks WHERE site_id = ? AND resource_id = ? LIMIT 1",
                (site_id, resource_id),
            ).fetchone()
        return row is not None

    def add_task(self, data: dict[str, Any]) -> BrushTask:
        payload = dict(data)
        payload.setdefault("added_at", now_iso())
        payload.setdefault("status", "downloading")
        payload.setdefault("downloader_type", "qbittorrent")
        payload.setdefault("remote_task_id", None)
        payload.setdefault("rule_snapshot", {})
        payload.setdefault("torrent_tags", [])
        columns = [
            "task_key", "site_id", "site_name", "group_id", "group_name", "resource_id", "title", "subtitle", "size_bytes",
            "qbittorrent_hash", "downloader_type", "remote_task_id", "unique_tag", "category", "save_path", "status", "added_at",
            "rule_snapshot", "torrent_tags",
        ]
        values = [payload.get(column) for column in columns]
        values[-2] = json.dumps(payload.get("rule_snapshot") or {}, ensure_ascii=False)
        values[-1] = json.dumps(payload.get("torrent_tags") or [], ensure_ascii=False)
        with self.store.connect() as conn:
            cursor = conn.execute(
                f"INSERT INTO brush_tasks ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)})",
                values,
            )
            row = conn.execute("SELECT * FROM brush_tasks WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return self._task(row)

    def get_task(self, task_id: int) -> BrushTask | None:
        with self.store.connect() as conn:
            row = conn.execute("SELECT * FROM brush_tasks WHERE id = ?", (task_id,)).fetchone()
        return self._task(row) if row else None

    def list_tasks(self, *, include_archived: bool = False, limit: int = 500) -> list[BrushTask]:
        with self.store.connect() as conn:
            if include_archived:
                rows = conn.execute("SELECT * FROM brush_tasks ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM brush_tasks WHERE status NOT IN ('deleted', 'archived') ORDER BY id DESC LIMIT ?",
                    (limit,),
                ).fetchall()
        return [self._task(row) for row in rows]

    def active_tasks(self) -> list[BrushTask]:
        with self.store.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM brush_tasks WHERE status NOT IN ('deleted', 'archived', 'error') ORDER BY id",
            ).fetchall()
        return [self._task(row) for row in rows]

    def checkable_tasks(self) -> list[BrushTask]:
        with self.store.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM brush_tasks WHERE status NOT IN ('deleted', 'archived') ORDER BY id",
            ).fetchall()
        return [self._task(row) for row in rows]

    def tracked_tasks(self) -> list[BrushTask]:
        with self.store.connect() as conn:
            rows = conn.execute("SELECT * FROM brush_tasks ORDER BY id").fetchall()
        return [self._task(row) for row in rows]

    def update_task(self, task_id: int, **changes: Any) -> BrushTask | None:
        allowed = {
            "qbittorrent_hash", "downloader_type", "remote_task_id", "status", "progress", "download_speed", "upload_speed", "downloaded",
            "uploaded", "ratio", "seeding_time", "completed_at", "last_activity_at", "last_checked_at",
            "deleted_at", "cleanup_reason", "error_message", "torrent_tags", "size_bytes",
        }
        values: list[Any] = []
        assignments: list[str] = []
        for key, value in changes.items():
            if key not in allowed:
                continue
            if key == "torrent_tags":
                value = json.dumps(value or [], ensure_ascii=False)
            assignments.append(f"{key} = ?")
            values.append(value)
        if not assignments:
            return self.get_task(task_id)
        values.append(task_id)
        with self.store.connect() as conn:
            conn.execute(f"UPDATE brush_tasks SET {', '.join(assignments)} WHERE id = ?", values)
        return self.get_task(task_id)

    def create_run(self, run_type: str, *, trigger: str | None = None) -> BrushRun:
        details = json.dumps(
            {"messages": [], "diagnostics": {"trigger": trigger} if trigger else {}},
            ensure_ascii=False,
        )
        with self.store.connect() as conn:
            cursor = conn.execute(
                "INSERT INTO brush_runs (run_type, status, started_at, details) VALUES (?, 'running', ?, ?)",
                (run_type, now_iso(), details),
            )
            row = conn.execute("SELECT * FROM brush_runs WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return self._run(row)

    def finish_run(self, run_id: int, **changes: Any) -> BrushRun:
        allowed = {
            "status", "candidates_count", "added_count", "checked_count", "deleted_count", "skipped_count",
            "error_count", "summary", "details", "diagnostics",
        }
        with self.store.connect() as conn:
            current = conn.execute("SELECT details FROM brush_runs WHERE id = ?", (run_id,)).fetchone()
        stored = json.loads(current["details"] or "[]") if current else {}
        existing_diagnostics = (stored.get("diagnostics") or {}) if isinstance(stored, dict) else {}
        merged_diagnostics = {**existing_diagnostics, **(changes.get("diagnostics") or {})}
        assignments = ["finished_at = ?"]
        values: list[Any] = [now_iso()]
        for key, value in changes.items():
            if key not in allowed:
                continue
            if key == "diagnostics":
                continue
            if key == "details":
                value = json.dumps(
                    {
                        "messages": value or [],
                        "diagnostics": merged_diagnostics,
                    },
                    ensure_ascii=False,
                )
            assignments.append(f"{key} = ?")
            values.append(value)
        values.append(run_id)
        with self.store.connect() as conn:
            conn.execute(f"UPDATE brush_runs SET {', '.join(assignments)} WHERE id = ?", values)
            row = conn.execute("SELECT * FROM brush_runs WHERE id = ?", (run_id,)).fetchone()
        return self._run(row)

    def list_runs(self, limit: int = 50) -> list[BrushRun]:
        with self.store.connect() as conn:
            rows = conn.execute("SELECT * FROM brush_runs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        runs = [self._run(row) for row in rows]
        task_ids = sorted({snapshot.task_id for run in runs for snapshot in run.added_tasks})
        task_statuses: dict[int, str] = {}
        if task_ids:
            placeholders = ", ".join("?" for _ in task_ids)
            with self.store.connect() as conn:
                task_rows = conn.execute(
                    f"SELECT id, status FROM brush_tasks WHERE id IN ({placeholders})",
                    task_ids,
                ).fetchall()
            task_statuses = {int(row["id"]): str(row["status"]) for row in task_rows}
        for run in runs:
            run.added_tasks = [
                snapshot.model_copy(update={"status": task_statuses.get(snapshot.task_id, snapshot.status)})
                for snapshot in run.added_tasks
            ]
        return runs

    def clear_records(self, *, include_active: bool) -> int:
        with self.store.connect() as conn:
            if include_active:
                cursor = conn.execute("DELETE FROM brush_tasks")
            else:
                cursor = conn.execute("DELETE FROM brush_tasks WHERE status IN ('deleted', 'archived', 'error')")
            conn.execute("DELETE FROM brush_runs")
        return cursor.rowcount
