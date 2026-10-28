#!/bin/bash
# Runs IPC commands that only query, fail before acting, or change the daemon's own state (labeled rules and signals,
# removed again), and prints each response with its exit code. Run it on the installed build and on a test build,
# each right after a restart, and diff the outputs: `--display mouse` follows the cursor, and a long-running daemon can
# hold stale space ids in its rules. The config commands only read options, fail, or set an option of the config file to
# the value it already has. Usage: bash ipc_compare.sh > out.txt
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
run rule --add label=claude_p4 app='^NoSuchAppClaudeP4$' title!='x' manage=off sticky=on sub-layer=above grid=2:2:0:0:1:1 space=^5 mouse_follows_focus=off native-fullscreen=on scratchpad=claudep4
run rule --add --one-shot label=claude_p4b app='^NoSuchAppClaudeP4$' display=^2
run rule --list
run rule --remove claude_p4
run rule --remove claude_p4b
run rule --remove claude_p4
run rule --add app='(' manage=maybe colour=red display=7 space=^ scratchpad=float label!=x grid=2:2 sub-layer=top bogus
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
run config window_border_width
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

# P5: the config domain and the client
for option in debug_output mouse_follows_focus focus_follows_mouse display_arrangement_order builtin_display_last \
    window_origin_display window_shadow insert_feedback_color window_border \
    window_border_width window_border_hide_single active_window_border_color normal_window_border_color tab_bar \
    tab_bar_height tab_bar_offset tab_bar_font tab_bar_icons tab_bar_backdrop tab_bar_card_padding \
    tab_bar_window_radius tab_bar_focused_color tab_bar_focused_text_color tab_bar_inactive_color \
    tab_bar_inactive_text_color tab_bar_unfocused_color tab_bar_unfocused_text_color tab_bar_backdrop_color \
    top_padding bottom_padding left_padding right_padding layout window_gap auto_padding tree_default_orientation \
    tree_workspace_layout tree_autotiling focus_wrapping mouse_modifier mouse_action1 mouse_action2 mouse_drop_action \
    external_bar skip_window_focus_animation space_layout scratchpad_exclusive scratchpad_raise scratchpad_below \
    scratchpad_grid; do
    run config "$option"
done
run config --space 4 layout
run config --space 4 top_padding
run config --space 4 window_gap
run config --space 4 auto_padding
run config --space 4 space_layout 15
run config --space 99 layout
run config --space bogus layout
run config --space
run config mouse_modifier focus_wrapping tab_bar_height
run config mouse_modifier bogus_option tab_bar_height
run config mouse_follows_focus maybe
run config focus_follows_mouse sometimes
run config display_arrangement_order diagonal
run config window_shadow sometimes
run config insert_feedback_color 0x0
run config insert_feedback_color red
run config window_border_width 0
run config active_window_border_color 255
run config tab_bar_height 0
run config tab_bar_offset 2.5
run config tab_bar_offset nan
run config tab_bar_backdrop frosted
run config tab_bar_card_padding -1
run config tab_bar_window_radius 1.5
run config tab_bar_font
run config tab_bar_focused_color green
run config top_padding 1.5
run config window_gap -1
run config layout bsp
run config tree_default_orientation diagonal
run config tree_workspace_layout stacked
run config mouse_modifier none
run config mouse_action1 swap
run config mouse_drop_action move
run config external_bar some:1:2
run config external_bar toolong:1:2
run config external_bar all:x
run config space_layout 10::5
run config space_layout 0
run config space_layout 1b:2b
run config space_layout 15 15
run config space_layout 1 2 3 4 5 6 7 8 9
run config space_layout bogus
run config scratchpad_grid 0:4:1:1:2:2
run config scratchpad_grid 4:4
run config mouse_follows_focus off focus_follows_mouse off window_origin_display focused window_shadow off
run config mouse_modifier alt mouse_action1 move mouse_action2 resize mouse_drop_action swap
run config scratchpad_grid 40:40:1:1:38:38 scratchpad_grid
run config tree_default_orientation auto tree_workspace_layout default focus_wrapping on tree_autotiling off
run config tab_bar_height 24 tab_bar_offset 2 tab_bar_focused_color 0xff285577 tab_bar_focused_color
run config space_layout 15 10:5 10:5:1b space_layout
run config external_bar all:0:0 external_bar
run config insert_feedback_color 0xffd75f5f window_border_width 4.0 window_border_width
run query --spaces id,index,label,display,windows
# P6: the full json of every query (it only reads), and space, window, display, rule and signal commands that fail
# before they act. Window titles can change between the runs (e.g. a terminal's); compare those lines by eye.
run query --displays
run query --displays --display
run query --displays --space 4
run query --displays --window
run query --spaces
run query --spaces --display 1
run query --spaces --space
run query --spaces --space 4
run query --spaces --window
run query --windows
run query --windows --display 1
run query --windows --space 4
run query --windows --window
run query --windows id,app,frame,split-type,stack-index,has-parent-zoom,has-fullscreen-zoom --space 4
run query --windows title,role,subrole,level,sub-level,layer,sub-layer,has-shadow --space 4
run query --windows root-window,display,space,can-move,can-resize,is-visible,is-sticky,is-floating --space 5
run query --tree
run query --tree --space 4
run query --tree --space 5
run query --tree --space 12
run query --bogus
run space --rotate 45
run space --mirror z-axis
run space --padding bogus
run space --gap abs:x
run space --toggle bogus
run space --layout bsp
run space --equalize z-axis
run space --balance diagonal
run space --bogus
run space --create 9
run space --move 99
run space --swap bogus
run space --display 9
run space --destroy bogus
run space --focus
run space 99 --label x
run display --bogus
run display --space 99
run display --focus bogus
run display 9 --label x
run window --grid 0:0
run window --move abs:x
run window --resize bogus
run window --ratio rel
run window --layout stacked
run window --split diagonal
run window --swap bogus
run window --warp bogus
run window --stack 99999999
run window --display 9
run window --space 99
run window --raise bogus
run window --lower stack.bogus
run window --scratchpad 12
run window --deminimize bogus
run window --close 99999999
run window --minimize bogus
run window --bogus
run window 99999999 --toggle float
run rule --remove no_such_label_claude
run rule --remove 1.5
run rule --apply 0x10
run signal --remove no_such_label_claude
run signal --remove 0x10
run signal --bogus
run rule --bogus
printf '$ (no -m arguments)\n'; out=$("$Y" -m 2>&1); printf '%s\n[exit %d]\n' "$out" "$?"
printf '$ (USER unset)\n'; out=$(env -u USER "$Y" -m query --spaces 2>&1); printf '%s\n[exit %d]\n' "$out" "$?"
