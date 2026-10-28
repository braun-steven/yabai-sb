# Payload update workflow notes

This repository’s “scripting addition” (OSAX) injects a payload into `Dock.app` to enable some elevated window/space operations. When macOS changes, the injected payload can break because the internal `Dock.app` code layout shifts.

## Where changes usually land
- `osax/arm64_payload.m`: the values for macOS 27 (arm64e; the x86_64 payload and the older versions were removed during the Swift port, see `bash scripts/payload-history.sh` for them). A new release adds `NSOperatingSystemVersion` conditionals again, mapping to:
  - **search window offsets** (e.g. `get_remove_space_offset`)
  - **byte patterns** used to locate code (e.g. `get_remove_space_pattern`)
- `osax/payload.m`: orchestrates version gating (`verify_os_version`) and pattern scanning (`hex_find_seq`, etc.).
- Occasionally: `osax/loader.m` / `Sources/Yabai/ScriptingAddition.swift` if injection mechanics change.

## How to learn what changed (from git history)
1. List “payload update” commits:
   - `bash scripts/payload-history.sh`
   - Narrow by OS/codename: `bash scripts/payload-history.sh --grep 'Sequoia|15\\.'`
2. Inspect a specific update:
   - `bash scripts/payload-history.sh --show <commit>`
3. Pay attention to commit subjects that mention **“patterns/offsets”** and often include the **hash of the Dock binary** (e.g. `sha256sum ... Dock`); this indicates the author validated the update against a specific macOS build’s `Dock.app`.

## What the diffs imply about the author’s process
From commits like “Patterns adjusted …” and comments inside the payload sources, the workflow is typically:
- Obtain the target `Dock.app` binary for the new macOS build and record its hash.
- Use a disassembler/decompiler (e.g. Ghidra/Hopper/IDA) to find relevant code paths (often by searching for Objective‑C selector strings referenced in comments, like `"removeSpace:"`).
- Choose a nearby **stable byte sequence** as a signature and adjust the **offset search window** so `hex_find_seq()` finds the right location quickly.
- Update the corresponding `get_*_pattern()` / `get_*_offset()` branch for that OS version, and bump payload/SA versioning if required.


The `justfile`'s `osax-payload` recipe builds the standalone payload, while SwiftPM's `OSAXEmbed` plugin embeds its binaries as `__osax_payload` and `__osax_loader` in the `OSAX` target. `Sources/Yabai/ScriptingAddition.swift` consumes them. Bump `OSAX_VERSION` in `osax/common.h` whenever payload code or protocol behavior changes; the P14 path-only rebuild kept 2.1.34 because rebuilding at the old path produced identical bytes.

## Removed opcodes

Opcodes 7 and 8 (window opacity and its fade) and 14 and 15 (the proxy swaps of window animations) were removed in 2.1.38. Their numbers stay unused: the validator and the fixtures use the literal values, so the other opcodes keep theirs.

## Adding a Dock build

The animation patch (the `0x2f00e400` instruction at `animation_time_addr`) is written only when Dock's `LC_UUID` is in
`known_dock_uuids` in `osax/payload.m`, next to `read_image_uuid`. For any other Dock build the payload logs
`unknown Dock build <uuid>; animation patch skipped` and does not report `OSAX_ATTRIB_ANIM_TIME`. The daemon then warns
"space animation patch unavailable for this Dock build" (`ScriptingAddition.attributeVerdict`) instead of failing. The
other attribute bits still fail the check.

To add a build after validating it:

1. Read its UUID: `otool -arch arm64e -l /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -A3 LC_UUID`.
2. Confirm the animation pattern and the `0x2f00e400` write against that binary, and record the Dock SHA-256 and build
   number in [osax-prototypes.md](osax-prototypes.md) "Dock inspection and ownership evidence".
3. Add the UUID to `known_dock_uuids` and bump `OSAX_VERSION` (`osax/common.h`) for the payload change.
4. Live check before shipping: reload the payload, then run `python3 scripts/live-tests/sa_version.py` (expect `0x5f`)
   and `log show --predicate 'process == "Dock"' --last 2m | grep yabai-sa` (expect the patch applied). See
   [live-testing.md](live-testing.md) "Scripting addition".

## Hardened core prototypes

The removed prototype build options described here are historical. Today the justfile's
`osax-payload` recipe builds the Swift arm64e payload without installing or injecting it, and
`osax-test` runs the current core against a recording backend outside Dock. The native adapter
remains in `payload.m`, and the named bootstrap template in `bootstrap.S` is shared. Read
[osax-prototypes.md](osax-prototypes.md) for protocol compatibility, signatures/ownership evidence,
sanitizer coverage, benchmarks and the controlled live comparison procedure.


## After a built-in load

The daemon's own load (`[daemon] load_scripting_addition`, `ScriptingAdditionLoader.swift`) runs `sudo -n <yabai> --load-sa`,
which installs the payload like the manual command. No reconnect step is needed for the messages: each `ScriptingAddition.send`
opens a new socket and connects to `/tmp/yabai-sa_$USER.socket`, so the first message after a successful load reaches the new
payload. The only state kept across messages is the handshake verdict (`payloadIsCurrentCache`): a handshake that fails is
retried, but a verdict "not current" (the version differs) stays until `payloadChanged()`. A Dock restart calls it before the
load starts, and a successful load calls it too (`EventHandler.scriptingAdditionLoaded`), so a daemon that started with an old
payload asks again. Not verified live: the first `space --focus` after a load is in the C4.2 live check.
