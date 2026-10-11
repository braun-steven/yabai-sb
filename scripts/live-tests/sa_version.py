#!/usr/bin/env python3
# Prints the version and attribute bits of the scripting-addition payload loaded in Dock.
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(f"/tmp/yabai-sa_{os.environ['USER']}.socket")
s.send(bytes([1, 0, 1]))  # length 1, SA_OPCODE_HANDSHAKE
version, rest = s.recv(256).split(b"\0", 1)
print(f"payload {version.decode()} attrib 0x{int.from_bytes(rest[:4], 'little'):x}")
