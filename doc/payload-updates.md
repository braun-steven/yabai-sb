# Payload update workflow notes

This repository’s “scripting addition” (OSAX) injects a payload into `Dock.app` to enable some elevated window/space operations. When macOS changes, the injected payload can break because the internal `Dock.app` code layout shifts.

## Where changes usually land
- `osax/arm64_payload.m`: the values for macOS 27 (arm64e; the x86_64 payload and the older versions were removed on branch `swift-port`, see `bash scripts/payload-history.sh` for them). A new release adds `NSOperatingSystemVersion` conditionals again, mapping to:
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


The makefile embeds the rebuilt binaries as `__osax_payload` and `__osax_loader` in the SwiftPM `OSAX` target. `Sources/Yabai/ScriptingAddition.swift` consumes them. Bump `OSAX_VERSION` in `osax/common.h` whenever payload code or protocol behavior changes; the P14 path-only rebuild kept 2.1.34 because rebuilding at the old path produced identical bytes.

## Hardened core prototypes

`make osax-prototypes` builds both arm64e variants without installing or injecting them. Normal
builds select Objective-C (2.1.35); `OSAX_CORE=swift make install` selects the experimental Swift
core (2.1.36). The native adapter remains in `payload.m`, and the named bootstrap template in
`bootstrap.S` is shared. `make osax-test` runs both cores against a recording backend outside Dock.
Read [osax-prototypes.md](osax-prototypes.md) for protocol compatibility, signatures/ownership
evidence, sanitizer coverage, benchmarks and the controlled live comparison procedure.

