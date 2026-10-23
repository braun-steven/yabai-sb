# Phase 6: Editor and tooling support

**Goal:** editors complete and check `yabai.toml` through a JSON Schema that cannot drift from the code, and the running
config can be printed as TOML.

**Prerequisites:** phase 5. **Phase gate:** `just ci`.

| ID | Title | Depends on |
|---|---|---|
| C6.1 | JSON Schema for `yabai.toml` | — |
| C6.2 | `config --dump` prints the running config as TOML | — |

---

## C6.1 JSON Schema for `yabai.toml`

**Steps**

1. Write `doc/yabai.schema.json` (JSON Schema draft 2020-12, as Taplo / Even Better TOML read it): the tables, every
   `[config]` option with its type, its choices as `enum` where the option is a choice, ranges where the handler has one,
   a `description` taken from the man page's first sentence, and `additionalProperties: false`. Rules, signals and
   spaces likewise; `{ not = … }` for negatable keys.
2. A test (`tests/YabaiCoreTests/ConfigSchemaTests.swift`) loads the schema and checks that its `[config]` properties are
   exactly `ConfigCommand.Name.allCases`, the `[[space]]` options are exactly the per-space set (C1.2), and the rule and
   signal keys are exactly the decoder's. A second check: every choice option's `enum` equals the choice type's raw
   values.
3. `examples/yabai.toml` starts with `#:schema https://raw.githubusercontent.com/<fork>/main/doc/yabai.schema.json` or a
   relative path; pick the form Taplo resolves for a file in `~/.config/yabai`, and document it in the man page.
4. CHANGELOG.

**Acceptance:** the schema test fails when an option is added without a schema entry (check this by adding one
temporarily, then removing it).

**Gate:** quick. **Commit:** `C6.1 Add a JSON Schema for yabai.toml`.

---

## C6.2 `config --dump` prints the running config as TOML

**Steps**

1. `config --dump` prints the running state as a `yabai.toml`: `[daemon]`, every `[config]` option with its running value
   (a comment `# default` on values equal to the default, `# override` on overridden ones), `[[space]]` entries for
   labels, pins and per-space values, rules and signals.
2. A renderer in YabaiCore (`ConfigDocument.toml()`), used by the dump. Round trip: a property test that `decode(toml(d))
   == d` for generated documents. Run it about ten times.
3. A `DaemonState` test: the dump of a loaded fixture checks clean and reconciles to `0 changes`.
4. Golden: add `config --dump` if its output is stable in the golden environment; otherwise explain in the notes.
5. Docs: asciidoc (`just man`), CHANGELOG.

**Acceptance:** round trip and reconcile tests pass.

**Gate:** quick. **Commit:** `C6.2 Print the running config as TOML with config --dump`.
