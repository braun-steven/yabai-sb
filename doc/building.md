# Building yabai

Use Xcode with the macOS 27 SDK and Swift 6.4 on Apple Silicon. The package dependencies are
Apple's swift-algorithms, swift-argument-parser, swift-collections and swift-log, and swiftlang's
swift-subprocess (without its Foundation trait; the swift-system it resolves links only on other platforms). SwiftPM owns the complete executable build, including the scripting addition,
compilation, linking, test discovery and debug/release optimization. The `justfile` provides convenience
commands for publishing to `bin/yabai`, documentation, signing and release archives.

Requirements: Xcode with the macOS 27 SDK and Swift 6.4, plus just (`brew install just`).

## Commands

| Command | Result |
|---|---|
| `swift build` / `swift build -c release` | Complete debug/release build in SwiftPM's output directory |
| `swift test` | Daemon/core tests, including golden IPC replay |
| `swift run yabai --version` | Build and run the CLI's version command |
| `just` / `just build` | Debug executable at `bin/yabai` |
| `just install` | Release executable at `bin/yabai`; no installation or service restart |
| `just asan` / `just tsan` | Debug executable with Address/ThreadSanitizer and C UndefinedBehaviorSanitizer |
| `just test` | Daemon/core tests, including golden IPC replay |
| `just osax-test` | Isolated payload/loader tests, outside Dock |
| `just lint` | Optional swift-format lint of `Sources` and `tests` (config `.swift-format`); reports findings, never reformats, not in `ci` |
| `just osax-payload` | Standalone binaries/arrays in `.build/osax/swift/`; no injection |
| `just prepare` | Optional build of just the `OSAX` target through SwiftPM |
| `just check-build` | Isolated clean/incremental/toolchain upgrade checks and Swift tests |
| `just clean` | Remove `bin/`, both packages' build caches and generated C sources |

Every daemon variant publishes to `bin/yabai` after a successful build. Copying to a temporary sibling
and renaming it preserves the last successful executable if compilation or copying fails. Other
`bin/` artifacts are retained. Recipes run serially within one just invocation because variants share this
published path; run separate build invocations one at a time.

Debug/release use the normal `.build/` cache; sanitizer builds use `.build/asan` and `.build/tsan`.
Switching between build variants cannot publish a cached sanitizer executable. The isolated package has its
own `osax/.build/` cache. `SWIFT` overrides the Swift command (default `xcrun swift`); `SWIFT_FLAGS`
passes additional SwiftPM options to builds and tests through `SWIFT_FLAGS`, for example
`SWIFT_FLAGS='--filter Golden' just test`.
These environment overrides are whitespace-separated words, not shell expressions: dollar signs,
backticks and wildcard characters stay literal, and embedded quotes do not group words. Use recipe
arguments for values containing spaces, for example `just test --filter 'test name'`. Exporting the
overrides avoids parsing their contents as shell source during Just interpolation. The SDK default
uses a shell conditional so `xcrun` is not evaluated when `SDKROOT` is already set (even to an empty value).
Coverage filters are extended regular expressions, passed as a recipe argument such as
`just coverage 'WindowManager\+Tree'`. `scripts/coverage.sh` passes them to `awk` through `ENVIRON`
because macOS `awk -v` consumes backslashes, which can change a literal `+` in a filename filter.

## CI gates

`just ci-quick` (debug build, then `just test`) and `just ci` (adds `just install`, `just osax-test` and
`just check-build`) run `scripts/ci.sh`. Each step prints one `PASS|FAIL <step> <seconds>s <log>` line; the full
output goes to `.build/ci/<step>.log`. The first failing step stops the run and prints its `error:` lines, its
unlisted warning lines and the last 40 log lines. A compiler or linker warning fails a step too, unless its text is
in `scripts/ci-warning-allowlist.txt` (one fixed string per line; each entry needs a reason comment above it).

## Compiler and SDK selection

`SWIFT` and `SWIFT_FLAGS` affect the outer SwiftPM invocation only. They do not select the payload
compiler or pass flags to it. Both native generation and its identity check resolve `clang` and
`swiftc` through `xcrun`, honoring `DEVELOPER_DIR` and `TOOLCHAINS`. `SDKROOT` selects the macOS SDK;
The just recipes preserve an existing value. The native commands pass that resolved SDK explicitly to both
compilers. The supported setup remains Xcode with Swift 6.4 and the macOS 27 SDK.

Use `DEVELOPER_DIR` to select an Xcode installation for the whole build, and `TOOLCHAINS` to select
an installed toolchain for the `xcrun` commands. Overriding `SWIFT` with a separate compiler path
does not automatically coordinate these selections. Likewise, SwiftPM `--sdk` or `--toolset`
options alone do not configure the embedded payload; keep their selections consistent with the
native environment if using them. Alternate toolchains must support the arm64e payload target.

## Direct SwiftPM and editor use

SwiftPM and editor use require no preparation step, including on a fresh checkout or after native
source changes:

```sh
swift build
swift test --filter Golden
swift run yabai --version
```

The plugin tracks native sources, headers and the payload's Swift core automatically.
Direct SwiftPM commands leave their products in SwiftPM's output
directory; use `swift build --show-bin-path` to locate them.

## Embedded scripting addition

The daemon is an ordinary SwiftPM executable. The injected library uses arm64e, manual retain/release
in its native adapter, and a separately linked Swift core; the loader also contains assembly.
`Plugins/OSAXEmbed/` invokes `scripts/build-osax.sh` to build these binaries and convert them to
C arrays compiled by the `OSAX` target alongside `Version.c`.
The installed executable therefore contains everything it needs to load the scripting addition.

The plugin declares native sources, headers, the module map and scripts as inputs, and two C files
as outputs. Native compilation runs when an input changes or an output is missing. All generated files and
compiler caches stay in the sandboxed plugin work directory under `.build/`. Identical generated
arrays retain their timestamps to avoid unnecessary downstream compilation. The inputs are enumerated
from `osax/` (`.m`, `.c`, `.h`, `.S`, `.swift` and `.modulemap` files), excluding `osax/.build/`,
`osax/testing/`, `osax/include/`, `osax/Version.c`, `osax/Package.swift` and the generated arrays, so a new
native file needs no plugin edit. Enumerated files that `build-osax.sh` does not read still trigger a rebuild
when they change, so keep such files out of `osax/`. The standalone command uses the same script, so compiler settings have one owner.

A small prebuild command checks the selected tools on each build. `scripts/osax-toolchain.sh`
records selection variables, resolved compiler paths, compiler versions/file identities, and the
resolved SDK path/settings hash in a comment-only generated `Toolchain.h`. Its timestamp changes
only when that identity changes. The native build command consumes this header as an input, so
switching Xcode/toolchains/SDKs or updating them in place invalidates the native artifacts without
a manual clean. The checker and native compiler commands share the same resolver. The header adds
no runtime resource or executable code; unchanged toolchains do not trigger native compilation.

The root manifest explicitly opts into C generation:

```swift
// swift-tools-version: 6.4;(experimentalCGen)
```

This is an **experimental SwiftPM feature**, verified with the installed Swift 6.4 default Swift
Build backend and plugin sandbox enabled. Without the opt-in, SwiftPM warns
`C source file generation not enabled` and omits generated C sources. Keep the suffix when updating
the tools version.
See SwiftPM's [tools-version parser](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/ToolsVersionParser.swift)
and [generated-source handling](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/TargetSourcesBuilder.swift).

The script sets the historical `.build/osax/swift/payload` install name explicitly: Swift's default
includes the output path, which would otherwise change the previously tested payload bytes in
different plugin work directories.

## Upgrade checks

Run `just check-build` after an Xcode/SwiftPM upgrade or changes to build generation. It copies the
current working sources into a fresh temporary directory and checks a complete build/version
command, a no-op rebuild, a native-header change, and another no-op build. It then changes the
Xcode selector to an equivalent selection of the same installation and verifies native cache
invalidation followed by another no-op. Identical native bytes and C-array timestamps must be
preserved. Finally it runs the Swift tests, including golden IPC replay. The copy holds only what the build and
tests read (`Sources`, `Plugins`, `osax`, `tests`, `Package.swift`, `assets/Info.plist`, two scripts,
the whole `examples/` directory and `doc/yabai.schema.json`): a test that reads another repository file through `#filePath` passes in `just test` but fails
here until `scripts/check-build.py` copies that file too. C2.3 hit this with `examples/yabai.toml` and `examples/batch.sh`,
so `examples/` is now copied as a whole; C6.1 hit it again with the schema that `ConfigSchemaTests` reads. Every step fails on a diagnostic line, a line that starts with `warning:` or `error:`, optionally after
a location (`file:12:5: `) or a tool name (`ld: `); text inside a test name, such as a fixture's `Syntax error:`, does
not count (C2 close: the earlier match anywhere in a line failed the tests step on such a test name).

The check needs only the selected Xcode; it does not switch system-wide `xcode-select`, require a
second installation, touch the checkout's sources/build caches/`bin/`, or deploy a service.
Successful checks remove their temporary copy. Failures retain it with per-step logs. For manual
inspection, run `python3 scripts/check-build.py --keep`; `--swift 'xcrun swift'` selects the outer
driver using the same scope described above. The runner uses Python 3's standard library.

SwiftPM sometimes logs a dependency-cache recovery warning (`warning: 'swift-collections': skipping cache due to
an error: The file “maintenance.lock” doesn’t exist.`) and fetches the package without the cache. The check ignores
exactly these `skipping cache` lines: they failed two phase closes of the static config plan, and a rerun passed each
time. Every other warning still fails the step.

## Settings and verification

Both package manifests use Swift 6 language mode and the supported
[`treatAllWarnings(as:)` setting](https://developer.apple.com/documentation/packagedescription/swiftsetting/treatallwarnings(as:_:))
for Swift and C targets. SwiftPM selects optimization for the requested configuration; CPrivate
only adds `NDEBUG` for release. The injected payload retains its tested explicit native compiler
settings. Remaining unsafe flags express private-framework search paths, manual ObjC ownership,
selected C diagnostics and the embedded Info.plist/SDK linker workaround.

The just recipes export the selected macOS `SDKROOT`; the Xcode `swift` shim also supplies it for direct commands.
`Package.swift` forwards `-isysroot` to the Clang linker so the executable records the actual SDK
version and AppKit does not enable old-SDK compatibility behavior. Check it with
`xcrun vtool -show-build bin/yabai` after toolchain changes.

For build-system changes, check plain `swift build` and `swift test` after `just clean`, a second
build without native generation/compilation, all four daemon variants, both test
suites, unchanged golden IPC output, and `bin/yabai --version`. A deliberate failed build should
leave `bin/yabai` unchanged. Check the generated payload hash against the tested artifact.
Payload sanitizer tests run separately:

```sh
swift test --package-path osax --sanitize=address
swift test --package-path osax --sanitize=thread
```

Daemon sanitizers do not instrument binaries embedded as byte arrays. Builds and isolated tests
do not deploy, restart the service or inject into Dock. See [live testing](live-testing.md) before
any deployment; retain signing as an explicit step after building.
