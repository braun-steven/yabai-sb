# Phase 6: YabaiCore simplification

**Goal:** the pure layer reads like Swift. No repeated lookup boilerplate, no copy-paste scanners, no libc varargs
parsing. Layout math is testable without daemon fixtures.

**Prerequisites:** phase 2. **Phase gate:** `make ci`.

The IPC grammar's responses and failures must stay **byte-exact**: the golden replay (`swift test --filter Golden`) is
the referee. Never re-record golden output in this phase. Any golden diff is a bug, except P6.1 step 3, which may only
remove dead code.

| ID | Title | Depends on |
|---|---|---|
| P6.1 | Generic token lookup and dead-code sweep | — |
| P6.2 | Shared key-value scanner for rules and signals | — |
| P6.3 | Swift number and pattern parsing, verified against libc | — |
| P6.4 | Layout math in YabaiCore | — |

---

## P6.1 Generic token lookup and dead-code sweep

**Where:**

- 16 copies of `allCases.first(where: { token.equals($0.rawValue) })` or similar, in `YabaiCore/*Command.swift`,
  `MessageParse.swift`, and elsewhere (`grep -rn "allCases.first(where" Sources`).
- Dead code:
  - the unreachable `.tree` branch in `QueryCommand.swift`, after the early return that already handles `.tree`;
  - the `glass:` parameter of `TabBar.drawTitle`, whose only caller passes `false`, so its glass branches are dead.

**Steps**

1. Add, in `YabaiCore/Message.swift` or a new small file:

   ```swift
   extension CaseIterable where Self: RawRepresentable, RawValue == String {
       init?(token: Token) { … }
   }
   ```

   Match the exact comparison the sites use today (`token.equals(_:)`: case-sensitive? check). If some sites compare
   differently, keep those as they are and note them.
2. Replace the copies. The init must preserve the iteration order of `allCases` when several raw values could match
   (they shouldn't).
3. Remove the dead branches. For `drawTitle`, remove the parameter and the glass-only code paths, and update the one
   caller.

**Acceptance:**

- `grep -rn "allCases.first(where" Sources` is empty, or only the noted exceptions remain.
- The golden replay is unchanged.
- The tab-bar image snapshot is unchanged.

**Gate:** quick. **Commit:** `P6.1 Look up command names through one generic initializer and drop dead branches`.

---

## P6.2 Shared key-value scanner for rules and signals

**Where:** `YabaiCore/Rule.swift` has a rule parser (around the `parseRuleProp` and rule `add` parsing) and
`parseSignal`. Both repeat:

- the `key=value` / `key!=value` loop;
- failure collection;
- `didParse` bookkeeping;
- `unsupportedExclusion` handling;
- regex validation.

**Steps**

1. Pin the behavior first. Make sure that every failure message of both parsers is covered by tests (`RuleTests`,
   `EventSignalTests`, `MessageTests`, golden), and add the missing cases as `@Test(arguments:)` rows.
2. Extract `struct KeyValueScanner`. It yields `(key: Token, value: Token, excluded: Bool)` and reports a malformed
   token the way both parsers do now.
3. Rewrite both parsers on top of it, keeping each one's own key handling.

**Acceptance:**

- Net LOC goes down.
- All rule, signal and golden tests pass unchanged.
- The property tests (`ParserPropertyTests`) pass ten runs in a row.

**Gate:** quick. **Commit:** `P6.2 Parse rule and signal arguments with one key-value scanner`.

---

## P6.3 Swift number and pattern parsing, verified against libc

**Where:** `Token.scan(_:_:)` (`YabaiCore/Message.swift`) wraps `vsscanf`, and `isFloat`-style checks use `strtof`.
Call sites:

- `SpaceCommand.swift` (padding and gap patterns `"%255[^:]:%d:%d:%d:%d"` and `"%255[^:]:%d"`);
- `WindowCommand.swift` (grid; move/resize/ratio `"%255[^:]:%f:%f"`, `"%255[^:]:%f"`);
- `Rule.swift` (grid `"%d:%d:%d:%d:%d:%d"`, opacity `"%f"`);
- `Sources/Yabai/IPC/MessageConfig.swift` (grid; the `"%5[^:]:%d:%d"` pattern);
- `Sources/Yabai/TabBar.swift` (`"%f"`).

`cFormat` (`vsnprintf`) stays where byte-exact output matters; this subphase covers parsing only.

**Steps**

1. Write Swift parsers in YabaiCore, one function per pattern shape. For example:
   - `parseIntegers(_ token:, count:, separator: ":") -> [Int32]?`
   - `parsePrefixed(_ token:, prefixMax: 255, values: Int, as: Float.self)`
   - `parseFloat(_:)`
2. Each must reproduce the sscanf/strtof semantics the call sites rely on today:
   - leading whitespace;
   - partial consumption: sscanf stops at the first non-matching char and still counts earlier conversions;
   - `inf`/`nan`/hex floats from strtof, which later checks reject with `isFinite` (keep the same rejection);
   - 32-bit overflow, which recent commits reject explicitly ("Reject integer tokens beyond 32 bits"; keep that);
   - `%255[^:]` truncation limits.

   Read `git log -5 -p -- Sources/YabaiCore/Message.swift` for the recent edge-case fixes.
3. **Differential tests.** Add property tests (`swift-property-based`) that generate tokens from an alphabet tuned to
   the edge cases (digits, `:`, `-`, `+`, `.`, `e`, whitespace, `inf`, `nan`, `0x`, long runs). For every pattern
   shape, assert that the new parser and the existing `scan`/`strtof` agree on:
   - the count of assigned conversions;
   - the values.

   Run them ten times; record seeds of any failure and fix the parser, never the test oracle.
4. Switch the call sites over, one shape at a time, and run the golden replay after each.
5. Once nothing calls `scan` or `strtof` any more, delete them and their imports, but keep the differential test
   oracle: move it into the test target as a test-only helper.

**Acceptance:**

- `grep -rn "vsscanf\|strtof\|\.scan(" Sources` is empty.
- The differential properties pass ten runs.
- The golden replay is unchanged.

**Gate:** quick. **Commit:** `P6.3 Parse numeric tokens in Swift, proven equal to the libc parsers`.

---

## P6.4 Layout math in YabaiCore

**Where:**

- `Con.cardInset(_:barHeight:barInset:)`, `Con.layOut(_:gap:barHeight:barOffset:barInset:)` and
  `Con.splitGap(_:length:count:)` in `Sources/Yabai/Con.swift`. These are pure `Float`/`Int` math over the tree.
- `TreeView.appendTitle(to:)` builds a `CFMutableString` and reads `WindowManager.shared`.

**Steps**

1. Define a plain value description in YabaiCore: `struct LayoutNode { var layout: ConLayout; var children:
   [LayoutNode]; var ratio: Float; … }`, holding exactly what `layOut` reads, plus a pure `func layOut(_ node:
   LayoutNode, in area: Area, params: LayoutParams) -> [Area]` that returns the areas in pre-order.
2. Have `Con.layOut` build the `LayoutNode` (a mapping step), call the pure function, and assign the resulting areas.
   Measure before and after with the existing performance notes in mind. If the mapping allocates on a hot path (mouse
   drag), keep it allocation-light: reuse arrays, `reserveCapacity`.
3. Move `cardInset` and `splitGap` into YabaiCore as static functions.
4. Title building: build a Swift `String` from a closure that supplies the titles, so `TreeView` passes
   `{ WindowManager.shared.window(for: $0)?.cachedTitle }`. Keep the CF conversion at the edge, where the tab bar needs
   it.
5. Tests in `YabaiCoreTests`: the existing `LayoutTests` scenarios, re-expressed on `LayoutNode`, plus a property
   test: the areas of children tile the parent minus gaps, without overlap. Run the property ten times.

**Acceptance:**

- `LayoutTests` and `ViewInsertionTests` pass unchanged.
- The new YabaiCore tests pass.
- `Con.swift` shrinks.

**Gate:** quick. **Commit:** `P6.4 Move tree layout math into YabaiCore`.
