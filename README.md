# smolBSD

A minimal FreeBSD image for embedded and edge deployments, coordinated by an
actor-model mailbox system.

## What is smolBSD?

smolBSD is a project to build the smallest stable FreeBSD VM that boots
unattended to a login prompt in 30 seconds or less. The target image fits inside
512 MiB on disk (aspirational: qcow2 artifact under 128 MiB) and ships only the
packages required to run `sh`, `vi`/`ed`, `rc.d`, and `pkg`.

Coordination across build tasks is handled by an actor-model mailbox: each agent
(architect, builder, reviewer, researcher) reads tasks addressed to it from a
shared mbox spool (`var/mail/spool`) and replies in-thread using RFC 822 envelopes
with TOML bodies. The coordinator harvests replies on each tick and dispatches the
next task. No shared conversation history is required — Just-Enough-Context (JEC)
drops carry all necessary state between agents.

## Phase I Targets

Two legs run in parallel; aarch64 is primary.

### aarch64 — HVF-native on Apple Silicon (`minim4-24`)

FreeBSD 15.0-RELEASE arm64, built natively on `fbuild` (a FreeBSD 15 aarch64 VM
hosted on an Apple Silicon Mac). HVF (Hypervisor.framework) provides near-bare-
metal acceleration for the aarch64 guest. The 30-second time-to-login acceptance
gate is only achievable here; amd64 emulation via TCG is 5-10x slower.

### amd64 — KVM on Vultr

FreeBSD 15.0-RELEASE amd64, cross-compiled from the aarch64 fbuild host and
deployed to a KVM-capable x86 Vultr instance for its timing gate.

## Build Approach

### Version control: jj

All commits use [jj](https://github.com/martinvonz/jj) (Jujutsu VCS). Drop to
raw git only when an external tool requires it.

```sh
jj log --no-graph -r '@' --limit 5    # recent history
jj describe -m "your message"         # update working-copy description
jj new                                # open a new change
```

### Nushell coordinator

`bin/coord-tick.nu` — the main coordinator loop. On each tick it:

1. Reads `var/mail/spool` and harvests agent replies.
2. Evaluates verdicts and acceptance criteria.
3. Appends the next task envelope to the spool.

`bin/mbox-parse.nu` — helper that parses mbox + TOML bodies into structured
records for downstream processing.

### Mailbox spool

`var/mail/spool` — a single RFC 822 mbox file. Every message (coordinator
request and agent reply) lives here. Addresses follow the pattern
`<role>@smolbsd.local`. The TOML body carries the structured task payload.

Example roles:
- `coordinator@smolbsd.local`
- `architect@smolbsd.local`
- `builder@smolbsd.local`
- `reviewer@smolbsd.local`

## Quick Start

### Prerequisites

- Apple Silicon Mac (for aarch64/HVF path) or a Vultr KVM instance (amd64 path)
- FreeBSD 15.0-RELEASE `fbuild` VM accessible via SSH jump:

```sh
ssh -J minim4-24 -p 2222 builder@localhost
```

- Nushell (`nu`) available locally for coordinator scripts
- `expect` available for acceptance tests

### Build the kernel

SSH into fbuild and run:

```sh
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLBSD
```

For the aarch64 native path no cross-compile flags are needed. For the amd64
cross-compile leg from the arm64 host:

```sh
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLBSD \
    TARGET=amd64 \
    TARGET_ARCH=amd64
```

### Run acceptance test

```sh
expect tests/time-to-ready.exp
```

The test measures wall-clock time from VM boot to login prompt and fails if it
exceeds 30 seconds.

### Advance the coordinator

```sh
nu bin/coord-tick.nu
```

## Project Layout

```
bin/
  coord-tick.nu          # coordinator actor loop
  mbox-parse.nu          # mbox+TOML parser
docs/
  superpowers/specs/     # design specifications
plans/
  tinyos/                # per-phase build plans
tests/
  time-to-ready.exp      # expect script: boot-to-login timing gate
var/
  mail/spool             # shared mbox — full project state in one file
```

## Technical Inspirations

- **Actor framework** — agents communicate only through the spool; no shared
  state beyond the mbox file
- **Tail-recursive FSMs** — coordinator is a pure state machine: read spool,
  compute next state, append message, repeat
- **SIMD / vector** — future workloads target NEON on aarch64 and AVX-512 on
  amd64 for signal-processing edge tasks
- **Secure enclaves** — long-term goal: run sensitive workloads inside FreeBSD
  bhyve enclaves on capable hardware
- **\*BSD substrate** — FreeBSD base provides a clean, permissively-licensed
  foundation; NetBSD pkgsrc considered for cross-arch package tooling

## License

Apache-2.0 for project-specific code. FreeBSD base system components retain
their BSD-2-Clause / BSD-3-Clause licenses. No GPL, LGPL, or AGPL dependencies
are permitted.
