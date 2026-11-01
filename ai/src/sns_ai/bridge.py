"""A bounded, persistent JSONL child process. No shell, HTTP or global process killing."""
from __future__ import annotations

import atexit
from collections import deque
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time

import psutil


class BackendError(RuntimeError):
    pass


def find_dart(value: str | None = None) -> str:
    executable = value or os.environ.get("SNS_DART") or shutil.which("dart")
    if not executable:
        raise FileNotFoundError("Dart was not found; set SNS_DART to dart.exe or pass dart=...")
    if os.name == "nt" and Path(executable).suffix.lower() in (".bat", ".cmd"):
        for candidate in (Path(executable).with_suffix(".exe"), Path(executable).parent / "cache/dart-sdk/bin/dart.exe"):
            if candidate.is_file():
                return str(candidate)
        raise FileNotFoundError("Pass the Dart SDK dart.exe, rather than a batch wrapper")
    return executable


class DartBridge:
    def __init__(self, *, project_root: str | Path, content: str | Path,
                 scenarios: str | Path, dart: str | None = None, timeout: float = 30):
        self.root = Path(project_root).resolve()
        self.timeout = timeout
        self.process = subprocess.Popen(
            [find_dart(dart), str(self.root / "bin/ai_bridge.dart"),
             "--content", str(Path(content).resolve()), "--scenario-set", str(Path(scenarios).resolve())],
            cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.lines = queue.Queue(maxsize=8)
        self.errors = deque(maxlen=100)
        self.lock = threading.Lock()
        self.sequence = 0
        self.closed = False
        self.backend_pid = None
        self.launcher = psutil.Process(self.process.pid)
        self.known_children = {}
        self.calls = 0
        self.roundtrip_seconds = 0.0
        self.decode_seconds = 0.0
        self.response_bytes = 0

        def stdout_reader():
            assert self.process.stdout
            for line in self.process.stdout:
                try:
                    self.lines.put(line, timeout=1)
                except queue.Full:
                    return
            try:
                self.lines.put(None, timeout=1)
            except queue.Full:
                pass

        def stderr_reader():
            assert self.process.stderr
            for line in self.process.stderr:
                self.errors.append(line.rstrip())

        self.readers = [threading.Thread(target=stdout_reader, daemon=True),
                        threading.Thread(target=stderr_reader, daemon=True)]
        for reader in self.readers:
            reader.start()
        atexit.register(self.close)

    def request(self, method: str, **payload):
        with self.lock:
            if self.closed:
                raise BackendError("Dart bridge is closed")
            self.sequence += 1
            request_id = self.sequence
            started = time.perf_counter()
            try:
                assert self.process.stdin
                self.process.stdin.write(json.dumps({"requestId": request_id, "method": method, **payload}, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                line = self.lines.get(timeout=self.timeout)
                if line is None:
                    raise BackendError("Dart bridge exited: " + "\n".join(self.errors))
                decoding = time.perf_counter()
                response = json.loads(line)
                self.decode_seconds += time.perf_counter() - decoding
                self.response_bytes += len(line.encode("utf-8"))
                if response.get("requestId") != request_id:
                    self.close()
                    raise BackendError("Dart JSONL request ID mismatch")
                if response.get("ok") is not True:
                    raise BackendError(str(response.get("error", "Unknown backend error")))
                backend_pid = response.get('backendPid', self.backend_pid)
                if backend_pid is not None and backend_pid != self.backend_pid:
                    if self.launcher.is_running():
                        self.known_children.update({p.pid: p for p in self.launcher.children(recursive=True)})
                    process = psutil.Process(backend_pid)
                    if backend_pid != self.process.pid and any(p.pid == self.process.pid for p in process.parents()):
                        self.known_children[backend_pid] = process
                    self.backend_pid = backend_pid
                return response
            except (queue.Empty, BrokenPipeError, json.JSONDecodeError) as error:
                elapsed = time.perf_counter() - started
                detail = (f'no response within {self.timeout:g}s' if isinstance(error, queue.Empty)
                          else f'{type(error).__name__}: {error}')
                self.close()
                diagnostics = '; '.join(self.errors) or 'no Dart stderr output'
                raise BackendError(f'Dart {method} request #{request_id} failed after {elapsed:.2f}s: {detail}; {diagnostics}') from error
            finally:
                self.calls += 1
                self.roundtrip_seconds += time.perf_counter() - started

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            current = self.launcher.children(recursive=True) if self.launcher.is_running() else []
            children = list({**self.known_children, **{p.pid: p for p in current}}.values())
        except psutil.NoSuchProcess:
            children = list(self.known_children.values())
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except (OSError, BrokenPipeError):
                pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        _, alive = psutil.wait_procs(children, timeout=2)
        for child in alive:
            try:
                child.terminate()
            except psutil.NoSuchProcess:
                pass
        _, alive = psutil.wait_procs(alive, timeout=2)
        for child in alive:
            try:
                child.kill()
            except psutil.NoSuchProcess:
                pass
        for reader in self.readers:
            reader.join(timeout=1)
        for pipe in (self.process.stdout, self.process.stderr):
            if pipe:
                pipe.close()
        atexit.unregister(self.close)
