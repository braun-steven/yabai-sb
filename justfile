# Split SWIFT/SWIFT_FLAGS on whitespace without expanding wildcard characters.
set shell := ["bash", "-efuo", "pipefail", "-c"]

# SWIFT selects only the outer driver. DEVELOPER_DIR/TOOLCHAINS select tools for both builds.
export SWIFT := env("SWIFT", "xcrun swift")
export SWIFT_FLAGS := env("SWIFT_FLAGS", "")

# Package.swift reads it to stamp the right SDK version into the binary.
export SDKROOT := `if [[ ${SDKROOT+x} ]]; then printf '%s' "$SDKROOT"; else xcrun --sdk macosx --show-sdk-path; fi`

# Build with SwiftPM; preserve the previous executable if building or copying fails.
[default]
build: (_publish "--configuration debug")

[private]
_publish build_flags:
    $SWIFT build --product yabai --arch arm64 $SWIFT_FLAGS {{ build_flags }}
    mkdir -p bin
    cp "$($SWIFT build --product yabai --arch arm64 $SWIFT_FLAGS {{ build_flags }} --show-bin-path)/yabai" bin/.yabai.tmp
    mv -f bin/.yabai.tmp bin/yabai

# Build and publish the optimized executable; this does not install or restart the service.
install: (_publish "--configuration release")

# Build and publish with AddressSanitizer and UndefinedBehaviorSanitizer.
asan: (_publish "--configuration debug --scratch-path .build/asan --sanitize=address --sanitize=undefined")

# Build and publish with ThreadSanitizer and UndefinedBehaviorSanitizer.
tsan: (_publish "--configuration debug --scratch-path .build/tsan --sanitize=thread --sanitize=undefined")

# Optional: build just the embedded scripting addition through SwiftPM.
prepare:
    $SWIFT build --target OSAX $SWIFT_FLAGS

# Run daemon and core tests; trailing arguments are forwarded to SwiftPM.
[positional-arguments]
test *args:
    $SWIFT test $SWIFT_FLAGS "$@"

# Optional swift-format lint; reports findings without reformatting, outside CI.
lint:
    $SWIFT format lint --recursive Sources tests

# Build and test with concise output; full logs are in .build/ci/.
ci-quick:
    bash scripts/ci.sh quick

# Smoke-test the built CLI without starting the daemon.
cli-smoke:
    python3 scripts/cli-smoke.py bin/yabai

# Run unit tests for the Python live-test and OSAX harness helpers.
script-test:
    python3 -m unittest discover -s scripts/tests -v

# Run all CI gates, including release, payload tests and build checks.
ci:
    bash scripts/ci.sh full

# Line coverage of Sources/ per file; filter is an extended regex of the files to show.
coverage filter="":
    bash scripts/coverage.sh {{ quote(filter) }}

# Check clean, incremental and toolchain-upgrade builds in an isolated copy.
check-build:
    python3 scripts/check-build.py --swift "$SWIFT"

# Run isolated payload and loader tests; trailing arguments are forwarded to SwiftPM.
[positional-arguments]
osax-test *args:
    $SWIFT test --package-path osax $SWIFT_FLAGS "$@"

# Build the standalone arm64e payload without installing or injecting it.
osax-payload:
    bash scripts/build-osax.sh .build/osax/swift

# Regenerate the man page from its Asciidoc source.
man:
    asciidoctor -b manpage doc/yabai.asciidoc -o doc/yabai.1

# Set the icon on the built executable.
icon:
    python3 scripts/seticon.py assets/icon/2x/icon-512px@2x.png bin/yabai

# Update the install script's version and release archive hash.
publish:
    sed -i '' "s/^VERSION=.*/VERSION=\"$(bin/yabai --version | cut -d v -f 2)\"/" scripts/install.sh
    sed -i '' "s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shasum -a 256 bin/$(bin/yabai --version).tar.gz | cut -d ' ' -f 1)\"/" scripts/install.sh

# Build the release archive after generating docs, building, signing and setting the icon.
archive: man install sign icon
    rm -rf archive
    mkdir -p archive/bin
    cp bin/yabai archive/bin/
    cp -r doc archive/
    cp -r examples archive/
    tar -cvzf bin/$(bin/yabai --version).tar.gz archive
    rm -rf archive

# Sign the built executable with the named signing identity.
sign:
    codesign -fs "yabai-cert" bin/yabai

# Remove the published executable directory.
clean-build:
    rm -rf bin

# Remove published binaries, SwiftPM caches and generated payload C files.
clean: clean-build
    rm -rf .build osax/.build
    rm -f osax/payload_bin.c osax/loader_bin.c
