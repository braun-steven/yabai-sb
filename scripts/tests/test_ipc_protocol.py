import importlib.util
import json
from pathlib import Path
import struct
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "live-tests" / "perf.py"
SPEC = importlib.util.spec_from_file_location("ipc_perf", SCRIPT)
perf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(perf)


def frame(reply):
    data = json.dumps(reply).encode()
    return struct.pack("!4sII", b"YBIP", 2, len(data)) + data


class Socket:
    def __init__(self, data):
        self.data = data
        self.sent = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def settimeout(self, _):
        pass

    def connect(self, _):
        pass

    def shutdown(self, _):
        pass

    def sendall(self, data):
        self.sent = data

    def recv(self, count):
        # Force every header and payload to be read in fragments.
        result, self.data = self.data[:min(count, 3)], self.data[min(count, 3):]
        return result


class IPCProtocolTests(unittest.TestCase):
    def test_query_data_is_decoded_without_losing_integer_precision(self):
        sock = Socket(
            frame({"type": "output", "command": 1, "format": "json",
                   "data": {"id": 18446744073709551615, "title": "文書"}})
            + frame({"type": "complete", "ok": True}))
        with mock.patch.object(perf.socket, "socket", return_value=sock):
            result = perf.socket_command(["query", "--windows"])
        self.assertEqual(json.loads(result), {"id": 18446744073709551615, "title": "文書"})
        magic, version, count = struct.unpack("!4sII", sock.sent[:12])
        self.assertEqual((magic, version, count), (b"YBIP", 2, len(sock.sent) - 12))
        self.assertEqual(json.loads(sock.sent[12:]),
                         {"type": "command", "arguments": ["query", "--windows"]})

    def test_error_is_not_treated_as_command_output(self):
        sock = Socket(frame({"type": "error", "command": 1, "message": "bad selector"}))
        with mock.patch.object(perf.socket, "socket", return_value=sock):
            with self.assertRaisesRegex(RuntimeError, "bad selector"):
                perf.socket_command(["query"])

    def test_truncated_and_oversized_frames_fail(self):
        for data in (b"YB", struct.pack("!4sII", b"YBIP", 2, (64 << 20) + 1)):
            with self.subTest(data=data):
                with self.assertRaises(RuntimeError):
                    perf._read_reply(Socket(data))

    def test_completion_is_required_even_after_output(self):
        sock = Socket(frame({"type": "output", "command": 1, "format": "text", "data": "ok\n"}))
        with mock.patch.object(perf.socket, "socket", return_value=sock):
            with self.assertRaisesRegex(RuntimeError, "incomplete IPC response"):
                perf.socket_command(["config", "window_gap"])
