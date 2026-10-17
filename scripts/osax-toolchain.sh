#!/bin/bash
# Shared selection for the plugin's identity check and the native compiler commands.
set -euo pipefail

osax_select_toolchain()
{
    osax_sdk="$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-path)"
    osax_clang="$(xcrun --sdk "$osax_sdk" --find clang)"
    osax_swiftc="$(xcrun --sdk "$osax_sdk" --find swiftc)"
    export SDKROOT="$osax_sdk"
}

osax_toolchain_identity()
{
    printf 'DEVELOPER_DIR=%s\nTOOLCHAINS=%s\nSDKROOT=%s\n' \
        "${DEVELOPER_DIR:-}" "${TOOLCHAINS:-}" "$osax_sdk"
    printf 'clang=%s\n' "$osax_clang"
    stat -L -f '%i:%z:%m:%c' "$osax_clang"
    "$osax_clang" --version
    printf 'swiftc=%s\n' "$osax_swiftc"
    stat -L -f '%i:%z:%m:%c' "$osax_swiftc"
    "$osax_swiftc" --version
    shasum -a 256 "$osax_sdk/SDKSettings.json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 1 ]] || { echo "usage: osax-toolchain.sh <identity-header>" >&2; exit 2; }
    osax_select_toolchain
    mkdir -p "$(dirname "$1")"
    trap 'rm -f "$1.tmp"' EXIT
    # A comment-only header is a supported generated C artifact, without adding runtime resources.
    osax_toolchain_identity | sed 's|^|// |' > "$1.tmp"
    if ! cmp -s "$1.tmp" "$1"; then
        mv -f "$1.tmp" "$1"
    fi
fi
