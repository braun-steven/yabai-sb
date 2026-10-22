# Split SWIFT/SWIFT_FLAGS on whitespace without expanding wildcard characters.
set shell := ["bash", "-efuo", "pipefail", "-c"]

build_path := "bin"
doc_path := "doc"
script_path := "scripts"
archive_path := "archive"

# SWIFT selects only the outer driver. DEVELOPER_DIR/TOOLCHAINS select tools for both builds.
export SWIFT := env("SWIFT", "xcrun swift")
export SWIFT_FLAGS := env("SWIFT_FLAGS", "")

# Package.swift reads it to stamp the right SDK version into the binary.
export SDKROOT := `if [[ ${SDKROOT+x} ]]; then printf '%s' "$SDKROOT"; else xcrun --sdk macosx --show-sdk-path; fi`

# Build with SwiftPM and publish only after success, keeping the previous executable and other bin/ artifacts on failure.
[default]
build: (_publish "--configuration debug")

[private]
_publish build_flags:
    $SWIFT build --product yabai --arch arm64 $SWIFT_FLAGS {{ build_flags }}
    mkdir -p {{ quote(build_path) }}
    cp "$($SWIFT build --product yabai --arch arm64 $SWIFT_FLAGS {{ build_flags }} --show-bin-path)/yabai" {{ quote(build_path / ".yabai.tmp") }}
    mv -f {{ quote(build_path / ".yabai.tmp") }} {{ quote(build_path / "yabai") }}

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

# Optional style lint with swift-format (config .swift-format). Reports findings only; it does not reformat and is not part of ci.
lint:
    $SWIFT format lint --recursive Sources tests

# CI gates print concise per-step output and keep full logs in .build/ci/; quick runs build and test, full also runs release, osax-test and check-build.
ci-quick:
    bash {{ quote(script_path / "ci.sh") }} quick

# Run all CI gates, including release, payload tests and build checks.
ci:
    bash {{ quote(script_path / "ci.sh") }} full

# Line coverage of Sources/ per file; filter is an extended regex of the files to show.
coverage filter="":
    bash {{ quote(script_path / "coverage.sh") }} {{ quote(filter) }}

# Check clean, incremental and toolchain-upgrade builds in an isolated copy.
check-build:
    python3 {{ quote(script_path / "check-build.py") }} --swift "$SWIFT"

# Run isolated payload and loader tests; trailing arguments are forwarded to SwiftPM.
[positional-arguments]
osax-test *args:
    $SWIFT test --package-path osax $SWIFT_FLAGS "$@"

# Build the standalone arm64e payload without installing or injecting it.
osax-payload:
    bash {{ quote(script_path / "build-osax.sh") }} .build/osax/swift

# Regenerate the man page from its Asciidoc source.
man:
    asciidoctor -b manpage {{ quote(doc_path / "yabai.asciidoc") }} -o {{ quote(doc_path / "yabai.1") }}

# Set the icon on the built executable.
icon:
    python3 {{ quote(script_path / "seticon.py") }} assets/icon/2x/icon-512px@2x.png {{ quote(build_path / "yabai") }}

# Update the install script's version and release archive hash.
publish:
    sed -i '' "s/^VERSION=.*/VERSION=\"$({{ quote(build_path / "yabai") }} --version | cut -d v -f 2)\"/" {{ quote(script_path / "install.sh") }}
    sed -i '' "s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shasum -a 256 {{ quote(build_path) }}/$({{ quote(build_path / "yabai") }} --version).tar.gz | cut -d ' ' -f 1)\"/" {{ quote(script_path / "install.sh") }}

# Build the release archive after generating docs, building, signing and setting the icon.
archive: man install sign icon
    rm -rf {{ quote(archive_path) }}
    mkdir -p {{ quote(archive_path / "bin") }}
    cp {{ quote(build_path / "yabai") }} {{ quote(archive_path / "bin/") }}
    cp -r {{ quote(doc_path) }} {{ quote(archive_path) }}/
    cp -r examples {{ quote(archive_path) }}/
    tar -cvzf {{ quote(build_path) }}/$({{ quote(build_path / "yabai") }} --version).tar.gz {{ quote(archive_path) }}
    rm -rf {{ quote(archive_path) }}

# Sign the built executable with the named signing identity.
sign:
    codesign -fs "yabai-cert" {{ quote(build_path / "yabai") }}

# Remove the published executable directory.
clean-build:
    rm -rf {{ quote(build_path) }}

# Remove published binaries, SwiftPM caches and generated payload C files.
clean: clean-build
    rm -rf .build osax/.build
    rm -f osax/payload_bin.c osax/loader_bin.c
