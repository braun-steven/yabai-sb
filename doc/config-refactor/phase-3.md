# Phase 3: Non-destructive reload

**Goal:** reloading applies only what differs between the file and the running state, so layouts survive. Runtime IPC
changes are overrides until the next reload. The file reloads itself on save, and a `config_loaded` signal fires after
each load.

**Prerequisites:** phase 2. **Phase gate:** `just ci`.

**Background:**

- `handleConfigReload` (`Sources/Yabai/IPC/ConfigReload.swift`) resets the config (`resetConfigToStartupDefaults`), clears
  `WindowManager.shared.rules` and `EventSignals.shared.table`, and spawns the file. The note at the top of that file
  sorts every option into three kinds by its side effects; use it as the inventory here.
- `doc/refactor/status.md` "Discovered" P9.6 (live): `config layout tree` runs `setLayoutForAllSpaces`, which clears the
  tree of every user space even when its layout is already tree (`Sources/Yabai/SpaceManager+Layout.swift`).
- Delayed events use `EventLoop.post(_:after:key:)` with a `DelayedEventKey`; never `DispatchQueue.asyncAfter`.

| ID | Title | Depends on |
|---|---|---|
| C3.1 | Setters skip unchanged values | — |
| C3.2 | The diff apply engine | C3.1 |
| C3.3 | `config --reload` on the engine, and `config --overrides` | C3.2 |
| C3.4 | Auto-reload on save | C3.3 |
| C3.5 | The `config_loaded` signal event | C3.3 |

---

## C3.1 Setters skip unchanged values

**Steps**

1. Fix `setLayoutForAllSpaces` and `setLayout(_:for:)` to leave a space whose layout does not change alone (no
   `clear()`).
2. Go through every option of the second and third kind in the `ConfigReload.swift` inventory (setters with a window
   server or manager effect) and make setting the current value a no-op: no tap restart, no cache invalidation, no
   relayout. `ConfigObserver` posts a `configChanged` event even for an equal value (doc/architecture.md); keep that, but
   make sure the group's handler does no visible work when nothing changed, or skip the post when the value is equal.
   Pick one, document it in `doc/architecture.md`, and apply it to every group.
3. Tests (`DaemonState`): for each such option, setting the current value records no flush, animation or payload message
   in the headless log; `config layout <current>` keeps a tabbed container (Workspace fixture).
4. Mark Discovered P9.6 (layouts) fixed by C3.1 in `doc/refactor/status.md`.

**Acceptance:** setting any option to its current value changes nothing observable in headless mode.

**Gate:** quick. **Commit:** `C3.1 Leave the state alone when an option is set to its current value`.

---

## C3.2 The diff apply engine

**Where:** `ConfigLoader` (C2.4).

**Steps**

1. Keep the last applied document (`ConfigLoader.applied: ConfigDocument?`) and the file's per-option value.
2. `ConfigLoader.reconcile(to new: ConfigDocument)`:
   - options: for each option of the new document and each option the old document set but the new one does not
     (which goes back to its default), apply it only when the running value differs. Compare through the option's own
     `print` output against the lowered word, normalized the same way, so overrides (C3.3) are found too;
   - `space_layout`: only when it differs;
   - spaces: labels, pins and per-space options, each only when it differs; a removed `[[space]]` entry removes its label,
     pin and per-space values; never create or destroy spaces by index here (AGENTS.md pitfall);
   - rules: replace the whole list when the new rule list differs from the running list; otherwise leave it, so rule
     indices stay;
   - signals: the same as rules.
3. Startup uses `reconcile` against an empty running state, so there is one code path.
4. Tests (`DaemonState`): reconcile with an identical document records nothing; changing one gap changes only that gap;
   removing an option resets it to its default; a reordered rule list replaces the list; a removed space entry removes
   its pin. A property test: for random pairs of documents A and B, applying A then reconciling to B gives the same
   running state as applying B to a fresh state. Run it about ten times.

**Acceptance:** the property test and the no-op test pass.

**Gate:** quick. **Commit:** `C3.2 Reconcile the running config with a document`.

---

## C3.3 `config --reload` on the engine, and `config --overrides`

**Steps**

1. `config --reload [<file>]` checks the file (C2.2); on failure it replies with the failures and changes nothing; on
   success it reconciles (C3.2) and replies `reloaded <file>: <n> changes`. `resetConfigToStartupDefaults` and the spawn
   are no longer used by it (deleted in C5.1 if nothing else uses them).
2. Overrides: a `config <option> <value>`, `config --space …`, `rule --add/--remove` or `signal --add/--remove` over IPC
   after a load is an override. Nothing extra is stored: the next reconcile finds the differences and puts the file's
   values back, and a changed rule or signal list is replaced by the file's.
3. New `config --overrides`: lists the options whose running value differs from the file (`<option> <running>
   (file: <value>)`, one per line, `--space` ones as `space <index> <option> …`), then `rules: overridden` and
   `signals: overridden` lines when those lists differ. Empty output when nothing is overridden.
4. Remove the P9.6 reload-loop check from `checkMessage` (a `config --reload` cannot be inside the file any more) and mark
   Discovered P9.6 (loop) obsolete.
5. Tests (`DaemonState`): a reload after `config window_gap 5` puts the file's gap back; `config --overrides` before and
   after; a failed check changes nothing. Update `ConfigReloadTests`. Golden: re-record the changed records.
6. Docs: asciidoc `config --reload`, `config --overrides` (`just man`), a paragraph on overrides in the CONFIGURATION
   section, CHANGELOG, README "Fork changes" entry extended.

**Live check:** with a tabbed container and a nested split on a space, run `yabai -m config --reload` twice: layouts
stay. Set `yabai -m config window_gap 30`, check `yabai -m config --overrides`, reload: the gap is back.

**Acceptance:** tests pass; reload of an unchanged file replies `0 changes` and records nothing in headless mode.

**Gate:** quick. **Commit:** `C3.3 Reload yabai.toml by reconciling, and list overrides`.

---

## C3.4 Auto-reload on save

**Steps**

1. A `ConfigWatcher` (`Sources/Yabai/ConfigWatcher.swift`) watches the config file's directory with a
   `DispatchSource.makeFileSystemObjectSource` (`.write`, `.rename`, `.delete`) on a private serial queue, so editors
   that save by writing a new file and renaming it are seen. On an event it posts `.configFileChanged` with
   `EventLoop.post(_:after: .milliseconds(200), key: .configReload)`, so a burst of writes is one reload.
2. The handler reads the file; when its contents equal the last loaded contents it does nothing; otherwise it runs the
   C3.3 reload. A failed check logs every line and notifies `configuration: <file> has M errors; kept the running
   config`.
3. `[daemon] auto_reload = false` stops the watcher (also when changed by a reload). The watcher follows the file when
   the directory is replaced (re-open on `.delete` of the directory, with a retry through a delayed event).
4. Tests: the watcher's decision logic is pure and tested in YabaiCore (contents equal, auto_reload off); a socket- and
   timer-free `DaemonState` test posts `.configFileChanged` directly. Run `swift test --sanitize=thread` and
   `--sanitize=address`.
5. Docs: asciidoc `auto_reload`, CHANGELOG.

**Live check:** edit `window_gap` in `yabai.toml` with the user's editor and save: the gap changes within a second, and
the log shows one reload. Save a typo: a notification appears and nothing changes. Fix it and save: it applies.

**Acceptance:** tests and sanitizers pass; no `DispatchQueue.asyncAfter` and no `Task` per event.

**Gate:** quick + sanitizers. **Commit:** `C3.4 Reload yabai.toml when it is saved`.

---

## C3.5 The `config_loaded` signal event

**Steps**

1. Add the event `config_loaded` to the signal event list and to `subscribe`. It fires after every successful load:
   startup (after the apply and the pin pass) and each reload, manual or automatic. Environment: `YABAI_CONFIG_FILE`,
   `YABAI_CONFIG_CHANGES` (the change count).
2. Signals from the file are already registered when it fires, so a `[[signal]] event = "config_loaded"` entry runs at
   startup.
3. Tests: the event is pushed after reconcile, with its environment; it is not pushed after a failed check. Golden for
   `signal --add event=config_loaded …` if signal records exist there.
4. Docs: asciidoc EVENT list, CHANGELOG.

**Acceptance:** tests pass; the EVENT list and `subscribe` include the event.

**Gate:** quick. **Commit:** `C3.5 Add the config_loaded signal event`.
