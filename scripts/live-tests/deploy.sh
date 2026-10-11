#!/bin/bash
# usage: deploy.sh [install|asan|tsan]
# Builds the checked-out tree, signs it with the yabai-cert identity, installs it over ~/.local/bin/yabai and
# restarts the service. Meant to be run by the user (see doc/live-testing.md); back up the installed binary first.
set -e
S=${TMPDIR:-/tmp}/yabai-live-build; mkdir -p $S
cd "$(dirname "$0")/../.."
make ${1:-install} > $S/build.log 2>&1 || { tail -30 $S/build.log; exit 1; }
grep "warning:" $S/build.log | grep -v "sprintf' is deprecated" | head || true
cp bin/yabai $S/yabai.new
codesign --force --sign 3A6E8695062DDC7C02B02042FB3DB70B41E75409 $S/yabai.new
codesign -d -r- $S/yabai.new 2>&1 | grep designated
cp $S/yabai.new ~/.local/bin/yabai.tmp && mv -f ~/.local/bin/yabai.tmp ~/.local/bin/yabai
~/.local/bin/yabai --restart-service
sleep 2; pgrep -x yabai
