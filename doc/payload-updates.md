# Payload update workflow notes

This repository’s “scripting addition” (OSAX) injects a payload into `Dock.app` to enable some elevated window/space operations. When macOS changes, the injected payload can break because the internal `Dock.app` code layout shifts.

## Where changes usually land
- `src/osax/arm64_payload.m` and `src/osax/x64_payload.m`: per‑OS `NSOperatingSystemVersion` conditionals mapping to:
  - **search window offsets** (e.g. `get_remove_space_offset`)
  - **byte patterns** used to locate code (e.g. `get_remove_space_pattern`)
- `src/osax/payload.m`: orchestrates version gating (`verify_os_version`) and pattern scanning (`hex_find_seq`, etc.).
- Occasionally: `src/osax/loader.m` / `src/sa.m` if injection mechanics change.

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
- Update the corresponding `get_*_pattern()` / `get_*_offset()` branch for that OS version (and arch), and bump payload/SA versioning if required.

