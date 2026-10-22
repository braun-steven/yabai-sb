# Live checks

These are checks that need the real window server, Dock or `sudo`. Agents append them here; the user runs them, best
after each phase. Use `update-yabai-fork` in a real terminal, or `bash scripts/live-tests/deploy.sh install` followed
by `restore`. Payload changes also need two runs of `sudo ~/.local/bin/yabai --load-sa`. Afterwards, tick the box and
note the result. If a check fails, add a line under "Discovered" in `status.md` with the subphase ID.

Template:

```text
- [ ] P<ID> <what to check> — Steps: <numbered steps> — Expect: <result> — Result: <filled in by the user>
```

## Pending

<!-- agents append below this line -->
- [ ] P2.2 SLS notifications still handled after the typed-enum rewrite (space create/destroy, window move/resize/order/destroy) — Steps: 1. Deploy the build with `update-yabai-fork` (real terminal) or `bash scripts/live-tests/deploy.sh install`. 2. Add a desktop in Mission Control, then run `yabai -m query --spaces` and check that the new space is listed; remove it again and check that it is gone from the list. 3. With a bordered window tiled on a space, drag it, resize it and check that its border follows (no stale border left at the old frame). 4. Focus another window on the same space and check that the bordered window's border is ordered correctly (no border above a window that covers it). 5. Close a bordered window and check that its border disappears and that `yabai -m query --windows` no longer lists it. 6. Press cmd-tab once and check that the switcher still works and yabai keeps running. 7. Restore the installed binary afterwards. — Expect: every step matches its description; yabai still running after every step (no crash report for yabai in Console), no stale borders, space list and window list updated on create/destroy/close. — Result: <filled in by the user>
- [ ] P2.3 Bridged window move still works after the Mach-O symbol lookup and the timer change — Steps: 1. Deploy the build with `update-yabai-fork` (real terminal) or `bash scripts/live-tests/deploy.sh install`. 2. Open a second desktop on the same display. 3. Focus a tiled window on desktop 1 and run `yabai -m window --space 2`. 4. Run `yabai -m query --windows --space 2` and check that the window is listed. 5. Move it back with `yabai -m window --space 1` and check the same. 6. Restore the installed binary afterwards. — Expect: the window moves both ways, the commands exit 0, and yabai keeps running (no crash report for yabai in Console). — Result: <filled in by the user>
- [ ] P2.3 Notification icon path after the KVC guard — Steps: 1. Stop the running service (`yabai --stop-service`). 2. In a terminal, run `./bin/yabai -c "$TMPDIR/p23-missing.rc"` (a config file that does not exist). 3. Check that a notification titled "yabai" with subtitle "configuration" appears, and that yabai keeps running in the terminal. 4. Stop it with ctrl-c, then restart the service with the restored installed binary. — Expect: the notification is shown (with or without the yabai icon) and the process does not exit. A missing icon key must not crash the daemon. — Result: <filled in by the user>
