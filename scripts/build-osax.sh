#!/bin/bash
# Build the arm64e binaries and embed them in C sources, without installing or injecting them.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: build-osax.sh <output-directory>" >&2; exit 2; }

mkdir -p "$1"
output="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
source ./scripts/osax-toolchain.sh
osax_select_toolchain
trap 'rm -f "$output/payload_bin.c.tmp" "$output/loader_bin.c.tmp"' EXIT

native_flags=(-O3 -mmacosx-version-min=27.0 -arch arm64e -fno-objc-arc -Wall -Wextra -Werror -isysroot "$osax_sdk")
"$osax_clang" -c ./osax/payload.m "${native_flags[@]}" -o "$output/native.o"
"$osax_clang" -c ./osax/core/api/API.c "${native_flags[@]}" -o "$output/api.o"

# NOTE: Keep the original install name explicit so plugin work-directory changes preserve the
# live-tested payload bytes. It is a library identifier, not the location used for injection.
"$osax_swiftc" -emit-library -O -swift-version 6 -warnings-as-errors -sdk "$osax_sdk" \
    -target arm64e-apple-macosx27.0 -module-cache-path "$output/module-cache" \
    -I ./osax/core/api/include ./osax/core/swift/Core.swift "$output/native.o" "$output/api.o" \
    -o "$output/payload" -F/System/Library/PrivateFrameworks \
    -framework SkyLight -framework Foundation -framework Carbon \
    -Xlinker -install_name -Xlinker .build/osax/swift/payload

"$osax_clang" ./osax/loader.m ./osax/bootstrap.S "${native_flags[@]}" \
    -o "$output/loader" -framework Cocoa

embed()
{
    local input="$1" symbol="$2" source="$3"
    xxd -i -a -n "$symbol" "$input" "$source.tmp"
    if ! cmp -s "$source.tmp" "$source"; then
        mv -f "$source.tmp" "$source"
    fi
}

# Preserve timestamps when an input change produces identical embedded bytes.
embed "$output/payload" __osax_payload "$output/payload_bin.c"
embed "$output/loader" __osax_loader "$output/loader_bin.c"
