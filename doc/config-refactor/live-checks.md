# Live checks

These are checks that need the real window server, Dock, `sudo` or the user's own files. Agents append them here; the
user runs them, best after phases 2, 3 and 4. Use `update-yabai-fork` in a real terminal, or
`bash scripts/live-tests/deploy.sh install` followed by `restore`. Deploys restart yabai and reset all layouts. Afterwards,
tick the box and note the result. If a check fails, add a line under "Discovered" in `status.md` with the subphase ID.

Template:

```text
- [ ] C<ID> <what to check> — Steps: <numbered steps> — Expect: <result> — Result: <filled in by the user>
```

## Pending
