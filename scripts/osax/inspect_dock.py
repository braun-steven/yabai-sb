#!/usr/bin/env python3
"""Inspect signatures in Dock on disk. Never loads a payload or reads live process memory."""
import argparse
import hashlib
import json
import pathlib
import re
import struct
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--dock", type=pathlib.Path, default=pathlib.Path("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
args = parser.parse_args()
raw = args.dock.read_bytes()
image = raw
if raw[:4] == b"\xca\xfe\xba\xbe":
    count = struct.unpack_from(">I", raw, 4)[0]
    slices = [struct.unpack_from(">IIIII", raw, 8 + i * 20) for i in range(count)]
    ordinary = [entry for entry in slices if entry[0] == 0x0100000c and entry[1] & 0xffffff == 2]
    if len(ordinary) != 1:
        raise SystemExit("expected one ordinary arm64e slice")
    _, _, offset, size, _ = ordinary[0]
    image = raw[offset:offset + size]
if struct.unpack_from("<I", image)[0] != 0xfeedfacf:
    raise SystemExit("expected 64-bit little-endian Mach-O")
commands = struct.unpack_from("<I", image, 16)[0]
offset, base, text, image_uuid = 32, None, None, None
for _ in range(commands):
    command, size = struct.unpack_from("<II", image, offset)
    if size < 8 or offset + size > len(image):
        raise SystemExit("invalid Mach-O load command")
    if command == 0x1b:
        image_uuid = str(uuid.UUID(bytes=image[offset + 8:offset + 24]))
    if command == 0x19:
        segment = struct.unpack_from("<II16sQQQQIIII", image, offset)
        if segment[2].rstrip(b"\0") == b"__TEXT":
            base = segment[3]
        for i in range(segment[9]):
            section = struct.unpack_from("<16s16sQQIIIIIIII", image, offset + 72 + i * 80)
            if section[0].rstrip(b"\0") == b"__text" and section[1].rstrip(b"\0") == b"__TEXT":
                text = section[2:5]
    offset += size
if base is None or text is None:
    raise SystemExit("missing __TEXT,__text")
text_vm, text_size, text_file = text
source = (pathlib.Path(__file__).resolve().parents[2] / "osax/arm64_payload.m").read_text()
results = []
for name, body in re.findall(r"const char \*get_(\w+)_pattern\(void\)\s*\{(.*?)\n\}", source, re.S):
    tokens = re.search(r'return "([^"]+)"', body)[1].split()
    regex = b""
    for token in tokens:
        allowed = bytes(value for value in range(256) if all(a == "?" or int(a, 16) == b for a, b in zip(token, [value >> 4, value & 15])))
        regex += b"[" + b"".join(re.escape(bytes([value])) for value in allowed) + b"]"
    start = int(re.search(r"uint64_t get_" + name + r"_offset\(void\)\s*\{\s*return (0x[0-9a-f]+);", source)[1], 16)
    low, high = max(base + start, text_vm), min(base + start + 0x1286a0, text_vm + text_size)
    region = image[text_file + low - text_vm:text_file + high - text_vm]
    matches = []
    for match in re.finditer(b"(?=(" + regex + b"))", region, re.S):
        pc = low + match.start()
        entry = {"offset": hex(pc - base), "instruction_aligned": pc % 4 == 0}
        if name in ("dock_spaces", "dppm"):
            a, b = struct.unpack_from("<II", image, text_file + pc - text_vm)
            valid = a & 0x9f000000 == 0x90000000 and b & 0xff800000 == 0x91000000 and a & 31 == b & 31 == (b >> 5) & 31
            entry["valid_adrp_add"] = valid
            if valid:
                immediate = ((a >> 29) & 3) | (((a >> 5) & 0x7ffff) << 2)
                if immediate & (1 << 20):
                    immediate -= 1 << 21
                add = (b >> 10) & 0xfff
                if b & (1 << 22):
                    add <<= 12
                entry["target_offset"] = hex((pc & ~0xfff) + (immediate << 12) + add - base)
        matches.append(entry)
    results.append({"name": name, "matches": matches})
print(json.dumps({"dock": str(args.dock), "sha256": hashlib.sha256(raw).hexdigest(), "uuid": image_uuid,
                  "text_size": text_size, "signatures": results}, indent=2))
