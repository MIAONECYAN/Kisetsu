from __future__ import annotations

from app.db import Store
from app.db.secret_migration import migrate_legacy_secrets, prune_orphan_secrets
from app.settings import database_path

_store: Store | None = None


def init_store(path: str | None = None) -> Store:
    global _store
    _store = Store(path or database_path())
    _store.init()
    migrate_legacy_secrets(_store)
    prune_orphan_secrets(_store)
    return _store


def get_store() -> Store:
    global _store
    if _store is None:
        _store = init_store()
    return _store
