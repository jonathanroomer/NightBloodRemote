"""Keep the selected voice task subscribed in the stock Codex desktop.

Executed by the paired Mac App Server from this signed iPhone resource. The
only UI operation is opening that canonical task. IPC requests are limited to
discovery and following; no model turns, approvals or transcript writes.
Stdout carries small lifecycle receipts only, never conversation snapshots.
"""
import json
import os
from pathlib import Path
import select
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid


MAX_FRAME = 32 * 1024 * 1024
LEASE_SECONDS = 90


def failure_reason(error):
    known = {"desktop_disconnected", "controller_disconnected",
             "desktop_attachment_failed", "desktop_handshake_failed",
             "unsupported_desktop_frame", "invalid_lease",
             "untrusted_desktop_endpoint", "desktop_endpoint_missing"}
    if isinstance(error, PermissionError):
        return "desktop_permission_denied"
    if isinstance(error, ConnectionRefusedError):
        return "desktop_connection_refused"
    if isinstance(error, (ConnectionResetError, BrokenPipeError)):
        return "desktop_connection_reset"
    if isinstance(error, TimeoutError):
        return "desktop_socket_timed_out"
    if isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired)):
        return "desktop_open_failed"
    if isinstance(error, (json.JSONDecodeError, UnicodeDecodeError, TypeError, AttributeError)):
        return "desktop_invalid_reply"
    if isinstance(error, OSError):
        return "desktop_io_failed"
    return str(error) if str(error) in known else "desktop_unavailable"


def canonical_id(value):
    parsed = str(uuid.UUID(value))
    if parsed != value:
        raise ValueError("invalid_task_id")
    return parsed


def trusted_endpoint(codex_home):
    root = Path(codex_home)
    if not root.is_absolute():
        raise ValueError("invalid_codex_home")
    directory = root / "ipc"
    endpoint = directory / "ipc.sock"
    for path, kind in [(directory, stat.S_ISDIR), (endpoint, stat.S_ISSOCK)]:
        info = path.lstat()
        if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError("untrusted_desktop_endpoint")
    return str(endpoint)


class DesktopFollower:
    def __init__(self, endpoint, thread_id, receipt, input_fd=0, opener=None):
        self.endpoint = endpoint
        self.thread_id = canonical_id(thread_id)
        self.receipt = receipt
        self.input_fd = input_fd
        self.opener = opener or self.open_task
        self.client_id = None
        self.owner_id = None
        self.pending = {}
        self.buffer = bytearray()
        self.stdin_buffer = bytearray()
        self.followed = False
        self.closed = False
        self.socket = None
        self.last_lease = time.monotonic()

    def open_task(self):
        subprocess.run(
            ["/usr/bin/open", "-g", "codex://threads/" + self.thread_id],
            check=True, timeout=5, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def send(self, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.socket.sendall(struct.pack("<I", len(body)) + body)

    def request(self, method, params, version=0, target=None):
        request_id = str(uuid.uuid4())
        value = {
            "type": "request", "method": method, "requestId": request_id,
            "version": version, "params": params, "timeoutMs": 1500,
        }
        if self.client_id:
            value["sourceClientId"] = self.client_id
        if target:
            value["targetClientId"] = target
        self.send(value)
        return request_id

    def following(self, enabled):
        self.send({
            "type": "broadcast", "method": "thread-stream-following-changed",
            "version": 1, "sourceClientId": self.client_id,
            "targetClientIds": [self.owner_id],
            "params": {"hostId": "local", "conversationId": self.thread_id,
                       "following": enabled},
        })

    def process(self, value):
        kind = value.get("type")
        if kind == "response":
            self.pending[value.get("requestId")] = value
        elif kind == "client-discovery-request":
            # This client never becomes a writer or handles commands.
            self.send({"type": "client-discovery-response",
                       "requestId": value.get("requestId"),
                       "response": {"canHandle": False}})
        elif kind == "broadcast":
            params = value.get("params", {})
            if value.get("method") == "client-status-changed":
                if params.get("clientId") == self.owner_id and params.get("status") == "disconnected":
                    raise RuntimeError("desktop_disconnected")
            if (value.get("method") == "thread-stream-state-changed"
                    and value.get("version") == 11
                    and value.get("sourceClientId") == self.owner_id
                    and self.client_id in value.get("targetClientIds", [])
                    and params.get("hostId") == "local"
                    and params.get("conversationId") == self.thread_id
                    and params.get("change", {}).get("type") == "snapshot"):
                # An owner snapshot acknowledges registration of this follower.
                # Discard its contents immediately; only readiness crosses WSS.
                self.followed = True

    def pump(self, timeout):
        readable, _, _ = select.select([self.socket, self.input_fd], [], [], timeout)
        if self.input_fd in readable:
            chunk = os.read(self.input_fd, 1024)
            if not chunk:
                self.closed = True
                return
            self.stdin_buffer.extend(chunk)
            if len(self.stdin_buffer) > 1024:
                raise RuntimeError("invalid_lease")
            while b"\n" in self.stdin_buffer:
                line, _, tail = self.stdin_buffer.partition(b"\n")
                self.stdin_buffer = bytearray(tail)
                if line == b"ping":
                    self.last_lease = time.monotonic()
                elif line == b"stop":
                    self.closed = True
                else:
                    raise RuntimeError("invalid_lease")
        if self.socket in readable:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise RuntimeError("desktop_disconnected")
            self.buffer.extend(chunk)
            while len(self.buffer) >= 4:
                size = struct.unpack("<I", self.buffer[:4])[0]
                if not 0 < size <= MAX_FRAME:
                    raise RuntimeError("unsupported_desktop_frame")
                if len(self.buffer) < size + 4:
                    break
                raw = bytes(self.buffer[4:4 + size])
                del self.buffer[:4 + size]
                self.process(json.loads(raw))
        if time.monotonic() - self.last_lease > LEASE_SECONDS:
            raise RuntimeError("controller_disconnected")

    def response(self, request_id, timeout=2):
        deadline = time.monotonic() + timeout
        while not self.closed and request_id not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self.pump(min(0.2, remaining))
        return self.pending.pop(request_id, None)

    def attach(self, timeout=15):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        self.socket.connect(self.endpoint)
        self.socket.settimeout(None)
        request_id = self.request("initialize", {"clientType": "nightblood_voice"})
        result = self.response(request_id)
        if not result or result.get("resultType") != "success":
            raise RuntimeError("desktop_handshake_failed")
        self.client_id = result.get("result", {}).get("clientId")
        if not isinstance(self.client_id, str):
            raise RuntimeError("desktop_handshake_failed")
        deadline = time.monotonic() + timeout
        opened = False
        while not self.closed and time.monotonic() < deadline:
            request_id = self.request(
                "thread-owner-discovery",
                {"hostId": "local", "conversationId": self.thread_id}, version=1,
            )
            result = self.response(request_id)
            if result and result.get("resultType") == "success":
                self.owner_id = result.get("handledByClientId")
                if isinstance(self.owner_id, str):
                    self.following(True)
                    while not self.closed and not self.followed and time.monotonic() < deadline:
                        self.pump(0.2)
                    if self.followed:
                        self.receipt("ready")
                        return
                    break
            if not opened:
                self.opener()
                opened = True
            self.pump(0.1)
        raise RuntimeError("desktop_attachment_failed")

    def run(self):
        try:
            self.attach()
            while not self.closed:
                self.pump(0.5)
        finally:
            if self.socket:
                if self.followed:
                    try:
                        self.following(False)
                    except (OSError, ValueError):
                        pass
                self.socket.close()


def main():
    try:
        codex_home, thread_id, nonce = sys.argv[1:]
        canonical_id(thread_id)
        canonical_id(nonce)
        def receipt(event, reason=None):
            print(json.dumps({"event": event, "threadId": thread_id,
                              "nonce": nonce, "reason": reason}), flush=True)
        try:
            try:
                endpoint = trusted_endpoint(codex_home)
            except FileNotFoundError:
                raise RuntimeError("desktop_endpoint_missing") from None
            follower = DesktopFollower(endpoint, thread_id, receipt)
            follower.run()
            receipt("closed")
        except Exception as error:
            receipt("failed", failure_reason(error))
            return 1
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
