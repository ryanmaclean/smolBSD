# smolBSD — Current State

Updated: 2026-06-04

## Active phase

**Phase 3 — TPM 2.0 Measured Boot** (in progress)

## Phase 3 status

| Item | Status |
|------|--------|
| Kernel configs: `device tpm` in all four SMOLBSD configs | done |
| CI gate (pop4090 self-hosted runner): `/dev/tpm0 present` | green |
| `bin/swtpm-setup.nu` | done |
| `bin/bhyve-smolbsd.nu` | done |
| `tests/tpm-attest.exp` | done |
| `tests/tpm-seal-test.nu` | done |
| smolBSD image rebuilt with `device tpm` (T2–T6 full suite) | **pending** |
| `bin/bhyve-host-setup.nu` | pending |
| `bin/vultr-bhyve-provision.nu` | pending |
| Physical board (Pi 5 / RK3588) | Phase 4 |

The CI smoke test (`tpm-vm-test.yml`) uses a stock FreeBSD 15.1-STABLE UFS
image, not a built smolBSD image. `/dev/tpm0 present` via `kldload tpm`
confirms the swtpm+QEMU pipeline works. Full T2–T6 (PCR read, seal/unseal,
PCR mutation) requires a smolBSD image built with `device tpm` compiled in
and `tpm2-tools` present.

## Phase completion summary

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Minimal FreeBSD 15 amd64 + aarch64 QEMU VM images | complete |
| 2 | Physical board configs (Pi5, RK3588), bhyve harness, CI gate open | complete |
| 3 | TPM 2.0 measured boot — bhyve+swtpm | **in progress** |
| 4 | Physical fTPM (Pi5 RP1, RK3588 OP-TEE), remote attestation | not started |

## Coordinator FSM

The mbox+TOML coordinator (`bin/coord-tick.nu`) manages agent handoffs.
Active user stories from `prd.json`:

| Story | Title | Status |
|-------|-------|--------|
| S-001 | Enforce spool message attestation checks | passes |
| S-002 | Per-task halt and resume handling | failing |
| S-003 | Bounded retry policy with escalation | failing |
| S-004 | Capability gate checks during dispatch | failing |
| S-005 | Deterministic state transition telemetry | failing |
