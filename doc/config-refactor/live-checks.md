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
- [ ] C2.2 A bad `yabai.toml` is reported with its line by `yabai --check-config` and by `yabai -m config --check`, and `config --reload` refuses it — Steps: 1. Copy any TOML file with a `[config]` table to `/tmp/check.toml` (not into `~/.config/yabai`). 2. Set `window_gap = "x"` as a line of that table. 3. Run `bin/yabai --check-config /tmp/check.toml` (no daemon needed). 4. After the deploy, run `yabai -m config --check /tmp/check.toml`, then `yabai -m config --reload /tmp/check.toml`. 5. Run `yabai -m config window_gap`. — Expect: step 3 prints `/tmp/check.toml:<line>: config.window_gap: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer` on stderr, the summary `checked N settings, 1 failures`, and exit status 1. Step 4 prints the same report as a failure; the reload fails with `config --reload does not read TOML files yet; '/tmp/check.toml' is a yabai.toml`. Step 5 shows the value from before the check, unchanged. — Result: <filled in by the user>
