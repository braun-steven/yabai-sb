# Phase 1: TOML document model

**Goal:** `YabaiCore` can read a `yabai.toml` into a typed, validated `ConfigDocument`, lower it to the IPC token streams
that `yabai -m` would send, and name the line of any key. Nothing in the daemon changes yet.

**Prerequisites:** none. **Phase gate:** `just ci`.

**Background:**

- The config options are `ConfigCommand.Name` (`Sources/YabaiCore/ConfigCommand.swift`, 61 cases). Their parsing lives in
  `ConfigOption` (`Sources/Yabai/IPC/MessageConfig.swift`): `parse` returns a `Change` closure without applying it.
- Rule keys are documented under "Rule" in `doc/yabai.asciidoc` (`label`, `app[!]`, `title[!]`, `role[!]`,
  `subrole[!]`, `display`, `space`, `manage`, `sticky`, `mouse_follows_focus`, `sub-layer`, `opacity`,
  `native-fullscreen`, `grid`, `scratchpad`, `insert`) and parsed in `Sources/YabaiCore/RuleCommand.swift`. Signal keys
  (`event`, `action`, `label`, `app[!]`, `title[!]`, `active`) are in `SignalCommand.swift`; the events are the EVENT list
  under "Signal".
- `BatchMessage.swift` already turns lines into token groups; `Token` and `Message` are the IPC word types.

| ID | Title | Depends on |
|---|---|---|
| C1.1 | Add the TOMLDecoder dependency | — |
| C1.2 | `ConfigDocument` and strict decoding | C1.1 |
| C1.3 | Lower a document to IPC messages | C1.2 |
| C1.4 | Line numbers for key paths | C1.2 |

---

## C1.1 Add the TOMLDecoder dependency

**Steps**

1. Check the package against the criteria before adding it. Read its `Package.swift` and `Sources/TOMLDecoder` at the
   newest tag (0.4.5 when the plan was written):
   - the `TOMLDecoder` library target is pure Swift (no C, C++ or `unsafeFlags`);
   - it builds with Swift 6.4 in language mode 6 without warnings in this package's settings;
   - `TOMLTable(source:)` exists with typed throws, and `TOMLTable`/`TOMLArray` let a caller list keys and read values
     without `Decodable`;
   - syntax errors carry a line number (`TOMLError`);
   - MIT or Apache-2.0 license.

   If one fails, set C1.1 to `blocked` with the failing criterion; the user picks another package.
2. Add it to `Package.swift` with `exact:` (as swift-collections is pinned) and as a dependency of `YabaiCore` only.
3. Add a one-line smoke test in `tests/YabaiCoreTests` that parses a small table, to prove the link.
4. Record the package, version and reason in `doc/swift-conventions.md` where the other dependencies are listed.
5. Note the release binary size before and after (`ls -l bin/yabai` after `just install`) in the status notes.

**Acceptance:** builds and tests pass with zero warnings in debug and release; `Package.resolved` pins the version.

**Gate:** quick + release. **Commit:** `C1.1 Add the TOMLDecoder dependency`.

---

## C1.2 `ConfigDocument` and strict decoding

**Where:** new `Sources/YabaiCore/ConfigDocument.swift` (types) and `ConfigDocumentDecoding.swift` (TOML → document).

**Steps**

1. Define the document as plain `Equatable, Sendable` value types:
   - `ConfigDocument`: `daemon: DaemonSettings`, `options: [ConfigOptionEntry]` (in file order), `spaces: [SpaceEntry]`,
     `rules: [RuleEntry]`, `signals: [SignalEntry]`;
   - `DaemonSettings`: `autoReload: Bool` (default true), `loadScriptingAddition: Bool` (default false);
   - `ConfigOptionEntry`: `name: ConfigCommand.Name`, `value: ConfigValue`, `keyPath: String`;
   - `ConfigValue`: `.bool`, `.integer`, `.float`, `.string`, `.strings` (for `space_layout`);
   - `SpaceEntry`: `index: Int`, `label: String?`, `pin: String?`, per-space `options: [ConfigOptionEntry]`;
   - `RuleEntry` and `SignalEntry`: their keys in file order as `(key, negated: Bool, value: ConfigValue)`, plus
     `oneShot` for rules.
2. Decode from `TOMLTable` with these rules (the format is in the overview, "Target format"):
   - top-level tables: `daemon`, `config`, `space` (array), `rule` (array), `signal` (array); anything else is an error;
   - `[config]` keys must be `ConfigCommand.Name` raw values; `[[space]]` keys are `index` (required, ≥ 1), `label`,
     `pin`, and the options that accept `--space` (find them by the `selSid` handling in `MessageConfig.swift`; list
     them as a static set in YabaiCore with a comment pointing there);
   - `[[rule]]` and `[[signal]]` keys are their command keys; a negatable key may be `{ not = "<regex>" }`; rules take
     `one_shot = true`; signals require `event` and `action`;
   - type checks only (bool, integer, float, string, array of strings); value ranges and choices are checked later by
     the existing handlers (C2.2), so they are not duplicated here;
   - duplicate `[[space]] index` values are an error.
3. Errors are `ConfigDocumentError(keyPath:, line:, message:)`. Key paths look like `config.window_gap`,
   `rule[3].app`, `space[1].pin` (0-based array indices, as TOML tools print them). `line` is the TOML syntax error's
   line when there is one, else nil (C1.4 fills it). Collect all errors of a document, not only the first.
4. Tests (`tests/YabaiCoreTests/ConfigDocumentTests.swift`): one `@Test(arguments:)` row per error kind (unknown table,
   unknown option, wrong type, `not` on a key that is not negatable, missing signal `action`, duplicate space index);
   a full document like the overview's "Target format" decodes to the expected value; an empty file is the default
   document.

**Acceptance:** every documented key decodes; every error kind has a test with its key path; no daemon code changes.

**Gate:** quick. **Commit:** `C1.2 Decode yabai.toml into a ConfigDocument`.

---

## C1.3 Lower a document to IPC messages

**Where:** new `Sources/YabaiCore/ConfigLowering.swift`.

**Steps**

1. `ConfigDocument.lowered() -> [ConfigEntry]`, where `ConfigEntry` holds `arguments: [String]` (the words after `-m`,
   exactly as `ExtractedCommand.arguments` today), `keyPath`, and a `Kind` (`.option`, `.spaceLayout`, `.space`,
   `.rule`, `.signal`) for the apply order.
2. Order: `[config]` options except `space_layout`, then `space_layout`, then for each `[[space]]`: `space <index>
   --label <label>`, `space <label or index> --pin <pin>`, `config --space <index> <option> <value>`, then each rule
   as `rule --add [--one-shot] key=value …`, then each signal as `signal --add key=value …`.
3. Value words: `true`/`false` → `on`/`off`; integers in decimal, except the color options (`*_color`), which print as
   `0x` + 8 uppercase or lowercase hex digits (match what `config <color>` prints); floats with Swift's shortest
   representation; `.strings` → one word each (`space_layout 15 10:5 10:5:1b`); a negated key → `key!=value`.
4. Exhaustiveness: a test iterates `ConfigCommand.Name.allCases` and lowers a document that sets each one to a valid
   sample value (a table in the test), so a new option without a sample fails the test.
5. Tests: inline snapshots of the lowered words for the "Target format" document; a property test that lowering never
   produces an empty word list and keeps the entry count equal to the document's setting count.

**Acceptance:** the lowered words of the sample document are exactly what the yabairc lines with the same settings
produce through `extractYabaiCommands` (assert that in a test while the extractor still exists).

**Gate:** quick. **Commit:** `C1.3 Lower a ConfigDocument to yabai messages`.

---

## C1.4 Line numbers for key paths

TOMLDecoder reports lines for syntax errors only. Semantic failures (a bad value found by a handler in C2.2) need a
line too.

**Where:** new `Sources/YabaiCore/TOMLKeyLocator.swift`.

**Steps**

1. A small line scanner over the source text that tracks the current table header (`[config]`, `[[rule]]` with its
   running index per array) and records the line of each `key =` (bare and quoted keys, dotted keys, and the keys of a
   one-line inline table). It skips comments and the contents of multi-line strings and arrays. It is a locator, not a
   parser: the file has already parsed.
2. `TOMLKeyLocator(source:).line(for keyPath: String) -> Int?`; for a path whose key is missing (a required key), it
   returns the line of the table header.
3. `ConfigDocumentError` and `ConfigEntry` get their `line` from it.
4. Tests: `@Test(arguments:)` rows for each construct above, including a `#` inside a string and a multi-line array.
   A property test: for generated documents (random option tables and rule arrays rendered to TOML), the locator's line
   for every key is the line the generator put it on. Run it about ten times.

**Acceptance:** every key path of the "Target format" document maps to its line.

**Gate:** quick. **Commit:** `C1.4 Locate the line of a TOML key path`.
