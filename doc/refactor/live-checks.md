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
