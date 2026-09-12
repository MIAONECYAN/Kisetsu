from __future__ import annotations

import os
import shutil
import sqlite3
from pathlib import Path
from urllib.parse import urlparse
from uuid import uuid4

from app.models import OrganizePolicySettings


BACKEND_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_DIR.parent
DEFAULT_DATA_DIR = PROJECT_ROOT / "data"
LEGACY_DATA_DIR = BACKEND_DIR / "data"
DATA_MIGRATION_MARKER = ".kisetsu-data-layout-v2"
BRAND_MIGRATION_MARKER = ".kisetsu-brand-migration-v1"
LEGACY_DATABASE_FILENAME = "animepilot.sqlite3"
LEGACY_SECRETS_DATABASE_FILENAME = "animepilot-secrets.sqlite3"
DATABASE_FILENAME = "kisetsu.sqlite3"
SECRETS_DATABASE_FILENAME = "kisetsu-secrets.sqlite3"
_runtime_tmdb_api_key: str | None = None


class DataDirectoryConflictError(RuntimeError):
    pass


def environment_value(primary: str, legacy: str) -> str | None:
    primary_value = os.getenv(primary)
    if primary_value is not None:
        return primary_value.strip() or None
    legacy_value = os.getenv(legacy)
    return legacy_value.strip() if legacy_value and legacy_value.strip() else None


def data_directory() -> Path:
    configured = environment_value("KISETSU_DATA_DIR", "ANIMEPILOT_DATA_DIR")
    if configured:
        return Path(configured).expanduser()
    return DEFAULT_DATA_DIR


DATA_DIR = data_directory()


def database_path() -> Path:
    configured = environment_value("KISETSU_DB", "ANIMEPILOT_DB")
    if configured:
        return Path(configured).expanduser()
    return data_directory() / DATABASE_FILENAME


def secrets_database_path(main_database: str | Path | None = None) -> Path:
    configured = environment_value("KISETSU_SECRETS_DB", "ANIMEPILOT_SECRETS_DB")
    if configured:
        return Path(configured).expanduser()
    main_path = Path(main_database).expanduser() if main_database is not None else database_path()
    return main_path.parent / SECRETS_DATABASE_FILENAME


def _sqlite_table_count(path: Path) -> int:
    uri = f"{path.resolve().as_uri()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        result = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'"
        ).fetchone()
        return int(result[0]) if result else 0


def migrate_legacy_database_file(source: Path, target: Path) -> str:
    source = source.expanduser()
    target = target.expanduser()
    if target.exists():
        return "target_preferred" if source.exists() else "ready"
    if not source.exists():
        return "missing"
    if not source.is_file():
        raise DataDirectoryConflictError("旧数据库路径不是文件，无法安全迁移。")

    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / f".{target.name}.migrating-{os.getpid()}-{uuid4().hex}"
    source_uri = f"{source.resolve().as_uri()}?mode=ro"
    try:
        with sqlite3.connect(source_uri, uri=True) as source_connection:
            with sqlite3.connect(temporary) as target_connection:
                source_connection.backup(target_connection)
                target_connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        with sqlite3.connect(temporary) as migrated_connection:
            quick_check = migrated_connection.execute("PRAGMA quick_check").fetchone()
            if not quick_check or quick_check[0] != "ok":
                raise DataDirectoryConflictError("迁移后的数据库完整性检查失败。")
        if _sqlite_table_count(source) != _sqlite_table_count(temporary):
            raise DataDirectoryConflictError("迁移后的数据库表数量与旧数据库不一致。")
        temporary.replace(target)
        shutil.copystat(source, target)
    except Exception:
        if temporary.exists():
            temporary.unlink()
        raise
    return "copied"


def migrate_legacy_database_files(directory: Path) -> dict[str, str]:
    directory = directory.expanduser()
    results = {
        "database": migrate_legacy_database_file(
            directory / LEGACY_DATABASE_FILENAME,
            directory / DATABASE_FILENAME,
        ),
        "secrets": migrate_legacy_database_file(
            directory / LEGACY_SECRETS_DATABASE_FILENAME,
            directory / SECRETS_DATABASE_FILENAME,
        ),
    }
    if "copied" in results.values():
        (directory / BRAND_MIGRATION_MARKER).write_text(
            "Kisetsu database names were copied from the retained AnimePilot files.\n",
            encoding="utf-8",
        )
    return results


def migrate_legacy_data_directory(source: Path, target: Path) -> str:
    source = source.expanduser()
    target = target.expanduser()
    marker = target / DATA_MIGRATION_MARKER

    if source == target:
        target.mkdir(parents=True, exist_ok=True)
        return "ready"
    if source.exists() and not source.is_dir():
        raise DataDirectoryConflictError("旧数据路径不是目录，无法安全迁移。")
    if target.exists() and not target.is_dir():
        raise DataDirectoryConflictError("新数据路径不是目录，无法启动后端。")
    if not source.exists():
        target.mkdir(parents=True, exist_ok=True)
        return "ready"
    if target.exists() and marker.exists():
        return "ready"
    if target.exists() and any(target.iterdir()):
        raise DataDirectoryConflictError(
            "检测到 backend/data 与项目根 data 同时包含数据。为避免覆盖或选错数据库，"
            "Kisetsu 已停止启动；请确认应保留的目录后再处理。"
        )
    if target.exists():
        target.rmdir()

    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / f".{target.name}.migrating-{os.getpid()}-{uuid4().hex}"
    try:
        shutil.copytree(source, temporary, copy_function=shutil.copy2)
        (temporary / DATA_MIGRATION_MARKER).write_text(
            "Copied from backend/data. The legacy directory is retained as a backup.\n",
            encoding="utf-8",
        )
        temporary.replace(target)
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise
    return "copied"


def prepare_data_directory() -> str:
    # A custom database path is an explicit ownership boundary. Tests and
    # deployments using it must never trigger migration of the default data.
    if environment_value("KISETSU_DB", "ANIMEPILOT_DB"):
        return "custom_database"

    target = data_directory()
    if target.resolve() != DEFAULT_DATA_DIR.resolve():
        target.mkdir(parents=True, exist_ok=True)
        migrate_legacy_database_files(target)
        return "custom_data_directory"
    status = migrate_legacy_data_directory(LEGACY_DATA_DIR, target)
    migrate_legacy_database_files(target)
    return status


def tmdb_api_key() -> str | None:
    return os.getenv("TMDB_API_KEY") or _runtime_tmdb_api_key or None


def set_runtime_tmdb_api_key(value: str | None) -> None:
    global _runtime_tmdb_api_key
    _runtime_tmdb_api_key = value.strip() if value and value.strip() else None


def mask_secret(value: str | None) -> str | None:
    if not value:
        return None
    stripped = value.strip()
    if len(stripped) <= 8:
        return "••••"
    return f"{stripped[:4]}••••{stripped[-4:]}"


def mask_url_secret(value: str | None) -> str | None:
    if not value:
        return None
    stripped = value.strip()
    if not stripped:
        return None
    parsed = urlparse(stripped)
    if parsed.scheme and parsed.netloc:
        path = parsed.path.rstrip("/") or "/"
        return f"{parsed.scheme}://{parsed.netloc}{path}?••••" if parsed.query else f"{parsed.scheme}://{parsed.netloc}/••••"
    return mask_secret(stripped)


def default_organize_policy() -> OrganizePolicySettings:
    return OrganizePolicySettings()


def bangumi_user_agent() -> str:
    return os.getenv("BANGUMI_USER_AGENT", "Kisetsu/0.1 (local MVP)")
