# Phase 4: Built-in scripting addition loading

**Goal:** with `[daemon] load_scripting_addition = true`, the daemon loads the scripting addition itself at startup and
after the Dock restarts, so no shell command or signal is needed.

**Prerequisites:** phase 3. **Phase gate:** `just ci` (and `just osax-test` if anything under `osax/` is touched; nothing
should be).

**Background:**

- `yabai --load-sa` (`YabaiOptions.loadSA`, `Sources/Yabai/ScriptingAddition.swift`) must run as root; the daemon runs
  as the user. The user's yabairc runs `sudo yabai --load-sa` with a passwordless sudoers entry, at startup and from a
  `dock_did_restart` signal.
- `Workspace.swift` posts `.dockDidRestart`; its handler is `EventHandler.dockDidRestart()`.
- `swift-subprocess` is already used (`Service.swift`, `ScriptingAddition.swift`). Signals spawn `sh -c` per subscriber
  (`EventSignal.swift`).
- No payload behavior or protocol changes: do not bump `OSAX_VERSION`.

| ID | Title | Depends on |
|---|---|---|
| C4.1 | Run `sudo -n yabai --load-sa` from the daemon | — |
| C4.2 | Load at startup and after the Dock restarts | C4.1 |

---

## C4.1 Run `sudo -n yabai --load-sa` from the daemon

**Steps**

1. A pure argv builder in YabaiCore: `["/usr/bin/sudo", "-n", <executable path>, "--load-sa"]`, where the executable
   path is the running binary's resolved path (`_NSGetExecutablePath` + `realpath`, read once at startup in the Yabai
   caller). `-n` makes sudo fail instead of prompting.
2. `ScriptingAdditionLoader.load(reason:)` in `Sources/Yabai`: runs the argv with swift-subprocess **off the event
   loop** (a detached task that only posts back), with a 30 s timeout, and posts `.scriptingAdditionLoaded(result)`.
   The handler logs the result (`Logger.sa` or the component logger the payload code uses). A failure (exit status,
   `sudo: a password is required`, timeout) notifies `scripting addition: could not load (<reason>); see sudoers setup in
   the man page`. One run at a time: a request while one runs is coalesced into one more run after it.
3. Headless: record the request instead of spawning (`Headless.record(scriptingAdditionLoad:)`).
4. Tests: the argv builder; the coalescing logic (pure state in YabaiCore); a `DaemonState` test that a request records
   one headless entry. Run `swift test --sanitize=thread` and `--sanitize=address`.

**Acceptance:** tests and sanitizers pass; nothing on the event loop waits for the process.

**Gate:** quick + sanitizers. **Commit:** `C4.1 Load the scripting addition through sudo from the daemon`.

---

## C4.2 Load at startup and after the Dock restarts

**Steps**

1. When `daemon.load_scripting_addition` is true: request a load once the startup apply is done, before
   `config_loaded` fires, and on every `.dockDidRestart` (after the existing handler's work). Turning it on through a
   reload requests a load; turning it off does nothing else.
2. The daemon's own payload calls already cope with a missing payload; check that the first payload use after the load
   result arrives works (the SA connection reconnects) and note the result in `doc/payload-updates.md` if it needs a
   step.
3. Replace the temporary `[[signal]] event = "dock_did_restart" action = "sudo yabai --load-sa"` entry in
   `examples/yabai.toml` with the setting. Do **not** edit the user's `~/.config/yabai/yabai.toml`; add a live check for
   the user to remove that signal there.
4. Docs: asciidoc `[daemon]` section (`load_scripting_addition`, with the sudoers line it needs, taken from the
   upstream wiki text already referenced in `examples/yabairc`), CHANGELOG, README "Fork changes" entry extended.

**Live check:** the user removes the `dock_did_restart` load signal from `~/.config/yabai/yabai.toml`, sets
`load_scripting_addition = true`, deploys, and checks: `yabai -m query --spaces` works and `space --focus` switches
without the slide animation (payload loaded); `killall Dock`, wait 5 s, check the same again; the log shows two load
results. Then set it to false in a copy and confirm `yabai --check-config` still passes.

**Acceptance:** tests pass; no `sudo` was run by any agent.

**Gate:** quick. **Commit:** `C4.2 Load the scripting addition at startup and after Dock restarts`.
