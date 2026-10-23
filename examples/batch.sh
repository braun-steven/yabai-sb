#!/usr/bin/env sh

# `yabai -m batch` sends many commands in one message, one round trip instead of one per command. Its stdin has one
# command per line, as the words after `yabai -m`; nothing is expanded there, so $VARIABLES and $(commands) do not work.
# A yabai.toml file needs no batch: its settings are applied in-process.
yabai -m batch <<'EOF'
config window_gap 6
config top_padding 12
config bottom_padding 12
EOF
