from __future__ import annotations

import hashlib
import inspect
import os
import platform
import re
import resource
import shutil
import sqlite3
import stat
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any

from app.db import Store


def _fd_type(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISFIFO(mode):
        return "pipe"
    if stat.S_ISCHR(mode):
        return "character"
    return "other"


def _lsof_snapshot() -> dict[str, Any]:
    result = subprocess.run(
        ["lsof", "-a", "-nP", "-p", str(os.getpid()), "-F", "ftn"],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    records: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in result.stdout.splitlines():
        if re.fullmatch(r"f\d+", line):
            if current is not None:
                records.append(current)
            current = {"fd": line[1:]}
        elif line.startswith("f"):
            if current is not None:
                records.append(current)
            current = None
        elif current is not None and line.startswith("t"):
            current["type"] = line[1:]
        elif current is not None and line.startswith("n"):
            current["name"] = line[1:]
    if current is not None:
        records.append(current)

    types = Counter(record.get("type", "unknown") for record in records)
    return {
        "total": len(records),
        "sqlite": sum(
            1
            for record in records
            if re.search(r"\.sqlite3(?:-(?:wal|shm))?(?: \(deleted\))?$", record.get("name", ""))
        ),
        "sockets": sum(types.get(kind, 0) for kind in ("IPv4", "IPv6", "unix")),
        "deleted": sum(1 for record in records if "(deleted)" in record.get("name", "")),
        "types": dict(sorted(types.items())),
        "collector": "lsof",
    }


def _native_snapshot() -> dict[str, Any]:
    fd_root = next(
        (candidate for candidate in (Path("/proc/self/fd"), Path("/dev/fd")) if candidate.is_dir()),
        None,
    )
    if fd_root is None:
        return {
            "total": None,
            "sqlite": None,
            "sockets": None,
            "deleted": None,
            "types": {},
            "collector": "unavailable",
        }

    types: Counter[str] = Counter()
    sqlite_count = 0
    deleted_count = 0
    total = 0
    for entry in fd_root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            details = os.fstat(int(entry.name))
        except OSError:
            continue
        total += 1
        types[_fd_type(details.st_mode)] += 1
        try:
            target = os.readlink(entry)
        except OSError:
            target = ""
        if re.search(r"\.sqlite3(?:-(?:wal|shm))?(?: \(deleted\))?$", target):
            sqlite_count += 1
        if "(deleted)" in target:
            deleted_count += 1
    return {
        "total": total,
        "sqlite": sqlite_count if fd_root.as_posix().startswith("/proc/") else None,
        "sockets": types.get("socket", 0),
        "deleted": deleted_count if fd_root.as_posix().startswith("/proc/") else None,
        "types": dict(sorted(types.items())),
        "collector": "procfs" if fd_root.as_posix().startswith("/proc/") else "devfs",
    }


def fd_snapshot() -> dict[str, Any]:
    if shutil.which("lsof"):
        try:
            return _lsof_snapshot()
        except (OSError, subprocess.SubprocessError):
            pass
    return _native_snapshot()


def resource_diagnostics(store: Store) -> dict[str, Any]:
    quick_check = "error"
    database_error: str | None = None
    try:
        with store.connect() as conn:
            row = conn.execute("PRAGMA quick_check").fetchone()
        quick_check = str(row[0]) if row else "error"
    except sqlite3.Error as exc:
        database_error = type(exc).__name__

    store_file = Path(inspect.getfile(Store))
    try:
        store_sha256 = hashlib.sha256(store_file.read_bytes()).hexdigest()
    except OSError:
        store_sha256 = None
    path_fingerprint = hashlib.sha256(
        str(store.path.expanduser().resolve(strict=False)).encode("utf-8")
    ).hexdigest()
    soft_limit, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    return {
        "pid": os.getpid(),
        "python_version": platform.python_version(),
        "platform": platform.system(),
        "architecture": platform.machine(),
        "fd": fd_snapshot(),
        "limits": {
            "nofile_soft": soft_limit,
            "nofile_hard": hard_limit,
        },
        "database": {
            "quick_check": quick_check,
            "error_type": database_error,
            "exists": store.path.expanduser().exists(),
            "path_fingerprint": path_fingerprint,
        },
        "source": {
            "store_sha256": store_sha256,
        },
    }
