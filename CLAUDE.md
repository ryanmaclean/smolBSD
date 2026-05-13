# smolBSD Coordinator — Claude Code Context

## 1. What this is

**smolBSD coordinator** is a Nushell mbox+TOML multi-agent finite-state machine (FSM) for building and maintaining a minimal FreeBSD VM. The coordinator manages a set of agents that collaborate via a mailbox spool, advancing through FSM states (idle → dispatching → waiting → harvesting → halted) on each tick.

## 2. Key files

| Path | Purpose |
|---|---|
| `bin/coord-tick.nu` | One FSM tick — advances state through idle/dispatching/waiting/harvesting/halted |
| `bin/mbox-parse.nu` | mbox+TOML parser — reads and writes messages in the spool |
| `bin/coord-run.sh` | Loop runner — **run this to operate the coordinator** |
| `var/mail/spool` | The mbox spool (messages between coordinator and agents) |
| `var/run/coord-state.toml` | Persisted FSM state (survives restarts) |
| `tests/` | Nu unit and integration tests |

## 3. How to run

Run the coordinator loop from the repo root:

```sh
sh bin/coord-run.sh
```

Optional environment variables:

| Variable | Default | Description |
|---|---|---|
| `ROOT` | `.` | Repo root |
| `INTERVAL` | `60` | Seconds between normal ticks |
| `HALT_INTERVAL` | `10` | Seconds to sleep while halted |
| `STATE_FILE` | `var/run/coord-state.toml` | FSM state file |
| `SPOOL` | `var/mail/spool` | mbox spool path |

Run a single tick manually:

```sh
nu bin/coord-tick.nu
```

## 4. How to test

```sh
nu tests/mbox-parse-test.nu
nu tests/coord-tick-test.nu
```

Or run all tests at once:

```sh
sh tests/run-all.sh
```

## 5. Key spec

`docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md`

Critical sections:
- **§12** — FSM state machine definition
- **§13** — HALT/escalation protocol
- **§17** — Capability check logic
- **D2** — Retry policy

## 6. Spool protocol

- Messages are standard mbox format with TOML bodies.
- `verdict` field must be one of: `pass`, `fail`, `blocked`.
- When `attestation_required = true`, the message body must include one or more `[[claims]]` blocks.
- `tools_required` is checked against `AGENT_CAPABILITIES` defined in `bin/coord-tick.nu`.

## 7. HALT flow

- **Per-task halt**: `var/mail/HALT.<task_id>` — coordinator pauses that task only.
- **Resume**: send a message with `X-Resume-Action: retry | abort | edit` in the spool.
- **Global emergency stop**: create `var/mail/HALT` (no suffix) — `coord-run.sh` detects this and skips invoking `coord-tick.nu`, sleeping `HALT_INTERVAL` seconds instead.
- Remove `var/mail/HALT` to resume normal operation.

## 8. Branch

Active development branch: `claude/stoic-pascal-u6y3T`

## 9. License

Apache-2.0
