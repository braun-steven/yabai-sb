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
    $SWIFT scripts/seticon.swift assets/icon/2x/icon-512px@2x.png bin/yabai

# Build the release archive after generating docs, building, signing and setting the icon.
archive: man install sign icon
    rm -rf archive
    mkdir -p archive/bin
    cp bin/yabai archive/bin/
    mkdir -p archive/doc
    cp doc/yabai.1 doc/yabai.schema.json archive/doc/
    cp -r examples archive/
    tar -cvzf bin/$(bin/yabai --version).tar.gz archive
    rm -rf archive

# Raise Daemon.version by a major, minor or patch step and move the CHANGELOG's Unreleased entries under it; commits nothing.
bump-version level:
    #!/usr/bin/env bash
    set -euo pipefail
    level={{ quote(level) }}
    file=Sources/Yabai/Yabai.swift
    changelog=CHANGELOG.md
    [[ -z "$(git status --porcelain --untracked-files=no -- "$file" "$changelog")" ]] || { echo "Commit or stash $file and $changelog first" >&2; exit 1; }
    grep -qx '## \[Unreleased\]' "$changelog" || { echo "No '## [Unreleased]' heading in $changelog" >&2; exit 1; }
    current="$(sed -n 's/^  static let version = "yabai-sb-v\([0-9.]*\)"$/\1/p' "$file")"
    [[ -n "$current" ]] || { echo "No version in $file" >&2; exit 1; }
    IFS=. read -r major minor patch <<< "$current"
    case "$level" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Usage: just bump-version major|minor|patch" >&2; exit 1 ;;
    esac
    version="$major.$minor.$patch"
    sed -i '' -e "s/^  static let version = \"yabai-sb-v[0-9.]*\"$/  static let version = \"yabai-sb-v$version\"/" "$file"
    sed -i '' -e "s/^## \[Unreleased\]$/&\n\n## [$version] - $(date +%Y-%m-%d)/" "$changelog"
    echo "Bumped $current to $version; review with: git diff -- $file $changelog"

# Archive HEAD, publish it as a GitHub release and point the Homebrew tap formula at it (commits the tap, never pushes).
brew-release: _brew-release-check archive
    #!/usr/bin/env bash
    set -euo pipefail
    tap="${YABAI_TAP_DIR:-../homebrew-tap}"
    version="$(bin/yabai --version)"
    tarball="bin/$version.tar.gz"
    sha="$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)"
    gh release create "${version#yabai-sb-}" "$tarball" --repo braun-steven/yabai-sb \
        --target "$(git rev-parse HEAD)" --title "${version#yabai-sb-}" --notes "See CHANGELOG.md."
    url="https://github.com/braun-steven/yabai-sb/releases/download/${version#yabai-sb-}/$version.tar.gz"
    sed -i '' -e "s|^  url \".*\"|  url \"$url\"|" -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" "$tap/Formula/yabai-sb.rb"
    git -C "$tap" commit -q -m "yabai-sb ${version#yabai-sb-}" -- Formula/yabai-sb.rb
    echo "Released ${version#yabai-sb-}; push the tap with: git -C $tap push"

[private]
_brew-release-check:
    #!/usr/bin/env bash
    set -euo pipefail
    tap="${YABAI_TAP_DIR:-../homebrew-tap}"
    [[ -f "$tap/Formula/yabai-sb.rb" ]] || { echo "No tap checkout at $tap (set YABAI_TAP_DIR)" >&2; exit 1; }
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit or stash local changes first" >&2; exit 1; }
    git fetch -q origin main
    git merge-base --is-ancestor HEAD origin/main || { echo "Push HEAD to origin/main first" >&2; exit 1; }
    tag="$(sed -n 's/^  static let version = "yabai-sb-v\([^"]*\)"$/\1/p' Sources/Yabai/Yabai.swift)"
    remote_tag="$(git ls-remote --tags origin "refs/tags/v$tag")"
    [[ -z "$remote_tag" ]] || { echo "Tag v$tag is already on origin: bump the version first (just bump-version)" >&2; exit 1; }

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
