import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest


spec = importlib.util.spec_from_file_location(
    "desktop_transcript", Path(__file__).with_name("desktop_transcript.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TASK = "11111111-1111-4111-8111-111111111111"


def receive(connection):
    def exact(length):
        data = b""
        while len(data) < length:
            chunk = connection.recv(length - len(data))
            if not chunk:
                raise EOFError()
            data += chunk
        return data
    length = struct.unpack("<I", exact(4))[0]
    return json.loads(exact(length))


def send(connection, value):
    raw = json.dumps(value).encode()
    connection.sendall(struct.pack("<I", len(raw)) + raw)


class DesktopTranscriptTests(unittest.TestCase):
    def setUp(self):
        self.input_fd, self.input_writer = os.pipe()
        self.receipts = []
        self.follower = module.DesktopFollower(
            "/unused", TASK, self.receipts.append, input_fd=self.input_fd)
        self.follower.client_id = "phone-follower"
        self.follower.owner_id = "desktop-owner"

    def tearDown(self):
        os.close(self.input_fd)
        os.close(self.input_writer)

    def snapshot(self):
        return {"type": "broadcast", "method": "thread-stream-state-changed",
                "version": 11, "sourceClientId": "desktop-owner",
                "targetClientIds": ["phone-follower"],
                "params": {"hostId": "local", "conversationId": TASK,
                           "change": {"type": "snapshot", "privateHistory": "discard"}}}

    def test_only_exact_owner_task_target_and_version_acknowledge(self):
        for field, wrong in [("version", 10), ("sourceClientId", "other"),
                             ("targetClientIds", ["other"])]:
            value = self.snapshot()
            value[field] = wrong
            self.follower.process(value)
            self.assertFalse(self.follower.followed)
        for field in ["hostId", "conversationId"]:
            value = self.snapshot()
            value["params"][field] = "other"
            self.follower.process(value)
            self.assertFalse(self.follower.followed)
        value = self.snapshot()
        value["params"]["change"]["type"] = "delta"
        self.follower.process(value)
        self.assertFalse(self.follower.followed)
        self.follower.process(self.snapshot())
        self.assertTrue(self.follower.followed)
        self.assertEqual(self.receipts, [])
        self.assertNotIn("privateHistory", vars(self.follower))

    def test_owner_disconnect_fails_instead_of_staying_ready(self):
        value = {"type": "broadcast", "method": "client-status-changed",
                 "params": {"clientId": "desktop-owner", "status": "disconnected"}}
        with self.assertRaisesRegex(RuntimeError, "desktop_disconnected"):
            self.follower.process(value)

    def test_lease_expires_without_controller(self):
        left, right = socket.socketpair()
        self.follower.socket = left
        self.follower.last_lease = module.time.monotonic() - module.LEASE_SECONDS - 1
        try:
            with self.assertRaisesRegex(RuntimeError, "controller_disconnected"):
                self.follower.pump(0)
        finally:
            left.close()
            right.close()

    def test_helper_has_no_arbitrary_stdin_commands(self):
        left, right = socket.socketpair()
        self.follower.socket = left
        os.write(self.input_writer, b"rm -rf /\n")
        try:
            with self.assertRaisesRegex(RuntimeError, "invalid_lease"):
                self.follower.pump(0)
        finally:
            left.close()
            right.close()

    def test_task_open_happens_only_without_owner_and_waits_for_snapshot(self):
        # Exercise framing, real socket I/O, discovery failure, task opening,
        # follower ACK and cooperative shutdown as one complete handshake.
        with tempfile.TemporaryDirectory(prefix="nb-ipc-") as folder:
            endpoint = str(Path(folder) / "ipc.sock")
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(endpoint)
            listener.listen()
            opened = []
            failures = []
            received = []

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(3)
                        initialize = receive(connection)
                        self.assertEqual(initialize["params"]["clientType"], "nightblood_voice")
                        send(connection, {"type": "response", "requestId": initialize["requestId"],
                                          "resultType": "success", "result": {"clientId": "phone-follower"}})
                        missing = receive(connection)
                        send(connection, {"type": "response", "requestId": missing["requestId"],
                                          "resultType": "error"})
                        discovery = receive(connection)
                        self.assertEqual(opened, [TASK])
                        self.assertEqual(self.receipts, [])
                        send(connection, {"type": "response", "requestId": discovery["requestId"],
                                          "resultType": "success", "handledByClientId": "desktop-owner"})
                        following = receive(connection)
                        self.assertTrue(following["params"]["following"])
                        self.assertEqual(self.receipts, [])
                        send(connection, self.snapshot())
                        # Stop only after the client has actually acknowledged.
                        acknowledged.wait(3)
                        os.write(self.input_writer, b"stop\n")
                        received.append(receive(connection)["params"]["following"])
                except Exception as error:
                    failures.append(error)

            acknowledged = threading.Event()
            def receipt(event):
                self.receipts.append(event)
                acknowledged.set()
            self.follower = module.DesktopFollower(
                endpoint, TASK, receipt, input_fd=self.input_fd,
                opener=lambda: opened.append(TASK))
            server = threading.Thread(target=serve)
            server.start()
            try:
                self.follower.run()
            finally:
                server.join(4)
                listener.close()
            self.assertFalse(server.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(self.receipts, ["ready"])
            self.assertEqual(received, [False])

    def test_endpoint_rejects_symlinks(self):
        with tempfile.TemporaryDirectory(prefix="nb-trust-") as folder:
            root = Path(folder)
            (root / "ipc").symlink_to(root)
            with self.assertRaisesRegex(ValueError, "untrusted_desktop_endpoint"):
                module.trusted_endpoint(root)

    def test_noncanonical_task_is_rejected(self):
        with self.assertRaises(ValueError):
            module.canonical_id(TASK.replace("-", ""))


if __name__ == "__main__":
    unittest.main()
