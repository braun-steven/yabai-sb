# Testing and debugging yabai live

Notes for agents verifying changes on the user's machine. They cover the unit tests, the live
harness, deploying test builds, the scripting addition (SA), sanitizers and crash analysis. Every
point below was learned the hard way; read it before running anything live.

## Unit tests

- `make -C tests` builds `src/manifest.m` with `-DTESTS` (plus the Swift code of `Sources/Yabai/` but
  `main.swift`) and runs every entry of `TEST_LIST` in `tests/src/tests.m`, under ASan/UBSan, then the golden
  IPC replay (`tests/src/golden.c`). The test build is warning-free; any warning is new. Check with
  `make -C tests 2>&1 | grep -c "warning:"`. `make test` runs `swift test` first.
- The golden replay runs on a daemon state without displays, spaces or windows, but in this process: a command
  in `tests/YabaiCoreTests/Golden/commands.txt` that acts on a display, space or window would act on the user's
  real one. Only add commands that fail before they act, or that only change the daemon's own state.
- `TEST_FUNC(name, { ... })` is a macro: a comma at the top level of a brace initializer
  (`struct x a = { 1, 2 };`, `uint32_t e[] = {1, 2}`) splits the macro arguments and the build fails
  with "too many arguments provided to function-like macro invocation". Build fixtures in a static
  helper function instead (see `known_focus_psn` in `tests/src/window_frame.c`).
- `ts_buf_*` lists live in per-event temporary storage (`ts_init` in `tests.m`); there is no
  `ts_buf_free`. Reset a list with `list = NULL`.
- Everything shares one translation unit, so `static` functions of any source file can be called from
  a test. Make decisions testable by moving them into pure `static inline` helpers that take their
  inputs as arguments (e.g. `space_manager_can_use_known_focus`, `application_launch_retry_delay`,
  `tree_collect_window_order`), and keep the side effects in the caller.
- Tree tests build containers with `con_create`, `tree_test_leaf` and `tree_test_split`
  (`tests/src/tree.c`) and set focus with `tree_focus`. In tests a tab bar has no glass panel, so
  `tab_bar_card_id` returns 0; `tree_con_is_visible` works.

## The live harness

It lives in `scripts/live-tests/`. Run it from that directory:

| File | Purpose |
|---|---|
| `live.py setup` | records the focused window, then opens TextEdit (3 documents), Script Editor (2) and Calculator on space 4 |
| `live.py run <label>` | 28 checks: relayout, tabs (incl. front-to-back order), rapid focus, cross-display send, focus follows mouse, alt-drag, stalled client, frozen app, animations, native fullscreen |
| `live.py extra <label>` | 50 SA space switches (Dock pid, footprint), space focus with a frozen front app, tabbed container warped to display 2 and back, swap across displays |
| `live.py launch <label>` | launch-retry backoff for an app frozen right after launch; needs every test app closed |
| `live.py cleanup` | quits the test apps, resets config, shows space 11 on display 2, focuses the window recorded by `setup` |
| `bench.py <label>` | medians for tab focus, rotate, split focus |
| `bounds`, `mouse`, `freeze` | Swift helpers; `live.py` compiles them when missing or outdated (ignored by git) |
| `deploy.sh [install\|asan\|tsan\|restore]` | builds, signs, installs and restarts a test build; `restore` puts the previous binary back (see below) |
| `sa_version.py` | prints the version and attribute bits of the payload loaded in Dock |
| `crashes.py [n]` | summarizes the newest yabai crash reports |

Rules for the user's machine:

- Two 2560×1440 displays. Display 1 has spaces 1–10, display 2 has 11–15. Spaces 1–3, 9–11 and 15
  hold the user's windows: use only 4–8 and 12–14. The harness uses 4, 5 and 12.
- Before `setup`, check `pgrep -lx TextEdit`, `"Script Editor"`, `Calculator`; if one runs, ask the
  user. `setup` records the focused window in `.focused-window` and `cleanup` focuses it again;
  `launch` needs the test apps closed, so it runs after a `cleanup`.
- Every deploy restarts yabai, and a restart loses the trees: all spaces, including the user's, come
  back as a flat splith row (tabbed containers are gone). Rebuild a test layout after each deploy,
  and tell the user that their layouts were reset.
- The native ctrl+←/→ space shortcuts are disabled (symbolic hotkeys 79/81), so the harness skips
  that check. Don't change the user's settings.
- A frozen application blocks every accessibility call to it for about 1 s (the AX timeout).
  `kill -STOP` right after `open` only parks the app on yabai's `finishedLaunching` observation, so no
  retries happen; `freeze com.apple.TextEdit` stops it from a KVO callback the moment it has
  finished launching, which exercises the `kAXErrorCannotComplete` retry path. Always `kill -CONT` in a
  `finally`.
- The tree follows i3: a splith container inside a splith container is not flattened. After
  `--layout splith` on a nested tabbed container the tree stays nested, and later checks that expect a
  flat row (and tab-order checks) fail for the wrong reason. `flatten_row()` warps every window next
  to a window at the root. `window <a> --stack <b>` builds a tabbed container; `window --focus parent`
  then `window --warp east` moves the whole container to the display on the right.
- Debug output (`yabai -m config debug_output on`) goes to stdout, i.e.
  `/tmp/yabai_$USER.out.log`, not the error log. It is flushed when the daemon logs the next message,
  so send a `yabai -m query ...` before reading it. Turn it off again afterwards.
- To check that signal commands run, add a labeled temporary signal and remove it:
  `yabai -m signal --add label=claude_test event=space_changed action="echo \$YABAI_SPACE_INDEX >> <file>"`,
  then `yabai -m signal --remove claude_test`.

Always run a baseline on the installed binary before changing anything, so before/after numbers
come from the same session. Reference numbers from the `fix-left-out-findings` session (release builds):

| Measure | master build | branch |
|---|---|---|
| `run` checks | 26/27 | 28/28 |
| bench tab focus / rotate / split focus (median) | 45 / 136 / 40 ms | 36 / 74–79 / 33 ms |
| space focus with a frozen front app | 2020 ms | 13 ms |
| query during launch retries of a frozen app (median) | 6.9 s (forever) | 12 ms, gives up after 12 attempts |
| query while another client stalls | 3.8 s | 0.8 s |

## Deploying a test build

- Agents deploy test builds themselves with `bash scripts/live-tests/deploy.sh install` (or `asan`,
  `tsan`). The user allowed exactly that command (`Bash(bash scripts/live-tests/deploy.sh:*)` in the
  git-ignored `.claude/settings.local.json`). The auto-mode classifier blocks every other way of
  replacing `~/.local/bin/yabai`; don't work around it. Run the script by this exact command: from the
  repository root, without `cd` or other commands chained in front of it.
- The first deploy backs up the installed binary to `~/.local/state/yabai/yabai.before-deploy`; later
  deploys keep that backup. When you are done testing, run `bash scripts/live-tests/deploy.sh restore`,
  which puts the backup back, checks it with `cmp` and deletes it. Never leave a test build installed,
  unless the user takes over (e.g. the long-lived `swift-port` branch, see `doc/swift-port.md`). The user
  deploys a branch for good with `update-yabai-fork` in a real terminal (it needs `sudo`).
- Tell the user after each deploy: it restarts yabai and resets their layouts (see above).
- `deploy.sh` signs with the `yabai-cert` identity (`3A6E8695…`), so the Accessibility permission is
  kept. Check with `codesign -d -r- ~/.local/bin/yabai`.
- Expected noise in `/tmp/yabai_$USER.err.log` while a test build is installed:
  `sudo: a terminal is required…` (the sudoers rule for `--load-sa` is pinned to the hash of the binary
  that `update-yabai-fork` installed) and `yabairc: line 164: 0xff285577: command not found`.
- `pgrep -x yabai` can briefly list two pids: the second is a `yabai -m` client from the yabairc.

## Scripting addition

- A test build cannot load its payload by itself (sudoers, see above), so Dock keeps the old payload.
  That is the moment to test how a new daemon behaves with an old payload, which ignores unknown
  opcodes. Do it before reloading.
- Reloading takes the user two runs of `! sudo ~/.local/bin/yabai --load-sa` (full path; `sudo`'s PATH
  may not include `~/.local/bin`). The first run installs the new payload files and restarts Dock. The
  `dock_did_restart` signal in the yabairc would inject the payload into the new Dock, but its
  `sudo` fails, so Dock has no payload at all until the second run injects it.
- Verify with `python3 scripts/live-tests/sa_version.py`. On macOS 27 (arm64) the
  attributes are `0x5f`: everything in `OSAX_ATTRIB_ALL`, but not `SET_WINDOW`. The Dock function behind
  `SA_OPCODE_WINDOW_FOCUS` is not found, and its only caller in `window_manager.c` is disabled
  (`#if 1`), so that opcode cannot be tested live.
- After the reload Dock is fresh: its footprint grows for the first few hundred operations. To look for a
  leak, measure `vmmap -summary $(pgrep -x Dock) | grep "Physical footprint"` over several rounds and
  compare the later ones (52.2 → 52.9 → 52.9 → 53.0 MB over 600 space switches).
- To find out how Dock's runtime handles one of its ivars without injecting code, read its class
  metadata: `otool -arch arm64e -ov /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock` (the
  binary has no plain `arm64` slice). `0x100000000 __mh_execute_header` in that output is a NULL pointer
  plus the image base. `flags 0x80` is `RO_IS_ARC`. An ivar of an ARC class with no strong or weak ivar
  layout (Swift classes, e.g. `DockCore.DisplaySpaces`) is "unretained" for `object_setInstanceVariable`,
  which then only stores the pointer, although Swift owns a reference in the field. The payload therefore
  writes `_currentSpace` itself and retains the new value and releases the old one (`set_current_space`).
- The payload is built without ARC (`#error` guard at the top of `payload.m`). Its socket thread has an
  `@autoreleasepool` per message; never `release` literals or other autoreleased objects.

## Sanitizers

- Confirm the runtime is loaded: `vmmap $(pgrep -x yabai) | grep -m1 -o "libclang_rt[^ ]*"`.
- Before a run, note the size of the error log (`wc -c < /tmp/yabai_$USER.err.log`) and afterwards scan
  only the new part: `tail -c +<size+1> /tmp/yabai_$USER.err.log | grep -E "Sanitizer|runtime error|SUMMARY"`.
- Look at the pid in each report (`==12345==` or `pid=12345`). Reports from pids other than the daemon's
  come from processes it forked, e.g. the process that runs signal commands.
- Known TSan noise: two "data races" in `event_handlers.c` (the first `debug` line of `APPLICATION_LAUNCHED`
  reading `process->name`/`pid` written by `process_create`). The process is handed over through the
  event queue, which TSan does not model; treat them as false positives.
- Fixed on `fix-left-out-findings`: the forked signal process called `exit()`, which ran CoreSpotlight's
  PowerLog finalizers in a fork of a multithreaded process and crashed (`_os_log_find` /
  `_dispatch_mgr_queue_push` under `exit` < `event_signal_flush`). It now uses `_exit()`. Any child
  of a fork must leave with `_exit()`.

## Crash reports

- macOS writes `~/Library/Logs/DiagnosticReports/yabai-<date>.ips` for every crashed yabai process,
  including forked children and sanitizer aborts. Count them before and after a run and summarize new
  ones with `scripts/live-tests/crashes.py`. An `.ips` file is a JSON header line followed by a JSON body; the crashed
  thread has `"triggered": true`.
- Reports from release builds with the same stack as a sanitizer report show that a bug is not caused by
  the sanitizer, and their dates show whether it predates the branch.
