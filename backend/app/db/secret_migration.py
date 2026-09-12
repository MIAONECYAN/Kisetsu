from __future__ import annotations

import json
import os
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.db.store import Store
from app.secret_config import (
    config_secret_namespace,
    split_result_payload,
    split_sensitive_config,
    split_subscription_payload,
)


MIGRATION_VERSION = 1
MIGRATION_STATUS_KEY = "legacy_migration_status"
MIGRATION_VERSION_KEY = "legacy_migration_version"
MIGRATION_BACKUP_KEY = "legacy_migration_backup"


@dataclass(frozen=True)
class SecretMigrationReport:
    migrated_config_fields: int = 0
    migrated_subscription_fields: int = 0
    migrated_history_urls: int = 0
    migrated_match_fields: int = 0
    migrated_cache_urls: int = 0
    backup_path: str | None = None
    status: str = "complete"

    @property
    def migrated_total(self) -> int:
        return (
            self.migrated_config_fields
            + self.migrated_subscription_fields
            + self.migrated_history_urls
            + self.migrated_match_fields
            + self.migrated_cache_urls
        )


@dataclass
class _MigrationPlan:
    secret_entries: dict[str, dict[str, Any]]
    config_updates: list[tuple[str, str]]
    subscription_updates: list[tuple[str, int]]
    history_ids: list[int]
    match_updates: list[tuple[str, int]]
    cache_update: tuple[str, str] | None
    counts: dict[str, int]

    @property
    def total(self) -> int:
        return sum(self.counts.values())


def migrate_legacy_secrets(store: Store) -> SecretMigrationReport:
    """Move legacy plaintext credentials into the sidecar before runtime starts."""

    store.secrets.init()
    plan = _build_plan(store)
    if plan.total == 0:
        store.secrets.set_meta(MIGRATION_VERSION_KEY, str(MIGRATION_VERSION))
        store.secrets.set_meta(MIGRATION_STATUS_KEY, "complete")
        return _report(plan, status="complete")

    backup_path = _create_private_backup(store)
    previous = {
        namespace: store.secrets.namespace(namespace)
        for namespace in plan.secret_entries
    }
    try:
        store.secrets.set_many(plan.secret_entries)
        _verify_secret_entries(store, plan.secret_entries)
        store.secrets.set_meta(MIGRATION_BACKUP_KEY, backup_path.name)
        store.secrets.set_meta(MIGRATION_STATUS_KEY, "secrets_verified")
    except Exception:
        for namespace, values in previous.items():
            store.secrets.replace_namespace(namespace, values)
        raise

    _scrub_main_database(store, plan)
    remaining = _build_plan(store)
    if remaining.total:
        raise RuntimeError("敏感数据迁移后的主数据库结构化复查未通过")
    store.secrets.set_meta(MIGRATION_VERSION_KEY, str(MIGRATION_VERSION))
    store.secrets.set_meta(MIGRATION_STATUS_KEY, "complete")
    return _report(plan, backup_path=backup_path, status="complete")


def prune_orphan_secrets(store: Store) -> int:
    """Remove sidecar records whose owning business row no longer exists."""

    with store.connect() as conn:
        config_keys = {str(row["key"]) for row in conn.execute("SELECT key FROM config").fetchall()}
        subscription_ids = {
            int(row["id"]) for row in conn.execute("SELECT id FROM subscriptions").fetchall()
        }
        history_fingerprints = {
            str(row["fingerprint"])
            for row in conn.execute("SELECT fingerprint FROM download_history").fetchall()
        }
        match_keys = {
            (int(row["subscription_id"]), str(row["fingerprint"]))
            for row in conn.execute(
                "SELECT subscription_id, fingerprint FROM subscription_matches"
            ).fetchall()
        }

    stale: list[str] = []
    for namespace in store.secrets.list_namespaces():
        if namespace.startswith("config:"):
            if namespace.removeprefix("config:") not in config_keys:
                stale.append(namespace)
            continue
        if namespace.startswith("subscription:"):
            try:
                subscription_id = int(namespace.removeprefix("subscription:"))
            except ValueError:
                continue
            if subscription_id not in subscription_ids:
                stale.append(namespace)
            continue
        if namespace.startswith("download-history:"):
            if namespace.removeprefix("download-history:") not in history_fingerprints:
                stale.append(namespace)
            continue
        if namespace.startswith("subscription-match:"):
            raw = namespace.removeprefix("subscription-match:")
            subscription_text, separator, fingerprint = raw.partition(":")
            if not separator:
                continue
            try:
                key = (int(subscription_text), fingerprint)
            except ValueError:
                continue
            if key not in match_keys:
                stale.append(namespace)
    store.secrets.delete_namespaces(stale)
    return len(stale)


def private_migration_backup_dir(store: Store) -> Path:
    return store.secrets.path.parent / "private-secret-migration-backups"


def _build_plan(store: Store) -> _MigrationPlan:
    entries: dict[str, dict[str, Any]] = {}
    config_updates: list[tuple[str, str]] = []
    subscription_updates: list[tuple[str, int]] = []
    history_ids: list[int] = []
    match_updates: list[tuple[str, int]] = []
    cache_update: tuple[str, str] | None = None
    counts = {
        "config": 0,
        "subscriptions": 0,
        "history": 0,
        "matches": 0,
        "cache": 0,
    }

    with store.connect() as conn:
        for row in conn.execute("SELECT key, value FROM config").fetchall():
            try:
                payload = json.loads(row["value"])
            except (TypeError, ValueError):
                continue
            if not isinstance(payload, dict):
                continue
            public, secrets = split_sensitive_config(str(row["key"]), payload)
            if secrets:
                _merge_entry(entries, config_secret_namespace(str(row["key"])), secrets)
                config_updates.append((json.dumps(public, ensure_ascii=False), str(row["key"])))
                counts["config"] += len(secrets)
            if str(row["key"]) == "download_history_state_cache":
                sanitized, cache_secrets = _split_history_cache(payload)
                for namespace, values in cache_secrets.items():
                    _merge_entry(entries, namespace, values)
                if cache_secrets:
                    cache_update = (json.dumps(sanitized, ensure_ascii=False), str(row["key"]))
                    counts["cache"] += sum(len(values) for values in cache_secrets.values())

        for row in conn.execute("SELECT id, data FROM subscriptions").fetchall():
            try:
                payload = json.loads(row["data"])
            except (TypeError, ValueError):
                continue
            if not isinstance(payload, dict):
                continue
            public, secrets = split_subscription_payload(payload)
            if not secrets:
                continue
            namespace = store._subscription_secret_namespace(int(row["id"]))
            _merge_entry(entries, namespace, secrets)
            subscription_updates.append((json.dumps(public, ensure_ascii=False), int(row["id"])))
            counts["subscriptions"] += len(secrets)

        for row in conn.execute(
            "SELECT id, fingerprint, download_url FROM download_history WHERE download_url IS NOT NULL AND TRIM(download_url) != ''"
        ).fetchall():
            namespace = store._history_secret_namespace(str(row["fingerprint"]))
            _merge_entry(entries, namespace, {"download_url": row["download_url"]})
            history_ids.append(int(row["id"]))
            counts["history"] += 1

        for row in conn.execute(
            "SELECT id, subscription_id, fingerprint, result FROM subscription_matches"
        ).fetchall():
            try:
                payload = json.loads(row["result"])
            except (TypeError, ValueError):
                continue
            if not isinstance(payload, dict):
                continue
            public, secrets = split_result_payload(payload)
            if not secrets:
                continue
            namespace = store._match_secret_namespace(
                int(row["subscription_id"]), str(row["fingerprint"])
            )
            _merge_entry(entries, namespace, secrets)
            match_updates.append((json.dumps(public, ensure_ascii=False), int(row["id"])))
            counts["matches"] += len(secrets)

    return _MigrationPlan(
        secret_entries=entries,
        config_updates=config_updates,
        subscription_updates=subscription_updates,
        history_ids=history_ids,
        match_updates=match_updates,
        cache_update=cache_update,
        counts=counts,
    )


def _split_history_cache(
    payload: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    sanitized = dict(payload)
    items: list[Any] = []
    entries: dict[str, dict[str, Any]] = {}
    for raw in payload.get("items") or []:
        if not isinstance(raw, dict):
            items.append(raw)
            continue
        item = dict(raw)
        download_url = item.pop("download_url", None)
        fingerprint = str(item.get("fingerprint") or "").strip()
        if download_url and fingerprint:
            entries[f"download-history:{fingerprint}"] = {"download_url": download_url}
        items.append(item)
    sanitized["items"] = items
    return sanitized, entries


def _merge_entry(
    entries: dict[str, dict[str, Any]], namespace: str, values: dict[str, Any]
) -> None:
    entries.setdefault(namespace, {}).update(values)


def _verify_secret_entries(store: Store, entries: dict[str, dict[str, Any]]) -> None:
    for namespace, expected in entries.items():
        actual = store.secrets.namespace(namespace)
        for field, value in expected.items():
            if field not in actual or actual[field] != value:
                raise RuntimeError("敏感数据侧库写入校验失败")


def _create_private_backup(store: Store) -> Path:
    directory = private_migration_backup_dir(store)
    directory.mkdir(parents=True, exist_ok=True)
    if os.name == "posix":
        os.chmod(directory, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    target = directory / f"kisetsu-before-secret-migration-{stamp}.sqlite3"
    source = sqlite3.connect(store.path)
    destination = sqlite3.connect(target)
    try:
        source.backup(destination)
    finally:
        destination.close()
        source.close()
    if os.name == "posix":
        os.chmod(target, 0o600)
    return target


def _scrub_main_database(store: Store, plan: _MigrationPlan) -> None:
    with store.connect() as conn:
        conn.execute("PRAGMA secure_delete = ON")
        conn.executemany(
            "UPDATE config SET value = ?, updated_at = CURRENT_TIMESTAMP WHERE key = ?",
            plan.config_updates,
        )
        if plan.cache_update is not None:
            conn.execute(
                "UPDATE config SET value = ?, updated_at = CURRENT_TIMESTAMP WHERE key = ?",
                plan.cache_update,
            )
        conn.executemany("UPDATE subscriptions SET data = ? WHERE id = ?", plan.subscription_updates)
        conn.executemany(
            "UPDATE download_history SET download_url = NULL WHERE id = ?",
            [(value,) for value in plan.history_ids],
        )
        conn.executemany("UPDATE subscription_matches SET result = ? WHERE id = ?", plan.match_updates)

    conn = sqlite3.connect(store.path)
    try:
        conn.execute("PRAGMA secure_delete = ON")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.execute("VACUUM")
    finally:
        conn.close()


def _report(
    plan: _MigrationPlan,
    *,
    backup_path: Path | None = None,
    status: str,
) -> SecretMigrationReport:
    return SecretMigrationReport(
        migrated_config_fields=plan.counts["config"],
        migrated_subscription_fields=plan.counts["subscriptions"],
        migrated_history_urls=plan.counts["history"],
        migrated_match_fields=plan.counts["matches"],
        migrated_cache_urls=plan.counts["cache"],
        backup_path=str(backup_path) if backup_path else None,
        status=status,
    )
