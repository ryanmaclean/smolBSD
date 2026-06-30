---
phase: 03-tpm-2-0-measured-boot
plan: "06"
subsystem: ci
tags: [freebsd, tpm2, swtpm, qemu, pcr, measured-boot, github-actions, ci]

requires:
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-04: T1-T6 acceptance tests all pass; bhyve-tpm-pcr-verify.nu fixed"
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-05: T5 live seal/unseal verdict=pass; OVMF pflash + key auth established"

provides:
  - ".github/workflows/tpm-vm-test.yml with complete T1-T6 test sequence (swtpm reset, QEMU boot, SSH gate, bhyve-tpm-pcr-verify.nu, job summary, cleanup)"

affects:
  - 03-07

tech-stack:
  added: []
  patterns:
    - "SSH key auth in CI: use --password '' with bhyve-tpm-pcr-verify.nu; rely on studio ed25519 key in guest /root/.ssh/authorized_keys (not password auth)"
    - "GitHub Actions env block for image path + SSH params: SMOLBSD_IMAGE, SWTPM_STATE, SSH_PORT, SSH_PASS"
    - "GITHUB_STEP_SUMMARY: tee T1-T6 TOML output for visible CI results without log diving"

key-files:
  created: []
  modified:
    - ".github/workflows/tpm-vm-test.yml — full T1-T6 test sequence replacing placeholder"

key-decisions:
  - "Used --password '' (key auth) in bhyve-tpm-pcr-verify.nu invocation: PLAN-05 confirmed PasswordAuthentication yes does not persist across guest reboots; studio ed25519 key is in /root/.ssh/authorized_keys, making key auth the reliable path."
  - "D-04 override retained as comment: run-vm-tests.nu --tpm uses step-tpm-device (nmdm console, FreeBSD-only) per RESEARCH.md Pitfall 1; bhyve-tpm-pcr-verify.nu is SSH-based and works on Linux/QEMU."

requirements-completed: [TPM-CI-UPDATE]

duration: 8min
completed: 2026-06-05
---

# Phase 3 Plan 06: Wire T1-T6 into tpm-vm-test.yml Summary

**Complete TPM CI workflow: tpm-vm-test.yml now runs the full T1-T6 acceptance suite (swtpm reset, QEMU+KVM boot, SSH gate, bhyve-tpm-pcr-verify.nu) on every push to the smolBSD repository.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-06-05T09:00:00Z
- **Completed:** 2026-06-05T09:08:00Z
- **Tasks:** 1 (Task 1: replace placeholder with full T1-T6 sequence)
- **Files modified:** 1 (.github/workflows/tpm-vm-test.yml)

## Accomplishments

- Replaced the placeholder step ("TPM test suite not yet wired — see PLAN-06") with the complete T1-T6 test sequence
- Workflow now: verifies image exists, resets swtpm, boots smolBSD with QEMU+KVM, waits for SSH, runs bhyve-tpm-pcr-verify.nu, reports results to job summary, cleans up
- All acceptance criteria verified: valid YAML, contains bhyve-tpm-pcr-verify.nu, smolbsd-amd64-tpm.qcow2, self-hosted+kvm runner, NU_VERSION 0.112.2, if: always() cleanup, GITHUB_STEP_SUMMARY, no fix-freebsd-vm, no step-tpm-device/tpm-attest.exp

## Task Commits

1. **Task 1 (wire T1-T6):** `84bb0c3` feat(03-06): wire T1-T6 TPM test sequence into tpm-vm-test.yml

## Files Modified

- `.github/workflows/tpm-vm-test.yml` — 82 lines added (replaced 2-line placeholder); full test sequence

## Decisions Made

- **Key auth instead of sshpass/password**: PLAN-05 found that `PasswordAuthentication yes` runtime fix does not persist across guest reboots. The studio@pop4090 ed25519 public key was added to `/root/.ssh/authorized_keys` in PLAN-05 and persists in the qcow2 image. Using `--password ""` in the bhyve-tpm-pcr-verify.nu invocation relies on key auth via the runner's ssh-agent.

- **D-04 override comment preserved**: The D-04 decision in CONTEXT.md originally specified `run-vm-tests.nu --tpm`. RESEARCH.md Pitfall 1 documented that `step-tpm-device` in that script uses nmdm console (FreeBSD-only, not available on Linux/QEMU). The workflow uses `bhyve-tpm-pcr-verify.nu` directly, with the override rationale documented in the workflow header comment.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] sshpass not needed — key auth is more reliable**
- **Found during:** Task 1 (writing SSH boot-gate and T1-T6 invocation)
- **Issue:** The plan template used `sshpass -p "$SSH_PASS"` for SSH commands, but PLAN-05 established that password auth is unreliable (not persisted across reboots) and key auth is in place.
- **Fix:** SSH boot-gate uses `ssh -o BatchMode=yes` (key auth); bhyve-tpm-pcr-verify.nu called with `--password ""` (triggers key auth path in the script's ssh-guest helper).
- **Files modified:** .github/workflows/tpm-vm-test.yml

## Known Stubs

None — the workflow is complete. The guest image's PasswordAuthentication + authorized_keys state is a runtime concern documented in PLAN-04/05, not a stub in this workflow.

## Self-Check: PASSED

- [x] `.github/workflows/tpm-vm-test.yml` — FOUND
- [x] Contains "bhyve-tpm-pcr-verify" — CONFIRMED (2 occurrences)
- [x] Contains "smolbsd-amd64-tpm.qcow2" — CONFIRMED
- [x] Does NOT contain "fix-freebsd-vm" — CONFIRMED (absent from run steps)
- [x] Contains "if: always()" — CONFIRMED (2 occurrences: report + cleanup)
- [x] Contains "GITHUB_STEP_SUMMARY" — CONFIRMED
- [x] Valid YAML (python3 yaml.safe_load) — CONFIRMED
- [x] Commit `84bb0c3` — FOUND

---
*Phase: 03-tpm-2-0-measured-boot*
*Completed: 2026-06-05*
