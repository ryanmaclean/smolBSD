# Phase II Brief — smolBSD

- **Phase**: II of IV — End-to-End Demo, Fleet Deploy, Coord Wiring
- **Campaign**: smolBSD — The Tiny Realm vs The Rump Citadel
- **Authored by**: planner@smolbsd.local (task-0016)
- **Date**: 2026-05-04
- **Status**: planning — not yet started
- **Prerequisite**: Phase I exit gate = both arches pass measured-relics

---

## 1. Phase I Completion Status

### 1.1 Acceptance Gates

| Gate | Arch | Status | Notes |
|------|------|--------|-------|
| `buildkernel` exit 0 | aarch64 | DONE | exit=0, 224s, 13.3 MiB kernel |
| `buildkernel` exit 0 | amd64 | DONE | exit=0, 239s, 13 MiB kernel |
| `buildworld` + `release` qcow2 | aarch64 | IN FLIGHT | screen `smolbsd-world` on fbuild, started 2026-05-04 21:01 UTC |
| `buildworld` qcow2 | amd64 | IN FLIGHT | screen `smolbsd-bw` on Vultr REDACTED-VULTR-IP, LLVM bootstrap stage |
| Build success rate (qemu-img info) | aarch64 | BLOCKED on qcow2 | will self-unblock when buildworld finishes |
| Build success rate (qemu-img info) | amd64 | BLOCKED on qcow2 | will self-unblock when buildworld finishes |
| Time-to-ready (`time-to-ready-arm64.exp`) | aarch64 | BLOCKED on qcow2 | script at `tests/time-to-ready-arm64.exp`; expect <=30s via HVF on minim4-24 |
| Time-to-ready (`time-to-ready.exp`) | amd64 | BLOCKED on qcow2 | script at `tests/time-to-ready.exp`; requires KVM-capable x86 host (Vultr) |
| Peak + idle memory (host RSS < 300 MiB, in-VM free >= 150 MiB) | aarch64 | BLOCKED on qcow2 | |
| Peak + idle memory | amd64 | BLOCKED on qcow2 | |
| Artifact size (< 512 MiB hard cap; aspirational < 128 MiB) | aarch64 | BLOCKED on qcow2 | |
| Artifact size | amd64 | BLOCKED on qcow2 | |
| Crash recovery time (<= 60s) | aarch64 | BLOCKED on qcow2 | |
| Crash recovery time | amd64 | BLOCKED on qcow2 | |
| `coord-tick.nu` dispatch (FSM + spool write) | both | DONE | real FSM implementation; state-dispatching writes mbox envelope |
| `mbox-parse.nu` unit tests (6/6) | both | DONE | `nu tests/run-tests.nu --suite unit` passes on nu 0.111.0 |
| i18n (FR + JA) | both | DONE | committed in `plans/tinyos/` |

### 1.2 Remaining gates after builds complete

When `buildworld` + `release` finish on both hosts:

1. Copy qcow2 to `minim4-24` (aarch64) and to the Vultr amd64 instance.
2. Run `tests/time-to-ready-arm64.exp` — expected PASS (HVF, <=30s).
3. Run `tests/time-to-ready.exp` on Vultr x86 with KVM — expected PASS (<=30s on native ISA).
4. Run memory and artifact-size checks per plan §8.3 and §8.4.
5. Run crash-recovery test per plan §8.5.
6. Record all five measured relics per arch; both arches must pass for Phase I exit.

Note: the amd64 time-to-ready gate cannot be cleared on `minim4-24` (TCG, not HVF). Run it on the Vultr instance where the build is already in flight.

---

## 2. Phase II Scope

Phase II proves the original thesis: **project state transfers between Claude agent teams via BSD mailbox, with a real smolBSD VM as the execution substrate**. Four items, in priority order.

### P1 — End-to-end coord→agent dispatch cycle (the thesis demo)

**Goal**: close the loop — the coordinator writes a task to the spool; a subagent boots the smolBSD aarch64 qcow2 on `minim4-24`, runs a command inside it, and writes the result back to the spool. The two halves of the experiment converge on a live BSD `/var/mail` path.

**Concretely**:
1. Coordinator appends a task-0017 request to `var/mail/spool` addressed to `builder@smolbsd.local`.
2. Coordinator (or operator) spawns a `general-purpose` subagent with the message-ID; subagent reads the task.
3. Subagent launches `FreeBSD-15-aarch64-smolbsd.qcow2` via `qemu-system-aarch64 -machine virt,accel=hvf`, waits for login, SSHes in, executes the task command (e.g. `uname -a`, `df -h`), captures output.
4. Subagent appends a reply to `var/mail/spool` with `verdict=pass`, `[[claims]]` block, and stdout captured as evidence.
5. Coordinator harvests the reply, verifies the claim via fleet-eval, transitions to DONE.

**Acceptance**: one complete round-trip (coord dispatch → subagent boot → command → reply → harvest → DONE) with a `fleet-eval`-verified claim in the spool.

**SLIRP caveat**: the demo VM uses `-nic user` (QEMU SLIRP NAT). SLIRP provides outbound TCP/UDP from inside the VM but FreeBSD's `pkg` bootstrap requires resolving `pkg.freebsd.org` and fetching over HTTPS — this works under SLIRP only if the host has internet. Do not use `pkg install` as the demo task command; use a self-contained command (`uname -a`, `sysctl kern.version`, `df -h`) that has no outbound dependency. pkg install belongs to P2 (physical board with a real NIC) or a future bridged-network QEMU variant.

**Why first**: this is the core thesis. Everything else is expansion.

### P2 — Fleet deploy: aarch64 image on a physical target

**Goal**: boot the Phase I aarch64 qcow2 userland on a real aarch64 board (fbrpi, Pi 5, or RK3588).

**Required steps**:
- Convert `FreeBSD-15-aarch64-smolbsd.qcow2` to raw: `qemu-img convert -O raw`.
- Rewrite GPT layout to match Pi/RK firmware expectations (BCM2712 or RK3588 DTB pin; see plan §12.1 open question).
- Write to microSD, boot, verify `uname -a` returns `arm64`.
- Confirm `pkg install` works from the live device.

**Acceptance**: SSH login to a physical aarch64 board running the smolBSD image; `pkg install` completes successfully.

**Why second**: the aarch64 qcow2 is the userland the fleet will carry; physical boot proves the kernel+userland are not QEMU-specific.

### P3 — Coordinator wiring: `state-dispatching` shells out to `claude` CLI

**Goal**: `state-dispatching` in `bin/coord-tick.nu` currently writes the mbox envelope but does not spawn the subagent. Wire it to call `claude` CLI (or an equivalent harness command) so dispatch is fully automated.

**Concretely**: add a `spawn-subagent` helper to `coord-tick.nu` that, after appending the envelope, shells out:
```
^claude --model claude-sonnet-4-6 --print "Read Message-ID <task-XXX.coord@smolbsd.local> from var/mail/spool and complete the task."
```
The subagent runs synchronously or is backgrounded; the coordinator transitions to `waiting` and polls the spool for the reply.

**Acceptance**: `nu bin/coord-tick.nu` with a queued task results in a subagent process spawning, doing work, and the coordinator harvesting the reply — all without operator intervention.

**Why third**: automates what is currently a manual step (operator spawns subagent). Prerequisite for a fully unattended loop.

### P4 — RTK integration: JEC compression via `rtk-v1`

**Goal**: the mailbox spec (§5) declares `X-JEC-Compression: rtk-v1` for 70–92% context reduction, but RTK is not yet installed on this host (`which rtk` → not found, per spec §14 caveat 6). Phase II installs RTK and wires it into the coordinator's outbound message construction.

**Concretely**:
- `brew install rtk && rtk init -g` on `minim4-24`.
- Add a `compress-jec` step to `coord-tick.nu`'s `state-dispatching` that pipes the `[brief]` and `context_pointers` content through `rtk read -l aggressive` before embedding in the envelope.
- Verify that a dispatched envelope is measurably smaller (token count or byte count) than the uncompressed equivalent.

**Acceptance**: a dispatched task envelope is >= 50% smaller (by byte count) than the raw context it summarizes; `X-JEC-Compression: rtk-v1` header present in the emitted mbox.

**Why fourth**: useful but not blocking for the thesis demo (degrading to raw output is the design intent per spec §5.2).

---

## 3. Phase II Success Criteria

Phase II is complete when all four of the following are met:

1. **Thesis demo verified**: at least one complete coord→subagent→reply round-trip with a `fleet-eval`-verified `[[claims]]` block exists in `var/mail/spool`. No operator intervention after the coordinator is started.

2. **Physical fleet deploy**: `FreeBSD-15-aarch64-smolbsd` running on a physical aarch64 board with SSH access and working `pkg install`. Board is one of: fbrpi, Pi 5, RK3588.

3. **Automated dispatch**: `nu bin/coord-tick.nu` with a pre-queued task spawns a subagent, harvests the reply, and transitions to DONE without manual subagent invocation.

4. **RTK installed + wired** (stretch goal; Phase II is not blocked on this): at least one dispatched envelope carries `X-JEC-Compression: rtk-v1` and a measurable size reduction.

---

*Authored by planner@smolbsd.local — task-0016 — 2026-05-04*
*In reply to coordinator@smolbsd.local message <task-0016.coord@smolbsd.local>*
