# IPC protocol v2

The CLI and daemon use the same protocol over `/tmp/yabai_$USER.socket`, mode 0600.
This replaces the unversioned native-endian/NUL protocol. Upgrade clients and daemon together
and restart the daemon; legacy clients are not supported. A version mismatch is an error,
and clients must never automatically retry a command: it may already have executed.
The scripting-addition socket uses its own, unchanged protocol.

## Framing

Every frame has a 12-byte header: ASCII `YBIP`, a big-endian unsigned 32-bit version
(`2`), and a big-endian unsigned 32-bit payload length. The payload is a UTF-8 JSON
object. Lengths exclude the header, must be positive, and are checked before allocation.
Requests have a 1 MiB limit; individual response frames have a 64 MiB limit.
Read the entire header and payload in loops: Unix stream reads do not preserve frame boundaries.

One connection carries one request. The client may half-close its write side after sending it;
the daemon does not wait for EOF to execute. Malformed requests are rejected before execution.

## Requests

Ordinary command:

```json
{"type":"command","arguments":["query","--windows","id,title"]}
```

Batch, with each command represented by its own argument array:

```json
{"type":"batch","commands":[["config","window_gap","6"],["query","--windows"]]}
```

The argument array of a command, and the command list of a batch, must be nonempty.
An empty string is an argument, distinct from the end of the array. Arguments are decoded
as Swift strings, including the existing Unicode comparison and invalid-UTF-8 replacement
behavior of CLI argv. JSON itself must be valid UTF-8. There is no nested batch request.
A command beginning with `batch` or `subscribe` within a batch fails at its own index;
the other commands still run.

Envelope validation precedes execution. Within each command, parsing and selector resolution
remain incremental: earlier operations can change the acting window or space of later ones.
Each batch command refreshes the space caches before running.

## Replies

All replies are framed JSON objects. Command indices are one-based positions in the request
(always 1 for an ordinary command). A command can produce several outputs or errors.

| Type | Fields | Meaning |
| --- | --- | --- |
| `output` | `command`, `format`, `data` | `format` is `text` (string data) or `json` (nested JSON data). |
| `error` | `command` when known, `message` | A command or request failed; the message includes its existing newline. |
| `complete` | `ok` | Ends an ordinary request; false if any command or response encoding failed. |
| `subscribed` | `events` | Acknowledges a subscription instead of completing the request. |
| `event` | `data` | The existing event object, with string values. |

For example, a query produces:

```json
{"command":1,"data":[{"id":42,"title":"Document"}],"format":"json","type":"output"}
{"ok":true,"type":"complete"}
```

These are separate length-prefixed frames, not newline-delimited wire messages.
A successful command with no output produces only `complete`. Intentional empty query
results retain that behavior; there is no synthetic null result.

The CLI renders JSON data as compact JSON with sorted keys and a trailing newline.
Text is written verbatim. Successful output always goes to stdout; errors always go to stderr.
Batch errors prefix each line with its command index. Any error produces exit status 1.
Transport EOF before `complete` is a failure, even if some output has arrived.

Query data retains existing object/array shapes, signed ID representations, and
`"nan"`/`"inf"`/`"-inf"` handling. Clients must preserve 64-bit integers when decoding.
Extra query arguments are errors, including arguments after `--tree`.

## Subscriptions and resource ownership

`["subscribe","window_focused"]` acknowledges with
`{"type":"subscribed","events":["window_focused"]}`, followed by `event` frames.
The CLI continues rendering its familiar acknowledgement and event JSON lines.
After acknowledgement, EOF ends the subscription successfully; before it, EOF requires
an ordinary `complete` frame. An invalid subscription produces an error and failed completion.

The socket reader transfers its owned connection to the event loop, then to either the
response queue or the subscriber queue. No socket write runs on `@WM`. Pending writes
retain their connection, preventing descriptor reuse while a write is outstanding.
Shutdown wakes a stalled subscriber writer, and descriptor closure follows its last reference.

Daemon request reads and ordinary frame writes have 1-second absolute deadlines.
Subscriber writes have 5-second deadlines and a 1 MiB backlog limit, counting framed bytes.
Client connect/write/read deadlines default to 30 seconds (`YABAI_CLIENT_TIMEOUT` overrides);
acknowledged subscription reads have no deadline. A deadline spans partial transfers
and interrupted system calls, so trickling bytes cannot extend it indefinitely.
