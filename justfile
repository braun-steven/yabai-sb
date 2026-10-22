set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

build_path := "bin"
doc_path := "doc"
script_path := "scripts"
asset_path := "assets"
sample_path := "examples"
archive_path := "archive"

# SWIFT selects only the outer driver. DEVELOPER_DIR/TOOLCHAINS select tools for both builds.
swift := env("SWIFT", "xcrun swift")
swift_flags := env("SWIFT_FLAGS", "")

# Package.swift reads it to stamp the right SDK version into the binary.
export SDKROOT := env("SDKROOT", `xcrun --sdk macosx --show-sdk-path`)

# Build with SwiftPM and publish only after success, keeping the previous executable and other bin/ artifacts on failure.
build: (_publish "--configuration debug")

[private]
_publish build_flags:
    {{ swift }} build --product yabai --arch arm64 {{ swift_flags }} {{ build_flags }}
    mkdir -p {{ build_path }}
    cp "$({{ swift }} build --product yabai --arch arm64 {{ swift_flags }} {{ build_flags }} --show-bin-path)/yabai" {{ build_path }}/.yabai.tmp
    mv -f {{ build_path }}/.yabai.tmp {{ build_path }}/yabai

# Build and publish the optimized executable; this does not install or restart the service.
install: (_publish "--configuration release")

# Build and publish with AddressSanitizer and UndefinedBehaviorSanitizer.
asan: (_publish "--configuration debug --scratch-path .build/asan --sanitize=address --sanitize=undefined")

# Build and publish with ThreadSanitizer and UndefinedBehaviorSanitizer.
tsan: (_publish "--configuration debug --scratch-path .build/tsan --sanitize=thread --sanitize=undefined")

# Optional: build just the embedded scripting addition through SwiftPM.
prepare:
    {{ swift }} build --target OSAX {{ swift_flags }}

# Run daemon and core tests; trailing arguments are forwarded to SwiftPM.
test *args:
    {{ swift }} test {{ swift_flags }} "$@"

# Optional style lint with swift-format (config .swift-format). Reports findings only; it does not reformat and is not part of ci.
lint:
    {{ swift }} format lint --recursive Sources tests

# CI gates print concise per-step output and keep full logs in .build/ci/; quick runs build and test, full also runs release, osax-test and check-build.
ci-quick:
    SWIFT="{{ swift }}" SWIFT_FLAGS="{{ swift_flags }}" bash {{ script_path }}/ci.sh quick

# Run all CI gates, including release, payload tests and build checks.
ci:
    SWIFT="{{ swift }}" SWIFT_FLAGS="{{ swift_flags }}" bash {{ script_path }}/ci.sh full

# Line coverage of Sources/ per file; filter is an extended regex of the files to show.
coverage filter="":
    SWIFT="{{ swift }}" SWIFT_FLAGS="{{ swift_flags }}" bash {{ script_path }}/coverage.sh {{ quote(filter) }}

# Check clean, incremental and toolchain-upgrade builds in an isolated copy.
check-build:
    python3 {{ script_path }}/check-build.py --swift "{{ swift }}"

# Run isolated payload and loader tests; trailing arguments are forwarded to SwiftPM.
osax-test *args:
    {{ swift }} test --package-path osax {{ swift_flags }} "$@"

# Build the standalone arm64e payload without installing or injecting it.
osax-payload:
    bash {{ script_path }}/build-osax.sh .build/osax/swift

# Regenerate the man page from its Asciidoc source.
man:
    asciidoctor -b manpage {{ doc_path }}/yabai.asciidoc -o {{ doc_path }}/yabai.1

# Set the icon on the built executable.
icon:
    python3 {{ script_path }}/seticon.py {{ asset_path }}/icon/2x/icon-512px@2x.png {{ build_path }}/yabai

# Update the install script's version and release archive hash.
publish:
    sed -i '' "s/^VERSION=.*/VERSION=\"$({{ build_path }}/yabai --version | cut -d v -f 2)\"/" {{ script_path }}/install.sh
    sed -i '' "s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shasum -a 256 {{ build_path }}/$({{ build_path }}/yabai --version).tar.gz | cut -d ' ' -f 1)\"/" {{ script_path }}/install.sh

# Build the release archive after generating docs, building, signing and setting the icon.
archive: man install sign icon
    rm -rf {{ archive_path }}
    mkdir -p {{ archive_path }}/bin
    cp {{ build_path }}/yabai {{ archive_path }}/bin/
    cp -r {{ doc_path }} {{ archive_path }}/
    cp -r {{ sample_path }} {{ archive_path }}/
    tar -cvzf {{ build_path }}/$({{ build_path }}/yabai --version).tar.gz {{ archive_path }}
    rm -rf {{ archive_path }}

# Sign the built executable with the configured Developer ID certificate.
sign:
    codesign -fs "yabai-cert" {{ build_path }}/yabai

# Remove the published executable directory.
clean-build:
    rm -rf {{ build_path }}

# Remove published binaries, SwiftPM caches and generated payload C files.
clean: clean-build
    rm -rf .build osax/.build
    rm -f osax/payload_bin.c osax/loader_bin.c
