# Mailbox + JEC Handoff Protocol — Design Spec v1.2

- **Date**: 2026-04-30
- **Project**: smolBSD
- **Status**: v1.2 — fb-vm-24/fbuild reconciliation, port 2222, screen-socket gotcha, .local network-context caveat
- **License**: BSD-2-Clause (project default)
- **History**: v1 (2026-04-30 13:30 — open sections deferred); v1.1 (2026-04-30 14:30 — agent replies harvested, folded); v1.2 (2026-04-30 15:00 — fb-vm-24/fbuild reconciliation, port 2222, screen-socket gotcha, .local network-context caveat)

## 1. Purpose

Prove that **project state can be transferred between Claude Opus 4.7 (1M context) agent teams** with no shared conversation history, using only:

- a single BSD-mailbox file as the interchange substrate, and
- Just-Enough-Context (JEC) drops compressed via RTK and other context-engineering techniques.

The first test workload is **smolBSD** itself (TinyOS path per `plans/tinyos/TINY_OS_VS_RUMPOS_BSD_PLAN.md`). When the protocol is proved on the prototype, the substrate moves to a real (Tiny|Rump)BSD instance where `/var/mail/<agent>` is the literal handoff channel. The two halves of the experiment converge there.

## 2. Substrate

- **Format**: mbox (RFC822 + `From ` separator). Body is `Content-Type: text/toml; charset=utf-8`.
- **Topology**: single shared spool, addressed by `To:` header. One file == entire system state.
- **Path**: `/Users/studio/smolBSD/var/mail/spool` (mirrors `/var/mail/`; in-tree so the spool itself becomes part of the project state that survives a fresh clone — which is the whole point).
- **Concurrency**: only the coordinator appends. Subagents read filtered by `To:` and **emit** replies by appending. The coordinator harvests on its next loop. No locking required at this stage; we'll revisit when multiple writers appear.
- **Threading**: `Message-ID` + `In-Reply-To`, exactly as in classic mail. Replies always go `To: coordinator@smolbsd.local`.

## 3. Addressing convention

```
<role>@smolbsd.local        # role-based virtual address resolved by coordinator
coordinator@smolbsd.local   # the orchestrator's inbox
architect@smolbsd.local
builder@smolbsd.local
reviewer@smolbsd.local
researcher@smolbsd.local
```

In the prototype phase, "addresses" are virtual — the coordinator dispatches a Claude Code subagent and tells it which `Message-ID` to read. When we move to a real BSD instance, each address gets a real `passwd(5)` entry and a real `/var/mail/<role>`.

## 4. Envelope format (mbox + TOML body)

### 4.1 Request (coordinator → agent)

```
From smolbsd-coord Tue Apr 30 12:50:00 2026
From: coordinator@smolbsd.local
To: architect@smolbsd.local
Subject: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 12:50:00 -0000
Message-ID: <task-0001.coord@smolbsd.local>
X-Project: smolbsd
X-Phase: tinyos/forge-tiny-baseline
X-JEC-Compression: rtk-v1
Content-Type: text/toml; charset=utf-8

task_id     = "task-0001"
title       = "Bootstrap FreeBSD 15 amd64 VM with smallest stable footprint"
deadline    = "2026-05-14"

[brief]                       # JEC: prose, soft cap 200 words
summary = """..."""

[context_pointers]            # JEC: paths/shas/msgids — NOT inlined
read         = ["docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md", ...]
prior_msgids = []

[acceptance]                  # binary, testable
must_pass = ["VM boots to login prompt unattended", ...]

[reply_contract]
output_to            = "coordinator@smolbsd.local"
output_format        = "mbox+toml-v1"
attestation_required = true
skills_recommended   = ["freebsd", "qemu-fleet", "freebsd-build-vm"]
tools_required       = ["Read", "Write", "Edit", "Bash"]   # §17: coord rejects dispatch if subagent type lacks any
tools_allowed        = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
budget_tokens        = 80000
```

### 4.2 Reply (agent → coordinator)

```
From smolbsd-architect Tue Apr 30 14:10:00 2026
From: architect@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 14:10:00 -0000
Message-ID: <task-0001.architect@smolbsd.local>
In-Reply-To: <task-0001.coord@smolbsd.local>
References: <task-0001.coord@smolbsd.local>
X-Project: smolbsd
X-Verdict: pass
Content-Type: text/toml; charset=utf-8

task_id = "task-0001"
verdict = "pass"             # pass | fail | blocked

[[claims]]                   # required when reply_contract.attestation_required
subject  = "VM boots to login prompt"
expected = "login: prompt within 30s"
probe    = "expect(1) script timed boot"
evidence = "logs/task-0001/boot.log:line 412"
verdict  = "pass"

[[artifacts]]
path = "build/freebsd-15-amd64-tiny.qcow2"
sha  = "sha256:..."
size = "487 MiB"
git  = "abc1234"

next_recommended = ["task-0002: shrink to <256 MiB"]
```

## 5. JEC profile — `rtk-v1`

`X-JEC-Compression: rtk-v1` declares the compression contract for the message. Two layers:

### 5.1 Outbound (coordinator-side)

When the coordinator inlines anything in `[brief]` or expands a `context_pointer` inline (rare; pointers are preferred), the content is pre-processed through RTK:

| Source                  | RTK command            | Reduction target |
|-------------------------|------------------------|------------------|
| `git status`/`diff`/`log` | `rtk git ...`          | -75% to -92%     |
| File excerpt            | `rtk read -l aggressive` | -70% (signatures only) |
| Test/build output       | `rtk test <cmd>`       | -90%             |
| Lint output             | `rtk lint`/`rtk tsc`   | -80%             |
| Directory listing       | `rtk ls`/`rtk find`    | -80%             |

Strategies (per RTK docs): smart filtering · grouping · truncation · deduplication.

### 5.2 Inbound (agent-side)

Agents that have RTK installed and `rtk init -g` run get the Bash hook automatically. Their own `Read`/`Grep`/`Bash` calls expanding `context_pointers` are filtered the same way. **The protocol does not require RTK on the agent side** — it degrades gracefully to raw output if RTK is absent. The `X-JEC-Compression` header signals capability, not requirement.

## 6. Dispatch loop

```
┌─────────────┐  1. write request mbox     ┌──────────────────┐
│ coordinator │ ────────────────────────► │ var/mail/spool   │
└─────────────┘                            └──────────────────┘
       │                                            │
       │ 2. spawn subagent                          │
       │    "your msgid is <task-XXX.coord@..>"     │
       ▼                                            │
┌─────────────┐  3. read+parse                     │
│   subagent  │ ◄─────────────────────────────────┘
│  (cold)     │
│             │  4. do the work
│             │     (Read, Bash via RTK, Edit, ...)
│             │
│             │  5. append reply mbox addressed
│             │     To: coordinator@smolbsd.local  ┌──────────────────┐
│             │ ────────────────────────────────► │ var/mail/spool   │
└─────────────┘                                    └──────────────────┘
       │ 6. agent terminates                              │
       ▼                                                   │
┌─────────────┐  7. harvest replies                       │
│ coordinator │ ◄─────────────────────────────────────────┘
└─────────────┘
```

The coordinator may write N requests in one batch and dispatch N subagents in parallel. Each subagent only reads its own message (filtered by `Message-ID` it was told to look for). Outputs are append-only and naturally serialized by the spool's mbox structure.

## 7. Verification — fleet-eval reflex

Per `~/.claude/CLAUDE.md`, every reply with `verdict = "pass"` and `attestation_required = true` MUST contain at least one `[[claims]]` block. The coordinator cross-checks with `fleet-eval verify` before trusting the reply. Untrusted replies trigger retry (policy TBD by D2).

## 8. Roles and agent assignments

| Role            | Address                       | Backing subagent type              | Tools required (writes?)         |
|-----------------|-------------------------------|------------------------------------|----------------------------------|
| coordinator     | `coordinator@smolbsd.local`   | (this Opus 4.7 1M session)         | Read+Write+Edit+Bash             |
| architect       | `architect@smolbsd.local`     | `feature-dev:code-architect` (RO) **OR** `general-purpose` (RW) | depends on `tools_required` field — see §17 |
| builder         | `builder@smolbsd.local`       | `general-purpose` + freebsd skill  | Read+Write+Edit+Bash             |
| reviewer        | `reviewer@smolbsd.local`      | `pr-review-toolkit:code-reviewer`  | Read-mostly                      |
| researcher      | `researcher@smolbsd.local`    | `general-purpose` + Explore        | Read-only OK                     |
| security        | `security@smolbsd.local`      | `general-purpose` + redact skill   | Read+Bash (Write only for envelopes under `var/run/secrets/`) |
| ops             | `ops@smolbsd.local`           | `general-purpose` + fleet-irc skill | Read+Write+Bash                  |

## 9. State that survives a handoff

The receiving agent team boots cold and gains full project state from these on-disk artifacts (no conversation history needed):

1. `var/mail/spool` — full message history, threaded
2. `docs/superpowers/specs/*.md` — design contracts (this file)
3. `plans/tinyos/*.md` — original plan(s)
4. `.planning/*.md` — backlog, in-flight tasks
5. `jj log` — once smolBSD is a jj repo (TODO: `jj git init`). Multi-agent isolation later via `jj workspace add` rather than `git worktree`.

This is the AX-first surface from `~/.claude/CLAUDE.md`: structured in/out, manifest-discoverable, attestation-bearing, schema-composable.

## 10. Closed sections — folded from agent replies

| §  | Question            | Owner    | Reply msgid (canonical record)          | Status |
|----|---------------------|----------|------------------------------------------|--------|
| 11 | Secrets handling    | security | `<design-d1.security@smolbsd.local>` (spool L441–711) | folded v1.1 |
| 12 | Retry policy        | reviewer | `<design-d2.reviewer@smolbsd.local>` (spool L712–1057) | folded v1.1 |
| 13 | Escalation channel  | ops      | `<design-d3.ops@smolbsd.local>` (spool L215–440) | folded v1.1 |

The full reply contents live in the spool. Sections below are distillations; on conflict, the spool reply is canonical.

## 11. Secrets handling (from D1)

**Mechanism**: out-of-band envelope files at `var/run/secrets/<task-id>/<key>` mode 0600, with a `.meta.toml` sidecar containing the `redact`-fingerprint. The spool only carries a `[secrets.<key>]` pointer table — never values. `var/run/` is `.gitignore`'d.

**Six rules:**

1. No secret value, plaintext or encoded, ever appears in the spool. Pointers only.
2. `var/run/` is `.gitignore`'d at repo root. Mode 0700 dir, 0600 envelopes.
3. Envelope filenames carry the *key name*, never a value-derived fingerprint.
4. Replies attest "I read $key" via `redact` fingerprint (e.g. `fc1dxxxx4439`) — proves identity, never leaks the value.
5. Envelopes are ephemeral — coordinator unlinks `var/run/secrets/<task-id>/` after harvest, regardless of verdict.
6. Backing store is the source of truth; envelopes are a per-task materialization layer, not storage. Rotation happens in the backing store.

**Pointer table** (the only secret-related content in the spool):

```toml
[secrets.gitea_token]
envelope    = "var/run/secrets/task-0042/gitea_token"
fingerprint = "fc1dxxxx4439"
source      = "keychain:gitea-pat"
expires_at  = "2026-04-30T18:00:00Z"
scope       = ["gitea.local:3000/api/v1/repos/*"]   # advisory
```

**Backing stores (license-clean):**

- Prototype phase: `/usr/bin/security` (macOS Keychain, ships with macOS) — verified present on this host.
- Target BSD VM: `gopass` (MIT, drop-in for `pass`). NOT `pass(1)` — GPL-2.0, disallowed.
- ssh-agent for SSH-key-shaped credentials (BSD-2 + ISC). `SSH_AUTH_SOCK` verified live.
- 1Password CLI (`op`) is mentioned in CLAUDE.md but **not installed on this host** (`which op` → not found). Design degrades gracefully; `op:vault/item` is a one-line addition to the materializer if/when available.

**Cross-phase invariance**: only the materializer (step 1 of the worked example) changes between prototype and BSD VM target. Steps 2–5 (subagent reads envelope → verifies fingerprint → uses inline → emits attestation → coordinator wipes) are byte-identical.

**Revocation**: three drills — planned (control message + drain), emergency (composes with D3's HALT marker, `rm -P` envelopes, `[control] HALT-ALL`), envelope leak (per-task wipe + new msgid). Audit trail = spool's jj history.

**Cross-design hooks:**

- D2 retry policy treats credential-fingerprint mismatch as **immediate escalate, no auto-retry** (one extra predicate before the retry table).
- D3 HALT marker accepts `X-Halt-Reason: credential-fingerprint-mismatch` as a recognized halt cause.

**Implementation backlog** (assigned forward):

- ops: create `.gitignore` with `var/run/` and `var/mail/spool.lock` before first dispatch.
- coordinator: `bin/secret-materialize.nu` (Nushell per CLAUDE.md), `bin/secret-wipe.nu`, `bin/spool-emit-control.nu`.

## 12. Retry policy (from D2)

The coordinator is a **state-machine interpreter, not a planner**. Every reply category maps to exactly one transition. Mechanical, no per-case judgement.

**State machine:**

```
[DISPATCHED] -> [AWAITING_REPLY] -> [HARVEST] -> [VERIFY] -> [DONE]
                                       |             |
                                       +-> [RETRY_QUEUED] -+
                                       |                   |
                                       +-> [ESCALATE]      |
                                                           |
                            (after fib backoff) <----------+
```

Seven states: `DISPATCHED`, `AWAITING_REPLY`, `HARVEST`, `VERIFY`, `RETRY_QUEUED`, `DONE`, `ESCALATE`. (Full DOT digraph in `<design-d2.reviewer@…>` body.)

**Decision table** (one row per reply category, schema = category, predicate, next_state, max_retries):

| Category                  | Predicate                                                         | Next state    | Max retries |
|---------------------------|-------------------------------------------------------------------|---------------|-------------|
| `pass+verified`           | `verdict='pass'` AND every `[[claims]]` re-probes pass            | `DONE`        | 0           |
| `pass+probe-failed`       | `verdict='pass'` AND any `[[claims]]` re-probe fails/inconclusive | `RETRY_QUEUED` | **1** (half budget) |
| `fail`                    | `verdict='fail'`                                                  | `RETRY_QUEUED` | 3           |
| `blocked+unblocker-named` | `verdict='blocked'` + actionable `blocked_by` field               | `RETRY_QUEUED` | 3           |
| `blocked+no-unblocker`    | `verdict='blocked'` + no `blocked_by`                             | `ESCALATE`    | 0 (immediate) |
| `no-reply`                | no msg matching dispatch Message-ID after timeout (default 30 min)| `RETRY_QUEUED` | 3           |
| `malformed`               | mbox parse fail / TOML invalid / missing required fields / pass-without-claims-when-required | `RETRY_QUEUED` | 3 |

**Backoff: Fibonacci** `[60, 60, 120]` capped at 300s.

**Why Fibonacci, not exponential**: each retry costs 60–100k tokens of agent budget. Exponential `(60→120→240→480)` burns the prompt-cache TTL (5 min, per CLAUDE.md ScheduleWakeup guidance) on every step. Fibonacci grows slower; the doubled-60 lets a transient flake resolve in a cache-warm window. Cap aligns with the 5-min TTL.

**Why `max_attempts = 3`**: rule-of-three. (1) baseline establishes failure mode; (2) proves it isn't transient, with prior failure summary inlined; (3) last shot, with explicit "if you can't pass, return blocked-with-named-blocker rather than fail again". Beyond 3 = muri (unreasonable strain) → escalate.

**Why probe-disagreement gets only 1 retry**: more agent retries can't break a tie between agent and probe. Either probe is wrong (operator fix) or agent is hallucinating (operator adjust). Both need human input → escalate fast.

**Retry payload contract** — every retry MUST mutate the request payload (pure resends are forbidden — pure muda):

- `prior_attempt_msgid` — Message-ID of failed reply (or NIL for no-reply)
- `prior_attempt_failure` — verdict + first 500 chars of failure evidence
- `prior_attempt_count` — 1 or 2
- `format_violation` — parser error (if `category=malformed`)
- `probe_disagreement` — fleet-eval probe output (if `category=pass+probe-failed`)
- New Message-ID per retry: `<task-XXX.coord.r{N}@smolbsd.local>`
- `X-Attempt: <N>` header (1-indexed; coord state reconstructable from spool alone)
- For `no-reply` only: `budget_tokens` doubles per retry, capped at 200000

**Cross-design predicate (pre-table check):**

- `reply.secrets_consumed[*].fingerprint` mismatch with materializer's recorded fingerprint → bypass table, force-escalate with `X-Halt-Reason: credential-fingerprint-mismatch`. Mechanical, not judgement (per D1).

**No-double-dispatch invariant**: coordinator MUST NOT have two in-flight messages with the same `task_id`. Enforced by scanning spool for unmatched `<task-XXX.coord*@>` before each new dispatch.

**Edge cases worth naming explicitly:**

- `pass` without `[[claims]]` when `attestation_required=true` → MALFORMED, not pass+verified.
- `INCONCLUSIVE` probe (e.g. SSH timeout) → probe-failed, not pass+verified.
- Multiple `[[claims]]` with mixed PASS/FAIL → category is `pass+probe-failed`.
- Late reply after timeout-fired retry → logged, ignored; in-flight retry has authority.
- Two replies with same `In-Reply-To` → first wins; second logged as protocol violation.
- Coordinator crash mid-retry → on restart, scan spool for dispatched-without-reply older than timeout; treat as no-reply with attempt count from `X-Attempt` header.

## 13. Escalation channel (from D3)

**Primary**: in-spool message to `user@smolbsd.local` + `var/mail/HALT` marker file. The spool *is* the substrate — reusing it costs zero new tooling, threads correctly, survives a fresh clone, and the user already has standard mbox tools (`mailx`, `less`, `grep`).

**Fallback**: one-shot Ergo IRC DM to `ryan` on `10.0.3.203:6697` (TLS) via `openssl s_client`. Push-only signal, NOT the canonical reply path. Honors CLAUDE.md "no probe loops on LAN servers" and Ergo auto-block protections — exactly one TLS attempt, optional one plain on 6667 if TLS handshake fails, then record outcome in HALT marker and move on.

**Pause marker**: `var/mail/HALT` — one `stat()` per coordinator tick is the entire pause check. Spool is only re-parsed once HALT presence is confirmed, to find the resume reply.

**HALT message shape:**

```
From: coordinator@smolbsd.local
To: user@smolbsd.local
Subject: [HALT] <task-id> — <one-line cause>
Message-ID: <halt-<task-id>.coord@smolbsd.local>
In-Reply-To: <task-id.coord@smolbsd.local>
References: <all retry msgids, space-separated>
X-Priority: 1
X-Halt-Reason: retry-exhausted | claim-verification-failed | malformed-reply
             | no-reply | blocked-no-unblocker | credential-fingerprint-mismatch
X-Resume-Tag: resume-<task-id>
```

Body (TOML) carries category, attempts list (msgid+verdict+evidence+probe-result per attempt), last_failure summary, proposed_actions = [retry, retry-as-<role>, abort, edit], and asks (what coordinator wants from human/D3).

**HALT marker (TOML body)**: `halted_at`, `task_id`, `halt_msgid`, `resume_tag`, `reason`, `fallback_fired`, `fallback_status`.

**User reply protocol**: append a resume mbox message (`Subject: Re: [HALT]`, `Message-ID: <resume-<task-id>.user@…>`, `X-Resume-Action: retry | retry-as-<role> | abort | edit`), then `rm var/mail/HALT`. Bare `rm var/mail/HALT` alone = abort, no redispatch. Detection latency = next coord tick (suggested 60s when HALT present).

**Triple-failure path** (spool write fails AND IRC fails AND HALT marker write fails):

1. Try `var/mail/HALT` write unconditionally — one filesystem op.
2. If even that fails, print structured panic to stderr: `{"event":"smolbsd-coord-panic","task_id":"…","spool_writable":false,"irc_reachable":false,"halt_writable":false,"ts":"…"}`. Exit code 78 (`EX_CONFIG`).
3. Coord process termination is itself the final escalation. The Claude Code harness session log carries the signal to user on next engagement. Async constraint satisfied via the harness boundary.

Triple-failure = substrate-integrity event, not task-level. Recovery is human; no automatic resume.

**Per-task isolation**: HALT marker is keyed by `task_id`, not global. Other tasks continue dispatching even when one task is halted. (D2 confirms: escalated task moves to `status=escalated`; dispatch loop continues for unrelated work.)

## 17. Capability/intent enforcement (lesson from round 1)

**Failure mode discovered**: in the round-1 dispatch wave, the architect (`feature-dev:code-architect`) was assigned a task whose `acceptance` required writing a file (`plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`). That subagent type is **read-only** — it has Read/Glob/Grep/WebFetch/TodoWrite but no Write/Edit/Bash. The agent produced the plan content in its reply but couldn't materialize it; the coordinator had to do that step. The protocol let this happen silently because nothing pre-validated the agent's tool capabilities against the task's actual needs.

**Rule**: every request envelope MUST include a `tools_required` field (in addition to the existing `tools_allowed`). The coordinator MUST refuse to dispatch a task to a subagent type whose tool set doesn't cover `tools_required`.

**Schema addition** (insert in `[reply_contract]` of every request, see §4.1):

```toml
[reply_contract]
tools_required = ["Read", "Write", "Edit", "Bash"]   # MUST be a subset of subagent's actual tool set
tools_allowed  = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]   # additional permitted
```

**Coordinator pre-flight check** (mechanical):

```
for tool in tools_required:
    assert tool in subagent_type.available_tools
        or refuse_dispatch("capability mismatch", task_id, subagent_type, missing=tool)
```

**Capability registry** (built into the coordinator, derived from each subagent type's documented tools):

| Subagent type                  | Has Write? | Has Bash? | Suitable for |
|--------------------------------|-----------|-----------|--------------|
| `general-purpose`              | yes       | yes       | building, ops, general work |
| `feature-dev:code-architect`   | **no**    | no        | research, design, planning **only** |
| `feature-dev:code-explorer`    | no        | no        | codebase exploration |
| `feature-dev:code-reviewer`    | no        | no        | review-only tasks |
| `pr-review-toolkit:code-reviewer` | yes (\*) | yes      | review with action |
| `Explore`                      | no        | yes       | search-heavy exploration |

(\*) per documented tool list

**Failure handling**: capability-mismatch refusal is a coordinator-level rejection, NOT a retry. The coordinator either (a) re-routes to a capable subagent type, or (b) splits the task into a research-only step (RO subagent) + a materialization step (RW subagent). The architect+coordinator pattern from round 1 is the canonical (b) form: architect produces content, coordinator materializes.

**Why this is its own §**: the failure mode generalizes — every protocol that decouples *intent* (the task brief) from *capability* (the executor) needs this check. mbox+TOML handoff just made the gap visible.

## 18. Operational notes — fbuild VM, network context, skill drift (v1.2)

This section captures three operational realities discovered during round-2
reachability testing. None change the protocol contract; all change what an
agent dropped in cold needs to know to actually use the substrate.

### 18.1 fbuild VM identity (the "fb-vm-24" drift)

The FreeBSD aarch64 build VM on `minim4-24` is canonically named **`fbuild`**
in reality: that is the screen-session name, the qemu `-name` argument, and
the disk image base name (`/Users/studio/vms/freebsd-15-build.qcow2`,
launched as `screen -dmS fbuild ...`). The **freebsd-build-vm skill** at
`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` calls it
**`fb-vm-24`** throughout — the "24" was a host suffix (`minim4-24`) that
got promoted into the VM name in skill prose. **The skill is stale on
this point and needs a separate update PR** (out of scope for this repo;
the skill lives globally under `~/.claude/`).

**Operational rule**: when reading the freebsd-build-vm skill, mentally
substitute `fbuild` for `fb-vm-24` for VM-level identifiers (screen
session, qemu `-name`, image filename). When the skill name `fb-vm-24` is
referenced as a symbol in this repo, it is marked
"skill-canonical name (drift; actual VM is `fbuild`)".

### 18.2 SSH hostfwd port (2225 → 2222)

The freebsd-build-vm skill documents `hostfwd=tcp::2225-:22`. Ground-truth
on minim4-24 (verified 2026-04-30T21:33:39Z via `lsof` against qemu pid
29210): `hostfwd=tcp::2222-:22`. **Use port 2222 for ssh-into-fbuild**.

```
ssh -J minim4-24 -p 2222 builder@localhost      # correct (current reality)
ssh -J studio@10.0.3.1 -p 2225 builder@localhost  # stale skill prose; do not use
```

### 18.3 virtfs share path (doubled-prefix wrapper bug)

The fbuild qemu cmdline carries
`-virtfs local,path=/Users/studio/Users/studio/share/fbuild,...`. The
doubled `/Users/studio/Users/studio/` is a **launch-wrapper bug**: a
literal `~` was prefixed to an already-absolute path inside
`run-fb-vm-24.sh` (the fleet-ops template), producing the doubled prefix
when the shell expanded `~` to `/Users/studio` before string concatenation.

**Status**: documented as a wrapper bug to fix separately in fleet-ops
(`vm-templates/run-freebsd-vm.sh.template`). Until then, source-IN /
artifacts-OUT must use the doubled path on the host side:

```
# host (minim4-24) side — drop sources here:
~/Users/studio/share/fbuild/source/        # WRONG (skill prose)
/Users/studio/Users/studio/share/fbuild/source/  # CURRENT REALITY
```

Inside the VM the mount tag (`host0`) and mountpoint (`/mnt/host`) are
unchanged — the bug is host-path-only.

### 18.4 Screen-socket-lost gotcha (qemu alive, screen -r fails)

**Detected via**: on minim4-24, `pgrep -f qemu-system-aarch64` returns pid
29210 (qemu running) but `screen -ls` returns
`No Sockets found in /var/folders/.../screen`. The fbuild VM is reachable
on ssh:2222, but the canonical recovery path
(`screen -r fbuild` → console) is **inert** — the screen session that
launched qemu lost its socket file. The qemu process inherited the file
descriptors and survived; the screen wrapper did not.

**Recovery procedure** (per freebsd-build-vm skill §"Launching the VM
(canonical)"):

```
# 1. Confirm both halves of the diagnostic on minim4-24:
ssh minim4-24 'pgrep -f qemu-system-aarch64; screen -ls'
#  -> qemu pid present
#  -> "No Sockets found"  --> socket lost

# 2. Kill the orphan qemu (it has no console anyway):
ssh minim4-24 'pkill -f "qemu-system-aarch64.*-name fbuild"'

# 3. Relaunch via the canonical wrapper (re-establishes screen + socket):
ansible minim4-24 -m raw -a "~/vms/run-fb-vm-24.sh"
ansible minim4-24 -m raw -a "screen -ls; pgrep -f qemu-system-aarch64"
```

**When NOT to do this**: while a long build is in progress inside the VM
(via ssh-launched `screen -dmS smolkernel` or similar in-VM screen
session). Killing qemu kills the build. Verify no in-flight build exists
before recovery — `ssh -p 2222 builder@... screen -ls` from minim4-24
will list any in-VM screen sessions.

### 18.5 `.local` fleet hostnames are LAN-only (network-context caveat)

The fleet's `.local` hostnames (`qnas.local`, `ergo.local`,
`searxng.local`, `gitea.local`, etc., per ansible-managed `/etc/hosts`
entries with `10.0.3.x` IPs — see CLAUDE.md "Search" section) **resolve
only when the agent is LAN-attached** (host is on the QNAS LAN
10.0.3.0/23). From a non-LAN-attached coordinator (e.g. a Mac on a
different network using Tailscale to reach minim4-24), they fail to
resolve / route.

Tailscale resolves Tailscale-attached node names (`minim4-24` itself is a
tailnet member) but does **not** proxy to non-tailnet hosts inside a
nested QEMU guest (`fbuild` reaches the LAN via SLIRP NAT only; the LAN
does not see fbuild as a tailnet peer).

**Implication for D3 escalation fallback** (§13): the fallback IRC DM
`openssl s_client 10.0.3.203:6697` is **inert from a non-LAN-attached
coordinator** — there is no route to `10.0.3.203` from a Mac that only
sees minim4-24 over Tailscale. The HALT marker + spool-message primary
path (§13) still works (it is filesystem-local), so the design is not
broken. The fallback is best-effort and degrades to "logged in HALT
marker, fallback_status = 'no-route'" when fired off-LAN.

**No design change**: D3's triple-failure path (§13) already covers this
case — fallback failure is logged, not fatal. This caveat is just the
explicit network-context assumption an agent dropped in cold needs to
recognize before debugging "why did the IRC fallback silently no-op".

## 14. Caveats and known limits

1. **No `sequential-thinking` MCP server is loaded** in this Claude Code instance. Stepwise reasoning happens in-prompt, not via that MCP. If the user installs it later, the protocol doesn't change — it's an internal-to-coordinator concern.
2. **smolBSD is now a jj repo** as of v1.1 (`jj git init` ran; commit `24b600c3` recorded round 1). Multi-agent isolation later via `jj workspace add ../smolBSD-<role>`.
3. **Memory exists but is sparse**. `~/.claude/projects/-Users-studio-smolBSD/memory/MEMORY.md` indexes three entries (Knox/TrustZone background, BRAP L1 decision, jj-not-git VCS preference). The spec, plan, and spool remain the primary durable state.
4. **Single-writer assumption** for the spool holds only while the coordinator is the sole producer. Multi-coordinator scenarios need locking — out of scope for v1.
5. **Subagent context bleed**: when this Opus session uses the `Agent` tool, the subagent does inherit some implicit harness context (skills index, CLAUDE.md). True "no shared context" requires moving to a separate `claude` invocation or different harness — see §15.
6. **RTK is optional on agent side and not yet installed on this host** (`which rtk` → not found). Outbound compression (side A) is honored by the coordinator pre-inlining; inbound (side B) becomes active when `brew install rtk && rtk init -g` is run. Agents without RTK degrade gracefully but produce larger outputs.
7. **Trust boundary**: the coordinator must verify `[[claims]]` independently. A misaligned subagent could fabricate claims; `fleet-eval` is the eval-reflex gate. **Round-1 claims have not yet been re-probed** — outstanding follow-up.
8. **Apache-2.0 RTK** — license is on the user's allowlist. If it changes upstream we re-evaluate.
9. **Capability/intent gap** existed in v1; closed by §17 in v1.1. Pre-existing requests in the spool do not have `tools_required` fields — they are grandfathered in for round 1 only.
10. **Citation hallucination risk**: the round-1 architect cited a "vermaden 2026-02 blog post" not independently verified. Treat agent-introduced citations as low-confidence until cross-checked. Substantive technical content (oci-image-runtime.conf, MINIMAL config, Makefile.vm) is verifiable against [cgit.freebsd.org](https://cgit.freebsd.org/src/tree/sys/amd64/conf/).
11. **`.gitignore` not yet written** — D1 secrets design requires `var/run/` to be jj/git-ignored before first credential dispatch. ops follow-up.
12. **`pass(1)` is GPL-2.0** — disallowed under the user's licensing rule. The secrets design uses `gopass` (MIT) instead. Don't accidentally drop `pass` into a future dependency.
13. **freebsd-build-vm skill is stale on VM-name and SSH-port** (v1.2). The global skill at `/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` calls the VM `fb-vm-24` (actual: `fbuild`) and lists hostfwd port `2225` (actual: `2222`). Skill update is a separate PR outside this repo; §18 is the authoritative reconciliation for now. Mentally substitute when reading the skill.
14. **`.local` hostnames are LAN-only** (v1.2 — see §18.5). From a coordinator reaching minim4-24 only over Tailscale, the D3 IRC fallback to `10.0.3.203:6697` is inert — design degrades gracefully (HALT marker + spool path are filesystem-local), but agents should expect `fallback_status = 'no-route'` when off-LAN.
15. **Screen-socket-lost is a known fbuild hazard** (v1.2 — see §18.4). qemu can outlive its launching screen session; `screen -r fbuild` then fails even though the VM is reachable on ssh:2222. Recovery is `pkill qemu` + relaunch via `~/vms/run-fb-vm-24.sh`. Verify no in-VM build is in flight first.

## 15. Future work

- Move spool to a real (Tiny|Rump)BSD instance now that §§11–13 are filled — protocol is portable by construction.
- Commit the spool + spec on every coordinator loop (`jj describe -m "..." && jj new`). Per-agent isolation via `jj workspace add ../smolBSD-<role>`.
- Implement coordinator binaries:
  - `bin/coord-tick.nu` — table-driven state-machine interpreter reading §12 verbatim
  - `bin/coord-escalate.nu` — D3 protocol entry point
  - `bin/secret-materialize.nu` / `bin/secret-wipe.nu` — D1 envelope lifecycle
  - `bin/spool-emit-control.nu` — control messages (rotate-key, halt, resume)
  - `bin/spool-tail.nu` — `mailx -f spool` style viewer with TOML pretty-printing
  - `bin/spool-archive.nu` — rotate spool > N messages to `var/mail/spool.YYYY-MM-DD`
- Cross-harness handoff: prove protocol works coordinator-Claude → builder-Codex.
- `Manifest:` discovery endpoint per AX-first.
- TrustZone integration (forward-look, given user's Knox background + BRAP L1 decision): replies could carry `[[attestations]]` blocks alongside `[[claims]]`, where the attestation is a TA-signed quote produced by the building VM. Spec v2 candidate.

## 16. Self-review checklist (v1.2)

- [x] No "TBD" in any section — §§11/12/13 fully folded; §17 fully specified; §18 (operational notes) added in v1.2
- [x] Sections internally consistent — §4.1 schema includes new `tools_required` field per §17; §8 role table has Tools-required column; §11/§12 cross-reference (D1+D2 fingerprint-mismatch override); §12/§13 cross-reference (ESCALATE → HALT protocol); §13/§18.5 cross-reference (IRC fallback inert when off-LAN, by design — falls back to filesystem-local primary)
- [x] Scope: focused on a single substrate (mbox+TOML+spool) with one closed contract — ready to implement
- [x] Ambiguities resolved:
  - mbox path explicit (`var/mail/spool`)
  - RTK side-A vs side-B distinguished
  - trust boundary named (fleet-eval probes; coordinator never trusts self-report alone)
  - capability/intent split (§17) — read-only vs read-write subagent types
  - pass+probe-failed has half retry budget (§12)
  - blocked has two sub-categories (with/without unblocker) with different transitions
  - fbuild VM identity and reachability primitives (§18) — VM name `fbuild` (not `fb-vm-24`), SSH port 2222 (not 2225), virtfs path `/Users/studio/Users/studio/share/fbuild` (doubled-prefix wrapper bug, documented to fix separately)
- [x] License floor verified: openssl Apache-2.0, Ergo MIT, Nushell MIT, mbox = plain RFC822 (no library), gopass MIT, ssh-agent BSD-2+ISC, RTK Apache-2.0. No GPL/LGPL/AGPL.
- [x] Cross-design composition explicit: D1↔D2 (fingerprint mismatch path), D2↔D3 (escalation handoff), D1↔D3 (HALT marker accepts X-Halt-Reason from D1), §18.5↔§13 (off-LAN IRC fallback degrades to logged no-route, primary path unaffected)
- [x] Forward references named: §17's capability check is mechanical, not a judgement call; §18 reconciliations are mechanical lookups (no judgement) until upstream skill is updated
- [x] Drift surfaced and reconciled (v1.2): freebsd-build-vm skill is stale on VM name + SSH port; §18 + caveats §14.13 are the authoritative reconciliation in-tree; skill needs separate update PR
