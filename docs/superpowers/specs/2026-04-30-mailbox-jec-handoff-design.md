# Mailbox + JEC Handoff Protocol — Design Spec v1

- **Date**: 2026-04-30
- **Project**: smolBSD
- **Status**: v1 — open sections deferred to dispatched agents (D1, D2, D3)
- **License**: BSD-2-Clause (project default)

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

| Role            | Address                       | Backing subagent type              |
|-----------------|-------------------------------|------------------------------------|
| coordinator     | `coordinator@smolbsd.local`   | (this Opus 4.7 1M session)         |
| architect       | `architect@smolbsd.local`     | `feature-dev:code-architect`       |
| builder         | `builder@smolbsd.local`       | `general-purpose` + freebsd skill  |
| reviewer        | `reviewer@smolbsd.local`      | `pr-review-toolkit:code-reviewer`  |
| researcher      | `researcher@smolbsd.local`    | `general-purpose` + Explore        |
| security        | `security@smolbsd.local`      | `general-purpose` + security skill |
| ops             | `ops@smolbsd.local`           | `general-purpose` + ansible-fleet  |

## 9. State that survives a handoff

The receiving agent team boots cold and gains full project state from these on-disk artifacts (no conversation history needed):

1. `var/mail/spool` — full message history, threaded
2. `docs/superpowers/specs/*.md` — design contracts (this file)
3. `plans/tinyos/*.md` — original plan(s)
4. `.planning/*.md` — backlog, in-flight tasks
5. `jj log` — once smolBSD is a jj repo (TODO: `jj git init`). Multi-agent isolation later via `jj workspace add` rather than `git worktree`.

This is the AX-first surface from `~/.claude/CLAUDE.md`: structured in/out, manifest-discoverable, attestation-bearing, schema-composable.

## 10. Open sections — deferred to dispatched agents

| § | Question                | Owner | Reply msgid expected             |
|---|-------------------------|-------|----------------------------------|
| D1 | Secrets handling       | security  | `<design-d1.security@…>`     |
| D2 | Retry policy           | reviewer  | `<design-d2.reviewer@…>`     |
| D3 | Escalation channel     | ops       | `<design-d3.ops@…>`          |

Their replies become spec §§ 11, 12, 13 in v1.1.

## 11. Open: Secrets handling

*Deferred to D1.*

## 12. Open: Retry policy

*Deferred to D2.*

## 13. Open: Escalation channel

*Deferred to D3.*

## 14. Caveats and known limits

1. **No `sequential-thinking` MCP server is loaded** in this Claude Code instance. Stepwise reasoning happens in-prompt, not via that MCP. If the user installs it later, the protocol doesn't change — it's an internal-to-coordinator concern.
2. **smolBSD is not yet a jj repo**. Fleet default is jj (Jujutsu), not git. Without `jj git init`, the spool is the only durable handoff channel. Recommend `jj git init` (Git-backed colocated, so `gh` and other Git tools still work) before the first build task.
3. **No memory file exists** for smolBSD or globally. The spec, plan, and spool ARE the memory.
4. **Single-writer assumption** for the spool holds only while the coordinator is the sole producer. Multi-coordinator scenarios (e.g., two parallel orchestrators) need locking — out of scope for v1.
5. **Subagent context bleed**: when this Opus session uses the `Agent` tool, the subagent does inherit some implicit harness context (skills index, CLAUDE.md). True "no shared context" requires moving to a separate `claude` invocation or different harness — see §15.
6. **RTK is optional on agent side**. Agents without RTK degrade gracefully but produce larger outputs. Mitigation: pre-compress in `[brief]` rather than relying on agent-side filtering.
7. **Trust boundary**: the coordinator must verify `[[claims]]` independently. A misaligned subagent could fabricate claims; `fleet-eval` is the eval-reflex gate.
8. **Apache-2.0 RTK** — license is on the user's allowlist. If it changes upstream we re-evaluate.

## 15. Future work

- Move spool to a real (Tiny|Rump)BSD instance once §11–13 are filled.
- Add `jj git init` and commit the spool + spec on every coordinator loop (`jj describe -m "..."` + `jj new`). Per-agent isolation via `jj workspace add ../smolBSD-<role>` instead of git worktrees.
- Add a `bin/spool-tail` viewer (Nushell) — `mailx -f spool` style, but with TOML pretty-printing.
- Add a `bin/spool-archive` rotator — when spool > N messages, rotate to `var/mail/spool.YYYY-MM-DD`.
- Cross-harness handoff: prove the protocol works coordinator-Claude → builder-Codex.
- Add a `Manifest:` discovery endpoint per AX-first principle.

## 16. Self-review checklist (filled inline)

- [x] No "TBD" in committed sections (open sections explicitly deferred to D1/D2/D3 — that's a contract, not a placeholder)
- [x] Sections internally consistent (envelope §4 matches schema §4.1/4.2; addressing §3 used in §6 dispatch loop)
- [x] Scope: single spec, one substrate, three open Q's deferred to agents — focused
- [x] Ambiguities resolved: mbox path is explicit; RTK side-A vs side-B clearly distinguished; trust boundary named
