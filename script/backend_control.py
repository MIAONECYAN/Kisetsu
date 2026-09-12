#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = PROJECT_ROOT / "backend"
STATE_DIR = PROJECT_ROOT / ".kisetsu"
PID_FILE = STATE_DIR / "backend.pid"
LOG_FILE = STATE_DIR / "backend.log"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000


@dataclass
class PortOwner:
    pid: int
    command: str

    @property
    def is_kisetsu_backend(self) -> bool:
        lowered = self.command.lower()
        return "uvicorn" in lowered and "app.main:app" in lowered


def parse_port(value: str | None) -> int:
    raw = (
        value
        or os.getenv("KISETSU_BACKEND_PORT")
        or os.getenv("ANIMEPILOT_BACKEND_PORT")
        or str(DEFAULT_PORT)
    )
    try:
        port = int(raw)
    except ValueError as exc:
        raise SystemExit(f"端口无效：{raw}") from exc
    if not 1 <= port <= 65535:
        raise SystemExit(f"端口超出范围：{port}")
    return port


def port_can_bind(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
        except OSError:
            return False
    return True


def command_for_pid(pid: int) -> str:
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "args="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return ""
    return completed.stdout.strip()


def port_owner(port: int) -> PortOwner | None:
    try:
        completed = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    for line in completed.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
            return PortOwner(pid=pid, command=command_for_pid(pid))
    return None


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_pid_file() -> int | None:
    try:
        raw = PID_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    return int(raw) if raw.isdigit() else None


def write_pid_file(pid: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(f"{pid}\n", encoding="utf-8")


def clear_stale_pid_file() -> None:
    pid = read_pid_file()
    if pid is None or not process_exists(pid):
        with suppress_file_errors():
            PID_FILE.unlink()


class suppress_file_errors:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, _exc, _tb):
        return exc_type is OSError or exc_type is FileNotFoundError


def fetch_health(host: str, port: int, timeout: float = 1.5) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/health", timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def diagnose(args: argparse.Namespace) -> int:
    port = parse_port(args.port)
    owner = port_owner(port)
    if owner is None and port_can_bind(args.host, port):
        print(f"端口 {port} 空闲，可以启动 Kisetsu 后端。")
        return 0
    if owner is None:
        print(f"端口 {port} 已被占用，但无法读取占用进程。请使用 lsof 手动检查。")
        return 2
    kind = "Kisetsu 后端" if owner.is_kisetsu_backend else "其它进程"
    print(f"端口 {port} 已被{kind}占用。")
    print(f"PID：{owner.pid}")
    print(f"命令：{owner.command or '未知'}")
    if owner.is_kisetsu_backend:
        health = fetch_health(args.host, port)
        if health and health.get("ok") is True:
            print(f"/health：{health.get('message')}，版本 {health.get('version')}。")
            return 0
        print("这是 Kisetsu 后端进程，但 /health 暂不可用；可运行 script/stop_backend.sh 后重启。")
        return 1
    print(f"不要自动停止该进程。请换端口：KISETSU_BACKEND_PORT={port + 1} script/start_backend.sh")
    return 2


def stop_backend(args: argparse.Namespace) -> int:
    port = parse_port(args.port)
    pid = read_pid_file()
    owner = port_owner(port)
    if pid is not None and process_exists(pid):
        command = command_for_pid(pid)
        target = PortOwner(pid=pid, command=command)
    elif owner and owner.is_kisetsu_backend:
        target = owner
    else:
        clear_stale_pid_file()
        print("没有找到可安全停止的 Kisetsu 后端进程。")
        return 0
    if not target.is_kisetsu_backend:
        print(f"PID {target.pid} 不是 Kisetsu 后端，不会停止。")
        print(f"命令：{target.command or '未知'}")
        return 2
    print(f"正在停止 Kisetsu 后端 PID {target.pid}...")
    os.kill(target.pid, signal.SIGTERM)
    with suppress_file_errors():
        os.kill(target.pid, signal.SIGCONT)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        if not process_exists(target.pid):
            with suppress_file_errors():
                PID_FILE.unlink()
            print("Kisetsu 后端已停止。")
            return 0
        time.sleep(0.2)
    if args.force:
        print("进程未响应 SIGTERM，正在强制停止这个 Kisetsu 后端进程...")
        os.kill(target.pid, signal.SIGKILL)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not process_exists(target.pid):
                with suppress_file_errors():
                    PID_FILE.unlink()
                print("Kisetsu 后端已强制停止。")
                return 0
            time.sleep(0.2)
    print("已发送 SIGTERM，但进程仍未退出。请稍后重试或手动处理。")
    return 1


def start_backend(args: argparse.Namespace) -> int:
    port = parse_port(args.port)
    clear_stale_pid_file()
    owner = port_owner(port)
    if owner is not None:
        if owner.is_kisetsu_backend:
            health = fetch_health(args.host, port)
            if args.restart:
                result = stop_backend(args)
                if result != 0:
                    return result
            elif health and health.get("ok") is True:
                write_pid_file(owner.pid)
                print(f"Kisetsu 后端已在运行：http://{args.host}:{port}")
                print(f"PID：{owner.pid}")
                print(f"/health：{health.get('message')}，版本 {health.get('version')}。")
                return 0
            else:
                print(f"端口 {port} 已被旧 Kisetsu 后端 PID {owner.pid} 占用，但健康检查失败。")
                print("请先运行 script/stop_backend.sh，或使用 --restart。")
                return 1
        else:
            print(f"端口 {port} 已被其它进程占用，不会自动停止。")
            print(f"PID：{owner.pid}")
            print(f"命令：{owner.command or '未知'}")
            print("请换端口或手动关闭占用进程。")
            return 2
    if not port_can_bind(args.host, port):
        print(f"端口 {port} 无法绑定，请检查系统权限或占用状态。")
        return 2
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PYTHONPATH"] = str(BACKEND_ROOT)
    env["KISETSU_BACKEND_PORT"] = str(port)
    command = [
        sys.executable,
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        args.host,
        "--port",
        str(port),
    ]
    log = LOG_FILE.open("a", encoding="utf-8")
    try:
        process = subprocess.Popen(
            command,
            cwd=BACKEND_ROOT,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
    finally:
        log.close()
    write_pid_file(process.pid)
    deadline = time.monotonic() + args.timeout
    payload = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            print(f"后端进程提前退出，请查看日志：{LOG_FILE}")
            return 1
        payload = fetch_health(args.host, port)
        if payload and payload.get("ok") is True:
            break
        time.sleep(0.25)
    if not payload or payload.get("ok") is not True:
        print(f"等待 /health 超时，请查看日志：{LOG_FILE}")
        return 1
    print(f"Backend running at http://{args.host}:{port}")
    print(f"Health: http://{args.host}:{port}/health")
    print(f"PID：{process.pid}")
    print(f"PID 文件：{PID_FILE}")
    print(f"日志：{LOG_FILE}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Kisetsu 后端端口诊断、启动和停止工具")
    parser.add_argument("command", choices=["diagnose", "start", "stop"])
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=None)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--restart", action="store_true", help="启动前安全停止旧 Kisetsu 后端")
    parser.add_argument("--force", action="store_true", help="仅在目标确认是 Kisetsu 后端时强制停止")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "diagnose":
        return diagnose(args)
    if args.command == "start":
        return start_backend(args)
    return stop_backend(args)


if __name__ == "__main__":
    raise SystemExit(main())
