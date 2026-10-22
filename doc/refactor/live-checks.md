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
