#!/bin/bash
# usage: deploy.sh [install|asan|tsan]   builds the checked-out tree, signs it with the yabai-cert identity, installs it
#                                        over ~/.local/bin/yabai and restarts the service
#        deploy.sh restore               puts back the binary that was installed before the first deploy
# The first deploy backs up the installed binary to ~/.local/state/yabai/yabai.before-deploy. Later deploys keep that
# backup, so restore always returns to the binary that update-yabai-fork installed (see doc/live-testing.md).
set -e
S=${TMPDIR:-/tmp}/yabai-live-build; mkdir -p $S
B=~/.local/state/yabai/yabai.before-deploy
cd "$(dirname "$0")/../.."

if [[ $1 == restore ]]; then
    [[ -f $B ]] || { echo "no backup at $B"; exit 1; }
    cp -p $B ~/.local/bin/yabai.tmp && mv -f ~/.local/bin/yabai.tmp ~/.local/bin/yabai
    cmp $B ~/.local/bin/yabai && rm $B
    ~/.local/bin/yabai --restart-service
    sleep 2; pgrep -x yabai
    exit 0
fi

VARIANT=${1:-install}
case $VARIANT in
    install|asan|tsan) ;;
    *) echo "usage: deploy.sh [install|asan|tsan|restore]"; exit 1 ;;
esac

make $VARIANT > $S/build.log 2>&1 || { tail -30 $S/build.log; exit 1; }
grep "warning:" $S/build.log | head || true
cp bin/yabai $S/yabai.new
codesign --force --sign 3A6E8695062DDC7C02B02042FB3DB70B41E75409 $S/yabai.new
codesign -d -r- $S/yabai.new 2>&1 | grep designated
if [[ ! -f $B ]]; then mkdir -p "$(dirname $B)" && cp -p ~/.local/bin/yabai $B; fi
cp $S/yabai.new ~/.local/bin/yabai.tmp && mv -f ~/.local/bin/yabai.tmp ~/.local/bin/yabai
~/.local/bin/yabai --restart-service
sleep 2; pgrep -x yabai
