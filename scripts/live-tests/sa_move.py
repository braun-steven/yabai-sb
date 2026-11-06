#!/usr/bin/env python3
# Moves windows to a space through the scripting addition (SA_OPCODE_WINDOW_LIST_TO_SPACE) by raw id. It also moves the
# windows yabai has no AX reference for, which `window --space` refuses.
# usage: sa_move.py <space id> <window id>...
import os, socket, struct, sys

def sa_move(sid, wids):
    body = struct.pack("<BQi", 0x12, sid, len(wids)) + b"".join(struct.pack("<I", w) for w in wids)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(3)
        s.connect(f"/tmp/yabai-sa_{os.environ['USER']}.socket")
        s.sendall(struct.pack("<h", len(body)) + body)
        return s.recv(16) == b"\x00"

if __name__ == "__main__":
    ok = sa_move(int(sys.argv[1]), [int(w) for w in sys.argv[2:]])
    print("moved" if ok else "refused")
    sys.exit(0 if ok else 1)
