# smolBSD — Roadmap

Campaign: **smolBSD — The Tiny Realm vs The Rump Citadel**

Build the smallest stable FreeBSD VM that boots unattended in ≤ 30 seconds,
fits under 512 MiB (target: < 128 MiB qcow2), and proves Claude agents can
hand off a long-running build project via BSD mbox + TOML with no shared
conversation history.

---

## Phase 1: Forge Tiny Baseline — COMPLETE

Minimal FreeBSD 15.0-RELEASE amd64 + aarch64 QEMU VM images.

**Exit gates (both arches):**
- `buildkernel` exit 0
- qcow2 artifact produced, size < 512 MiB
- Time to login prompt ≤ 30 s
- Host RSS idle < 300 MiB; in-VM free ≥ 150 MiB
- Crash recovery ≤ 60 s

**Key files:** `sys/amd64/conf/SMOLBSD`, `sys/arm64/conf/SMOLBSD`,
`release/tools/smolbsd-qemu.conf`, `release/tools/smolbsd-qemu-aarch64.conf`

---

## Phase 2: Fleet Deploy + Coord Wiring — COMPLETE

Physical board configs, bhyve harness, coordinator FSM dispatch wired.

**Delivered:**
- aarch64 image boots on Pi 5 (SMOLBSD-PI5) and RK3588 (SMOLBSD-RK3588)
- `bin/coord-tick.nu` FSM: idle → dispatching → waiting → harvesting → halted
- mbox+TOML spool protocol with attestation enforcement
- CI gate on GitHub Actions (ubuntu-latest + macos-latest)
- End-to-end coord → subagent → reply round-trip demonstrated

---

## Phase 3: TPM 2.0 Measured Boot — IN PROGRESS

TPM 2.0 measured boot and local attestation via QEMU + swtpm on amd64.

**Scope:** build smolBSD image with `device tpm` compiled in, install
`tpm2-tools`, and validate the full T1–T6 acceptance suite inside a QEMU VM
backed by swtpm on pop4090 (Ryzen 9 7950X, KVM) before any hardware dependency.

**Acceptance gates (T1–T6):**
- T1: swtpm socket appears within 3 s ✅ (CI green)
- T2: smolBSD guest boots with `/dev/tpm0` present (needs real smolBSD image)
- T3: `tpmctl -G` returns TPM 2.0 manufacturer info
- T4: PCR 0 readable, non-zero, stable
- T5: seal/unseal round-trip with PCR 0+7 policy
- T6: PCR value changes after `tpm2_pcrextend`

**Already done:**
- kernel configs (`device tpm` in all SMOLBSD configs)
- swtpm setup scripts, bhyve harness, test scripts
- CI smoke test on pop4090 (self-hosted runner, `/dev/tpm0 present` = green)
- `bin/fix-freebsd-vm.py`, `bin/build-smolbsd-image.nu`, `.github/workflows/tpm-vm-test.yml`

**Remaining:**
- Build smolBSD amd64 image with `device tpm` + `tpm2-tools` in package set
- Run full T2–T6 suite on pop4090 QEMU
- Update CI to use real smolBSD image instead of stock FreeBSD

**Key files:** `bin/swtpm-setup.nu`, `bin/bhyve-smolbsd.nu`, `bin/qemu-smolbsd.nu`,
`tests/tpm-attest.exp`, `tests/tpm-seal-test.nu`, `tests/tpm-smoke-test.nu`,
`.github/workflows/tpm-vm-test.yml`, `plans/tinyos/PHASE-3-TPM.md`,
`bin/build-smolbsd-image.nu`, `release/tools/smolbsd-qemu.conf`

---

## Phase 4: Physical fTPM + Remote Attestation — NOT STARTED

Physical board TPM via Pi 5 RP1 fTPM (RPi UEFI) and RK3588 ARM TrustZone
+ OP-TEE fTPM TA. Remote attestation protocol (TPM quote + verifier service).

**Prerequisites:** Phase 3 T1–T6 all pass. OP-TEE license audit complete.

---

## Coordinator stories backlog

Open FSM user stories (see `prd.json`):

| Priority | Story | Title |
|----------|-------|-------|
| P2 | S-002 | Per-task halt and resume handling |
| P3 | S-003 | Bounded retry policy with escalation |
| P4 | S-004 | Capability gate checks during dispatch |
| P5 | S-005 | Deterministic state transition telemetry |
