#!/usr/bin/env sh
#
# Triggers the SketchyBar event space_change for each space change, so that items can redraw. Each line that yabai
# prints is one event; the first line only lists the subscribed events, and the loop triggers on it too, which redraws
# once at start. The loop ends when yabai ends the subscription (it restarts or stops), and then this script exits.
#
# Start it with: sh examples/sketchybar-subscribe.sh &
#

yabai -m subscribe space_changed | while read -r line; do
  sketchybar --trigger space_change
done
