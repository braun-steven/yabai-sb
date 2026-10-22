# Phase 9: Configuration management

**Goal:** config mistakes are reported with the valid choices and with `file:line`, and the config can be checked and
reloaded without restarting the service. A restart resets every layout.

**Prerequisites:** phase 6 (P6.1 generic token lookup, P6.2 shared scanner). **Phase gate:** `make ci`.

**Background:**

- yabairc is a shell script that `Daemon.execConfigFile` (`Yabai.swift`) spawns once at startup, with nobody waiting
  for it.
- Each config option's `parse` returns a `Change` closure without applying it (`ConfigOption` in
  `IPC/MessageConfig.swift`), so validation is already separate from application. This phase builds on that.

Every new command needs:

- handler parsing;
- `doc/yabai.asciidoc` + `make man`;
- a CHANGELOG entry;
- a README "Fork changes" entry (new feature);
- golden commands where they don't act on real displays, spaces or windows.

| ID | Title | Depends on |
|---|---|---|
| P9.1 | Failure messages name the valid values | — |
| P9.2 | Warn when several config files exist | — |
| P9.3 | Dry-run parsing for config, rule and signal commands | — |
| P9.4 | yabairc command extractor | — |
| P9.5 | `yabai -m config --check [file]` | P9.3, P9.4 |
| P9.6 | `yabai -m config --reload [file]` | P9.5 |

---

## P9.1 Failure messages name the valid values

**Where:** `CommandError.unknownValue(domain, command, value)` produces texts like `unknown value '-1' given to command
'window_gap'`, which don't say what is valid. The golden responses are in `tests/YabaiTests/Golden/responses.txt`.

**Steps**

1. Add an optional `expected: String?` to the unknown-value error. When present, the message becomes `unknown value
   '<v>' given to command '<c>'; expected <expected>`.
2. Fill `expected` at the parse sites that know it:
   - choice options: `one of: a, b, c`, from the `CaseIterable` raw values in declaration order;
   - booleans: `on or off`;
   - non-negative integers: `a non-negative integer`;
   - floats in a range: `a number from 0.0 to 1.0`;
   - selectors: `a window selector (see WINDOW_SEL)`.

   Cover at least the config domain fully, plus window/space/display choice arguments.
3. Re-record golden: `GOLDEN_RECORD=1 swift test --filter Golden`. Review every changed record: only the suffix may
   change. Put the count of changed records in the commit body.
4. CHANGELOG: "Error messages list the expected values".

**Acceptance:** the golden diff contains only added `; expected …` suffixes, and the other tests pass. Some tests
assert full failure texts; update those deliberately.

**Gate:** quick. **Commit:** `P9.1 Name the expected values in command failures`.

---

## P9.2 Warn when several config files exist

**Where:** `Daemon.getConfigFile` (`Yabai.swift`) returns the first existing file among `$XDG_CONFIG_HOME/yabai/yabairc`,
`~/.config/yabai/yabairc` and `~/.yabairc`.

**Steps**

1. Collect every existing candidate.
2. When more than one exists, log `Logger.daemon.warning("using <first>; ignoring <others>")` and send one user
   notification through `notify("configuration", …)`.
3. Log the chosen path at notice level in every case.
4. Make the candidate selection a pure function (a list of candidates and an exists-closure in, chosen path and
   ignored list out), and test it.

**Gate:** quick. **Commit:** `P9.2 Warn when several config files exist`.

---

## P9.3 Dry-run parsing for config, rule and signal commands

**Goal:** given the tokens of one `config`, `rule` or `signal` message, report every failure without changing any state.

**Steps**

1. Add `@WM func checkMessage(_ message: inout Message) -> [String]`, next to `handleMessage` in
   `IPC/MessageLoop.swift` or a new `IPC/MessageCheck.swift`. It returns failure texts:
   - **config:** parse the scope and the option, call `option.parse` and **drop** the returned `Change`. A `--space`
     selector is parsed for syntax but not resolved: the check must not depend on the current spaces. Split
     `ConfigCommand.parseScope` from resolution if needed.
   - **rule** / **signal:** run the existing YabaiCore parse functions (`RuleCommand`, `SignalCommand`, `parseSignal`)
     and nothing else. No `add`, no apply.
   - **Other domains** (`space`, `window`, `display`, `query`): return a single note `not checked: <domain> commands
     act on the current session`. This is not a failure.
2. No state may change. Prove it with a `DaemonState` test that snapshots the config, rules and signals, runs
   `checkMessage` on valid and invalid inputs of each kind, and compares the snapshots.

**Acceptance:** the test proves no mutation, and the failure texts equal those of real execution. Test with the same
inputs through `handleMessage` in a fresh fixture.

**Gate:** quick. **Commit:** `P9.3 Check config, rule and signal messages without applying them`.

---

## P9.4 yabairc command extractor

**Goal:** a pure YabaiCore function that finds the `yabai -m …` invocations in a shell script and tokenizes them as the
shell would.

**Steps**

1. Write `func extractYabaiCommands(_ script: String) -> [ExtractedCommand]` in YabaiCore, where `ExtractedCommand =
   (line: Int, arguments: [String]?, skipped: String?)`. It handles:
   - comments (`#` outside quotes) and blank lines;
   - backslash line continuations, with the line number of the first line;
   - single and double quotes, and backslash escapes in double quotes and unquoted text;
   - a command that starts with `yabai -m`, or with a path ending in `/yabai -m`, possibly preceded by `sudo`. Treat
     `sudo yabai --load-sa` as skipped: "not a message".
   - Lines with `$`, backticks, `$(…)`, pipes, `&&`, `||`, `;` and redirections, or inside shell control structures
     (`if`, `for`, `while`, `case`, functions), are reported as `skipped: "dynamic shell"`. Don't evaluate shell.
2. Property-test the quoting: a generated argument list, quoted with a reference quoting function, round-trips. Run it
   ten times.
3. Example tests on `examples/yabairc`: every `yabai -m` line there is extracted, or skipped with a reason.

**Gate:** quick. **Commit:** `P9.4 Extract yabai messages from a yabairc without running it`.

---

## P9.5 `yabai -m config --check [file]`

**Steps**

1. Parse `--check [file]` in the config domain (`ConfigCommand.parseScope` / `handleDomainConfig`). Without `file`,
   check the file the daemon would load: reuse the selection from P9.2, and the `-c` path the daemon was started with.
2. In the daemon:
   - read the file; on failure, reply with a failure response naming the path;
   - extract the commands (P9.4);
   - run `checkMessage` (P9.3) for each extracted command.
3. Response:
   - one line per failure: `<file>:<line>: <failure text>`;
   - one line per skipped command, with a `note:` prefix;
   - a summary: `checked N commands, M failures, K skipped`.

   The response is a failure (`0x07` first byte, so the CLI exits 1) if M > 0.
4. Document it in `doc/yabai.asciidoc` (config domain), run `make man`, add a CHANGELOG entry, and add README "Fork
   changes" ("Config check and reload", one entry with P9.6).
5. Golden: add `config --check /nonexistent` (failure, no side effects). Tests: a fixture yabairc with one bad value,
   one dynamic line and one valid line yields the expected output.

**Gate:** quick. **Commit:** `P9.5 Check a yabairc with config --check`.

---

## P9.6 `yabai -m config --reload [file]`

**Semantics** (document them exactly):

1. Run the P9.5 check. If there are failures, reply with them and change nothing.
2. Otherwise:
   - reset `Config` to its defaults, through the same path `Config` uses at startup, so that `ConfigObserver`
     re-renders;
   - remove every rule and signal;
   - spawn the yabairc again exactly as at startup (`execConfigFile`).

   Windows, trees and spaces stay as they are. Rules apply to new windows only, unless the yabairc runs `rule --apply`.
3. Reply `reloaded <file>`.
4. Imperative commands in the yabairc (`space --create`, …) run again. Document: "keep the yabairc idempotent, as it
   already must be for `--restart-service`".

**Steps**

1. Implement it in the config domain. The reset and spawn happen in one `@WM` handler, so no event interleaves before
   the yabairc starts. The yabairc's own messages then arrive as normal IPC messages.
2. Make `execConfigFile` reusable; it is `private static` in `Daemon` today.
3. Tests (`DaemonState`): with a check failure, nothing changes; with success, config is reset, rules and signals are
   cleared, and a spawn was requested. Inject the spawn as a closure on a concrete type so the test records it instead
   of spawning; no protocol.
4. Docs: asciidoc, `make man`, CHANGELOG. In `examples/yabairc`, add a comment that an skhd binding can call
   `yabai -m config --reload`.

**Acceptance:** tests pass, the golden replay is unchanged (don't add `--reload` to golden: it would spawn a shell),
and the docs are updated.

**Live check:**
- add a deliberate typo to a copy of the yabairc and run `yabai -m config --check <copy>`: you get `file:line` output;
- run `yabai -m config --reload`: layouts stay, and changed gaps and borders apply;
- `yabai -m rule --list` shows no duplicates after two reloads.

**Gate:** quick. **Commit:** `P9.6 Reload the yabairc with config --reload`.
