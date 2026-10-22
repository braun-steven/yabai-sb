# Phase 10: IPC features

**Goal:** scripts can send many commands in one round trip, and status bars can follow events without a process per
event.

**Prerequisites:** phase 2 (P2.5 client timeout and length cap) and phase 9 (P9.4 tokenizer). **Phase gate:** `make ci`,
plus `swift test --sanitize=thread` and `--sanitize=address`.

**Background:**

- A message is a native-endian `Int32` length followed by null-separated tokens (`ClientMessage.encode`,
  `YabaiCore/Client.swift`).
- Responses are written on the `yabai.ipc` serial queue (`MessageLoop.send`), and the socket is closed afterwards.
- `runCommands` runs the commands of one message for the config, space and window domains.
- Signals: `EventSignals.push` records pending signals only when the type has subscribers, and `flush` spawns `env …
  sh -c <command>` per subscriber (`Sources/Yabai/EventSignal.swift`).

Every new command needs:

- handler parsing;
- `doc/yabai.asciidoc` + `make man`;
- a CHANGELOG entry;
- a README "Fork changes" entry.

| ID | Title | Depends on |
|---|---|---|
| P10.1 | Batch message encoding | — |
| P10.2 | `yabai -m batch` | P10.1 |
| P10.3 | Subscriber registry and event encoding | — |
| P10.4 | `yabai -m subscribe` | P10.3 |

---

## P10.1 Batch message encoding

**Steps**

1. In YabaiCore, add `BatchMessage.encode(_ commands: [[String]]) -> [[UInt8]]` and `BatchMessage.decode(...)`.
   - The batch is sent as the domain token `batch` followed by count-prefixed groups: `batch <n1> <arg>… <n2> <arg>…`,
     where each `n` is a decimal token. That is unambiguous even with empty arguments.
   - `decode` takes the token stream after `batch` and returns `[[Token]]`, or a failure for:
     - a malformed count;
     - a count beyond the remaining tokens;
     - an empty batch.
2. Tests:
   - round-trip property test (ten runs);
   - malformed inputs as `@Test(arguments:)` rows.

**Gate:** quick. **Commit:** `P10.1 Encode several messages as one batch message`.

---

## P10.2 `yabai -m batch`

**Steps**

1. **Client** (`IPC/Client.swift`): `yabai -m batch` with no further arguments reads stdin.
   - Split it into lines with the P9.4 tokenizer (same quoting rules; `#` comments and blank lines are ignored).
   - Each line holds the arguments after `-m`, for example `window --focus east`.
   - A leading `yabai -m` on a line is accepted and stripped.
   - Lines that the tokenizer reports as dynamic shell are a client-side error naming the line; nothing is sent.
   - Encode with P10.1, send as one message, and print the response.
2. **Daemon** (`IPC/MessageLoop.swift`):
   - Decode the batch, and run each command through the same path as a standalone message, inside one `@WM` handler
     invocation.
   - Prefix every failure line of command *i* with `<i>: `, where *i* is 1-based and the line number in stdin.
   - Flush changed views once at the end: find how a single message flushes today (`flushDirtyViews` or the view
     flush in the handlers) and make sure a batch doesn't flush per command, if that is cleanly possible. If it isn't,
     keep the per-command flush and note it.
   - The response fails if any command failed.
   - Output (queries) is concatenated in order.
3. Golden: add batches whose commands fail before acting (e.g. two invalid config values) to `commands.txt`, record
   with `GOLDEN_RECORD=1`, and review.
4. Docs: asciidoc (a new "BATCH" subsection under `-m`), `make man`, CHANGELOG, README "Fork changes" (with P10.4 as one
   entry, "IPC batch and subscribe"). In `examples/yabairc`, show converting a block of `config` lines into one
   heredoc `yabai -m batch <<'EOF' … EOF`.

**Acceptance:** golden passes after review, a test covers prefixing and failure status, and the sanitizers pass.

**Live check:** time 30 `config` commands as separate calls versus one batch (`time`); the batch is much faster.
`yabai -m batch` with a heredoc of window commands applies them all.

**Gate:** quick + sanitizers. **Commit:** `P10.2 Run several commands in one message with yabai -m batch`.

---

## P10.3 Subscriber registry and event encoding

**Steps**

1. **Event encoding (YabaiCore).** Write `func eventJSONLine(type: String, arguments: [(name: String, value: String)])
   -> [UInt8]`.
   - It produces one line of JSON: `{"event":"window_focused","window_id":"…",…}` followed by `\n`.
   - Map each `YABAI_*` name to a key: lowercase, without the prefix (`YABAI_WINDOW_ID` → `window_id`).
   - Numbers stay strings, exactly like the environment values, to avoid lossy guessing.
   - Use the existing `JSON.swift` encoder with sorted keys, after P2.6.
   - Golden-test a few lines.
2. **Registry (Yabai).** Write `@WM final class EventSubscribers` holding `[Subscriber]`, where each `Subscriber` has:
   - the fd;
   - the subscribed `Set<SignalType>`, empty meaning all;
   - a private serial `DispatchQueue` for writes;
   - an atomic backlog byte count.

   It provides:
   - `add(fd:types:)`;
   - `publish(type:arguments:)`. It encodes once, then for each matching subscriber adds the size to the backlog and
     `async`-writes on the subscriber's queue. On a write error, or when the backlog exceeds 1 MiB, it closes the fd
     and removes the subscriber on `@WM` through `EventLoop.post`. Writes never block `@WM`.
3. **Hook into signals.** `EventSignals.push` must record a pending signal when the type has signal subscribers **or**
   event subscribers. In `flush`, call `EventSubscribers.shared.publish` for each pending signal, in addition to the
   spawns.
4. Tests:
   - publish to a `socketpair` and read the line back;
   - a subscriber that doesn't read is dropped after the backlog limit, with the limit made injectable for the test;
   - a closed peer is removed;
   - run under TSan and ASan.

**Gate:** quick + sanitizers. **Commit:** `P10.3 Publish events as JSON lines to registered subscribers`.

---

## P10.4 `yabai -m subscribe`

**Steps**

1. **Daemon.** The new domain `subscribe [<event>…]` takes event names as in `signal --add event=…`; unknown names fail
   with the list of valid names (P9.1 style).
   - On success, don't close the socket. Hand the fd to `EventSubscribers.add`.
   - Write a first line: `{"subscribed":["window_focused",…]}`.
   - The normal response path must not close this fd. Add an explicit "keep open" outcome to the message handling,
     instead of special-casing the domain inside `send`.
2. **Client.** For `subscribe`:
   - disable the P2.5 receive timeout;
   - copy each line to stdout as it arrives, flushing per line;
   - exit 0 when the daemon closes the socket, and 1 if the first line is a failure.
3. Docs:
   - asciidoc (domain `subscribe`, the JSON line format, the backlog drop rule);
   - `make man`;
   - CHANGELOG;
   - README (the entry shared with P10.2);
   - an `examples/` snippet piping into a SketchyBar script (`yabai -m subscribe space_changed | while read -r line;
     do sketchybar --trigger …; done`).
4. Golden: `subscribe not_an_event` (failure only).

**Acceptance:** an end-to-end test drives a fake client through `socketpair`, receives the `subscribed` line, then an
event line after a `push` + `flush` in a `DaemonState` test. The sanitizers pass.

**Live check:**
- `yabai -m subscribe window_focused space_changed` prints a line for each focus and space change;
- `Ctrl-C` on the client doesn't disturb yabai;
- a client suspended with `Ctrl-Z` gets dropped after heavy activity, and yabai stays responsive.

**Gate:** quick + sanitizers. **Commit:** `P10.4 Stream events to clients with yabai -m subscribe`.
