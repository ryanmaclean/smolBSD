# OPERATOR-OBSERVATION.md
# smolBSD Coordinator — First End-to-End Observation
# Date: 2026-05-16  Observer: automated (Claude Code agent)
# DO NOT COMMIT — contains test observations, may be superseded

---

## ENVIRONMENT

| Item | Value |
|---|---|
| Host | macOS 25.3.0, Apple Silicon |
| Working dir | `/Users/studio/smolBSD` |
| Test tmpdir | `/tmp/smolbsd-obs-VzEYu` |
| Nushell | `0.111.0` at `/opt/homebrew/bin/nu` |
| `claude` CLI | `2.1.140` at `/Users/studio/.local/bin/claude` |
| `claude` auth status | **NOT LOGGED IN** (`Not logged in · Please run /login`) |
| `ANTHROPIC_API_KEY` | **not set** |
| qcow2 artifact | `/Users/studio/smolBSD/build/FreeBSD-15-aarch64-smolbsd.qcow2` — **exists** (1.4 GiB) |
| Live spool | `/Users/studio/smolBSD/var/mail/spool` — NOT touched |
| Test spool | `/tmp/smolbsd-obs-VzEYu/var/mail/spool` — fresh empty file |
| Test state file | `/tmp/smolbsd-obs-VzEYu/var/run/coord-state.toml` — created by coordinator |

`nu` and `claude` are both on PATH for `sh` subprocesses. The coordinator's `spawn-subagent` function (line 199) uses `which claude` to detect the CLI — it finds it. The authentication failure is invisible at detection time; the error only surfaces in the spawned process log.

---

## HAPPY PATH ATTEMPT

**Command used:**
```sh
# Step 1: submit a task
nu bin/coord-submit.nu \
  --task-id "task-0001" \
  --role "general-purpose" \
  --subject "Echo test" \
  --body '...' \
  --spool /tmp/smolbsd-obs-VzEYu/var/mail/spool

# Step 2: run a tick (repeated manually)
nu bin/coord-tick.nu \
  --root /tmp/smolbsd-obs-VzEYu \
  --spool var/mail/spool \
  --state-file var/run/coord-state.toml \
  --max-ticks 10
```

**Expected outcome:** FSM transitions idle → harvesting → dispatching → waiting → harvesting → idle, with a subagent producing a `verdict=pass` reply.

**Actual outcome:** FSM transitions correctly through all states up to `waiting`. Subagent is spawned (file written, process launched). Subagent exits immediately with `Not logged in · Please run /login`. No reply appears in the spool. FSM stays in `waiting` indefinitely. After manual injection of a synthetic reply, the full happy path (waiting → harvesting → idle) completes without issue.

---

## TIMELINE

### Tick 1 — Empty spool (event: `coord_tick_start`, `state_init`, `tick_enter`, `idle_no_new_messages`, `coord_tick_done`)

- State file absent → `state_init` event, default state loaded.
- FSM enters `idle`, scans spool (0 messages), emits `idle_no_new_messages`.
- Exits cleanly with `fsm_state = idle`, `tick_count = 1`, `seen_ids = 0`.
- **Outcome: PASS.** Empty-spool idle cycle is correct.

### Tick 2 — Task submitted, subagent spawned (events: `idle_new_messages_found`, `harvest_message`, `would_dispatch`, `dispatch_sent`, `subagent_spawned`, `waiting_no_reply`, `coord_tick_done`)

- `coord-submit.nu` wrote a valid mbox+TOML envelope to the spool (1 message, `Message-ID: <task-0001.coord@smolbsd.local>`).
- FSM: `idle` → `harvesting` (tick 3) → `dispatching` (tick 4) → `waiting` (tick 5).
- At `harvesting` (tick 3): `harvest_message` direction=`request`, `would_dispatch` fired.
- At `dispatching` (tick 4): coordinator appended a second mbox message (`<coord.4.r1.20260516132636@smolbsd.local>`) with `action = "dispatch"`. `dispatch_sent` logged.
- `spawn-subagent` called: `claude` found via `which claude`, prompt written to `/tmp/smolbsd-obs-VzEYu/var/run/spawned/task-0001.prompt.txt`, process launched as detached `sh -c ... &`. Event `subagent_spawned` logged with `prompt_file` and `log_file` paths.
- FSM transitioned to `waiting`, emitted `waiting_no_reply` (reply not yet present — correct, subagent is async).
- Tick ended with `fsm_state = waiting`, `seen_ids = 1`.

**Subagent log (`task-0001.log`, 1 line):**
```
Not logged in · Please run /login
```
The `claude --bare` flag requires either an OAuth session or `ANTHROPIC_API_KEY`. Neither is present. The subagent process exited without writing any reply to the spool.

### Tick 3 — Still waiting, no reply (event: `waiting_no_reply`)

- FSM loaded from disk as `waiting`. Scanned spool for `In-Reply-To: <coord.4.r1.20260516132636@smolbsd.local>` — none found.
- `waiting_no_reply` emitted. State unchanged. **300s timeout not yet elapsed.**
- `fsm_state = waiting`, `tick_count = 6`.

### Tick 4 (synthetic) — Injected reply, harvesting, idle (events: `waiting_reply_received`, `harvest_message` x2, `harvest_reply_pass`, `coord_tick_done`)

- A synthetic reply was hand-crafted with `In-Reply-To: <coord.4.r1.20260516132636@smolbsd.local>`, `verdict = pass`, and a `[[claims]]` block. Appended directly to spool.
- FSM: `waiting` → `harvesting` (tick 8). `waiting_reply_received` fired.
- `harvest_message` processed both the coordinator dispatch envelope and the reply.
- `harvest_reply_pass` fired for `<task-0001.reply.1@smolbsd.local>`.
- FSM returned to `idle`. `tick_count = 8`, `seen_ids = 3`, `attempt_counts = {}` (cleared on pass).
- **Outcome: PASS.** The full harvest path including `[[claims]]` verification works correctly when a valid reply is present.

### HALT test — Sentinel file detection (events: `halted`, `coord_tick_done`)

- `touch /tmp/smolbsd-obs-VzEYu/var/mail/HALT`.
- Tick ran: `halted` event emitted immediately (before `tick_enter`), FSM state saved as `halted`.
- **Outcome: PASS.** Global HALT sentinel is detected correctly in O(1).

### HALT resume — Bug observed (events: `tick_enter fsm_state=halted`, `halted` again)

- `rm /tmp/smolbsd-obs-VzEYu/var/mail/HALT`.
- Next tick: FSM loaded from disk as `halted`. `tick()` called → `process-resume-actions` found no resume message → `halt-present` check at line 694 **passed** (file absent) → `tick_count` incremented, `tick_enter` logged with `fsm_state = halted` → `match` dispatched to `state-halted` (line 710) → `state-halted` logged `halted` event again and returned `halted`.
- **FSM is STUCK.** Removing the HALT file alone is not sufficient to exit the `halted` state. The coordinator spec (§13) says "append a resume mbox message … then `rm var/mail/HALT`". Without the resume message, the FSM remains `halted` even after the file is removed.
- This is correct per spec but is an **operator surprise** because `coord-run.sh` and the README both imply `rm var/mail/HALT` alone resumes normal operation (README: "Remove `var/mail/HALT` to resume normal operation").

---

## BLOCKERS (ranked by severity)

### BLOCKER 1 — `claude` CLI not authenticated (FATAL for autonomous operation)

**Severity: Critical.** The `spawn-subagent` function (line 199, `coord-tick.nu`) detects `claude` on PATH via `which claude` and calls it with `--bare`. `--bare` mode requires either an OAuth session (keychain) or `ANTHROPIC_API_KEY`. Neither is present. Every spawned subagent exits immediately with `Not logged in · Please run /login`. No reply ever appears in the spool. The FSM stays in `waiting` until the 300s timeout fires, then synthesizes a `fail` verdict, enters D2 retry, and after 3 attempts halts the task.

**Fix required:** Either `claude auth login` in the interactive session before running `coord-run.sh`, or set `ANTHROPIC_API_KEY` in the environment. The coordinator has no check for this condition and produces no warning; the failure is silent except in the spawned process log file.

### BLOCKER 2 — `coord-run.sh` does not pass `--root` to `nu bin/coord-tick.nu`

**Severity: High.** `coord-run.sh` calls `nu "${ROOT}/bin/coord-tick.nu"` (line 59) without forwarding `--root`, `--state-file`, or `--spool` flags. `coord-tick.nu` defaults to `--root "."` and resolves all paths relative to cwd. If `coord-run.sh` is invoked from any directory other than the repo root, it will create `var/` directories in the wrong location. The `ROOT` env var is exported but never forwarded to the nu process as a `--root` argument. Only the env var path (`nu "${ROOT}/bin/coord-tick.nu"`) passes `ROOT`, not the tick's internal path resolution.

**Fix:** `coord-run.sh` line 59 should be: `nu "${ROOT}/bin/coord-tick.nu" --root "${ROOT}" --state-file "${STATE_FILE}" --spool "${SPOOL}"`.

### BLOCKER 3 — `halted` FSM state requires a resume message; `rm HALT` alone is insufficient

**Severity: Medium.** The README states "Remove `var/mail/HALT` to resume normal operation." This is incomplete. Once `coord-state.toml` persists `fsm_state = halted`, removing the HALT file does not restore the coordinator to `idle`. The operator must also append an mbox resume message with `X-Resume-Action: retry` and `X-Resume-Tag: resume-<task_id>`. Without this, `state-halted` (line 658) finds no resume actions, returns `halted`, and the loop spins forever in the halted state on each tick.

**Fix:** Update README and `coord-run.sh` comments. Consider adding an auto-recovery path: if `fsm_state = halted` and no `var/mail/HALT` file and no `halted_tasks`, transition to `idle` directly.

### BLOCKER 4 — Dispatcher envelope is minimal; subagent has no task context

**Severity: Medium.** The `state-dispatching` function (lines 619–629) writes a coordinator dispatch envelope containing only `task_id` and `action = "dispatch"`. The subagent prompt (line 214) instructs the spawned agent to find the original task message by scanning for `<task-0001.` in the spool. In practice the spool may contain many messages; the scan works, but the original task message body (with `command`, `brief`, `acceptance`) is in the user-submitted message, not the coordinator dispatch. The subagent must therefore parse two separate messages. No error occurs, but this is a fragile design that will break if the spool is compacted or the original message is no longer present.

### BLOCKER 5 — `coord-submit.nu --tick` passes `--spool` but not `--root` to tick

**Severity: Low.** The `--tick` mode of `coord-submit.nu` (line 241) calls `nu --no-config-file $tick_path --spool $spool --max-ticks 10`. It does not forward `--root` or `--state-file`. If the spool is in a non-default location (e.g., the tmpdir used in this test), the state file will be written to `./var/run/coord-state.toml` in whatever the current working directory is, which may differ from the spool's directory.

---

## WHAT WOULD MAKE THIS WORK (ranked by minimum-viable)

1. **Authenticate the `claude` CLI.** Run `claude auth login` (OAuth) or export `ANTHROPIC_API_KEY`. This alone enables autonomous subagent execution. No code changes required. Estimated effort: 2 minutes.

2. **Fix `coord-run.sh` to forward `--root`/`--spool`/`--state-file`.** One-line change to line 59. Without this, running `coord-run.sh` from a non-root working directory silently creates state in the wrong location.

3. **Add a pre-flight auth check in `spawn-subagent`.** Before calling `claude`, verify auth: `claude --print --bare --max-turns 0 ""` or check `ANTHROPIC_API_KEY` is set. If neither, emit `subagent_spawn_skipped` with `reason: "claude CLI not authenticated"` instead of silently spawning a process that exits immediately.

4. **Clarify the HALT resume protocol in operator docs.** The README sentence "Remove `var/mail/HALT` to resume normal operation" needs to add "and append a resume mbox message to the spool."

5. **Add a `coord-submit.nu` convenience for resume actions.** Currently there is no tooling to construct the resume mbox message; operators must hand-write one. A `--resume <task_id>` flag on `coord-submit.nu` would fill this gap.
