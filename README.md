# smolBSD

## What it is

smolBSD is a minimal FreeBSD 15 VM (aarch64 primary, amd64 secondary) paired
with a Nushell coordinator finite-state machine that dispatches build,
review, and ops tasks to agents over an mbox+TOML mail spool. The goal is a
small qcow2 artifact that boots unattended to a login prompt in under 30
seconds on HVF/KVM hosts, driven end-to-end by the coordinator without
shared conversation history.

## Status

As of 2026-05-08:

| Leg     | Boot gate              | Image size            | Notes                                  |
|---------|------------------------|-----------------------|----------------------------------------|
| aarch64 | 11s on HVF — PASS      | 1.41 GiB (INVESTIGATING vs 512 MiB target) | Native build on `fbuild` |
| amd64   | KVM gate pending       | 2.5 GiB (official VM image) | Use Vultr/x86 KVM host for gate run |

See `docs/PHASE-1-RESULTS.md` for the full report (sha256s, fleet deploy on
fbrpi403, amd64 BIOS-boot verification).

## Build

Full pipeline lives in `docs/BUILDING.md`. The one-liner from a FreeBSD 15
aarch64 host with `/usr/src` checked out at `releng/15.0`:

```sh
sudo nu bin/build-smolbsd.nu
```

This runs setup, `buildworld`, `buildkernel KERNCONF=SMOLBSD`, kernel obj
cleanup, and `make cloudware-release` (the release image step). Output streams
to `/var/tmp/smolbsd-build.log`.
Use `--check` for a read-only preflight, `--skip-buildworld` to resume after
a long build, or `--arch amd64` to cross-compile.

## Harvest and acceptance gates

`bin/harvest.sh` fetches qcow2 artifacts from the remote build hosts (fbuild
via jump host for aarch64, Vultr for amd64) into `var/artifacts/`, then runs
the size and boot gates and writes `var/artifacts/harvest-report.txt`:

```sh
sh bin/harvest.sh
```

Gates:
- size <= 512 MiB (`wc -c` on the qcow2)
- boot via `expect tests/time-to-ready-arm64.exp` / `tests/time-to-ready.exp`

For diagnosing image bloat, mount the rootfs and dump the top directories,
files, and pkgbase packages by size:

```sh
bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolbsd.qcow2
```

Works on Linux (qemu-nbd) and FreeBSD (mdconfig). Writes a `.size-report.txt`
beside the image and exits non-zero if usage exceeds 512 MiB.

## Coordinator

The Nushell coordinator is documented in `CLAUDE.md`. To run the loop:

```sh
sh bin/coord-run.sh
```

To advance one tick by hand:

```sh
nu bin/coord-tick.nu
```

Environment overrides (all optional):

| Var             | Default                       | Purpose                          |
|-----------------|-------------------------------|----------------------------------|
| `ROOT`          | `.`                           | Repo root                        |
| `INTERVAL`      | `60`                          | Seconds between normal ticks     |
| `HALT_INTERVAL` | `10`                          | Seconds to sleep while halted    |
| `STATE_FILE`    | `var/run/coord-state.toml`    | Persisted FSM state              |
| `SPOOL`         | `var/mail/spool`              | mbox spool path                  |

FSM states are `idle -> dispatching -> waiting -> harvesting -> halted`. On
`dispatching`, the coordinator auto-spawns the `claude` CLI for the target
agent if it is on `PATH` (Phase II wiring); otherwise it queues the request
and waits for an external agent to reply into the spool. Global emergency
stop: `touch var/mail/HALT`; per-task halt: `var/mail/HALT.<task_id>`.

## Tests

```sh
sh tests/run-all.sh
```

Runs three Nu suites: `mbox-parse-test.nu`, `coord-tick-test.nu`, and
`spawn-subagent-test.nu`. Individual suites can be invoked directly with
`nu tests/<file>.nu`.

## License

Apache-2.0 for project code. FreeBSD base components retain their original
BSD-2-Clause / BSD-3-Clause licenses. No GPL/LGPL/AGPL dependencies.
