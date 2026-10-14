#!/bin/bash
# Runs IPC commands that only query, fail before acting, or change the daemon's own state (labeled rules and signals,
# removed again), and prints each response with its exit code. Run it on the installed build and on a test build,
# each right after a restart, and diff the outputs: `--display mouse` follows the cursor, and a long-running daemon can
# hold stale space ids in its rules. Usage: bash ipc_compare.sh > out.txt
Y=~/.local/bin/yabai

run() {
    printf '$ %s\n' "$*"
    out=$("$Y" -m "$@" 2>&1); code=$?
    printf '%s\n[exit %d]\n' "$out" "$code"
}

run query --displays id,index
run query --displays --display 1
run query --displays id --display 2
run query --displays id --display 3
run query --displays id --display east
run query --displays id --display west
run query --displays id --display north
run query --displays id --display first
run query --displays id --display last
run query --displays id --display mouse
run query --displays id --display bogus
run query --displays id --display 0x10
run query --displays id --display 1.5
run query --spaces index,display --space 4
run query --spaces index --space 99
run query --spaces index --space first
run query --spaces index --space last
run query --spaces index --space bogus
run query --spaces index,label
run query --spaces id,,index
run query --spaces id,bogus,also
run query --spaces id,
run query --windows --everything
run query --windows id --window 99999999
run query --windows id --window bogus
run query --windows id --window stack.bogus
run query --windows id --window stack.0
run query --tree --space 99
run query --tree --bogus
run rule --add label=claude_p4 app='^NoSuchAppClaudeP4$' title!='x' manage=off sticky=on sub-layer=above opacity=0.9 grid=2:2:0:0:1:1 space=^5 mouse_follows_focus=off native-fullscreen=on scratchpad=claudep4
run rule --add --one-shot label=claude_p4b app='^NoSuchAppClaudeP4$' display=^2
run rule --list
run rule --remove claude_p4
run rule --remove claude_p4b
run rule --remove claude_p4
run rule --add app='(' manage=maybe colour=red display=7 space=^ scratchpad=float label!=x opacity=2 grid=2:2 sub-layer=top bogus
run rule --add manage=on
run rule --apply 9999
run rule --remove 9999
run rule --remove 0x10
run signal --add label=claude_p4 event=window_focused app!='^Finder$' title='x' action='true' active=yes
run signal --list
run signal --remove claude_p4
run signal --add event=nope action=x
run signal --add label!=x
run signal --add event=window_focused app='(' active=maybe action=x
run signal --remove 9999
run config mouse_modifier
run config focus_wrapping
run config window_opacity_duration
run config top_padding
run config mouse_follows_focus
run config layout bsp
run config mouse_modifier none
run config bogus_option
run window --toggle claude_no_such_scratchpad
run window --sub-layer top
run window --insert up
run window 99999999 --focus
run window --focus stack.bogus
run space --label recent
run space --label 12
run display --label west
run space 99 --focus
run display 9 --focus
run bogus --domain
