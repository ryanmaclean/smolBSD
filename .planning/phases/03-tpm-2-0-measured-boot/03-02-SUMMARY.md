---
phase: 03-tpm-2-0-measured-boot
plan: "02"
subsystem: ci
tags: [nushell, github-actions, tpm, ci, pop4090, self-hosted-runner, musl]

requires:
  - phase: 03-tpm-2-0-measured-boot
    provides: phase context, runner labels, Nushell install pattern from ci.yml

provides:
  - .github/workflows/tpm-vm-test.yml skeleton targeting pop4090-amd64 runner
  - Nushell v0.112.2 verified at /home/studio/.local/bin/nu on pop4090
  - 03-PREFLIGHT-NOTES.md documenting install verification

affects:
  - 03-06-PLAN.md (Wave 4 — fills in T1-T6 test suite using this skeleton)
  - any plan that references tpm-vm-test.yml

tech-stack:
  added: [nushell-0.112.2-musl-on-pop4090]
  patterns:
    - "Self-hosted runner Nushell install: curl musl tarball from github releases, extract to ~/.local/bin, append to GITHUB_PATH"

key-files:
  created:
    - .github/workflows/tpm-vm-test.yml
    - .planning/phases/03-tpm-2-0-measured-boot/03-PREFLIGHT-NOTES.md
  modified: []

key-decisions:
  - "Replace existing tpm-vm-test.yml (stock FreeBSD image smoke test) with skeleton targeting pop4090 runner — PLAN-06 fills in T1-T6"
  - "Nushell install uses x86_64-unknown-linux-musl binary (self-contained, no libc dep) — same pattern as ci.yml"
  - "curl from pop4090 to github.com/nushell releases succeeds — no fallback runner pre-install needed"

patterns-established:
  - "Nushell install pattern for self-hosted Linux runners: musl tarball via curl, extract to ~/.local/bin, echo to GITHUB_PATH"

requirements-completed: [TPM-CI-NUSHELL]

duration: 8min
completed: 2026-06-04
---

# Phase 3 Plan 02: TPM CI Skeleton — Nushell Install on pop4090 Summary

**tpm-vm-test.yml skeleton with Nushell v0.112.2 musl install step targeting pop4090-amd64 self-hosted runner, Nushell binary confirmed at /home/studio/.local/bin/nu**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-04T00:00:00Z
- **Completed:** 2026-06-04T00:08:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Created `.github/workflows/tpm-vm-test.yml` skeleton targeting pop4090-amd64 (`runs-on: [self-hosted, linux, amd64, kvm]`) with Nushell v0.112.2 install step
- Verified outbound curl from pop4090 to github.com/nushell releases works — no manual pre-install required
- Confirmed `/home/studio/.local/bin/nu --version` outputs `0.112.2` on pop4090 (10.0.2.42)
- Replaced the previous stock-FreeBSD smoke-test workflow with a clean skeleton that PLAN-06 will extend

## Task Commits

1. **Task 1: Create tpm-vm-test.yml skeleton with Nushell install** - `633a1c0` (feat)
2. **Task 2: Verify Nushell installs correctly on pop4090** - `ec960f6` (feat)

**Plan metadata:** (docs commit — see below)

## Files Created/Modified

- `.github/workflows/tpm-vm-test.yml` — New skeleton workflow: push+workflow_dispatch triggers, pop4090-amd64 runner, Nushell install, Show Nushell version, T1-T6 placeholder
- `.planning/phases/03-tpm-2-0-measured-boot/03-PREFLIGHT-NOTES.md` — SSH-verified install result: curl works from pop4090, nu 0.112.2 confirmed at ~/.local/bin/nu

## Decisions Made

- Replaced the existing tpm-vm-test.yml (stock FreeBSD 15.1-STABLE UFS image smoke test with fix-freebsd-vm.py) with a clean skeleton. The old smoke test served its purpose (confirmed swtpm+QEMU pipeline and /dev/tpm0 visibility); PLAN-06 will wire in the full T1-T6 suite against the smolBSD image.
- Used the same Nushell install pattern as ci.yml (musl tarball, curl from releases, ~/.local/bin) — no divergence between runner types.

## Deviations from Plan

None - plan executed exactly as written.

The existing `tpm-vm-test.yml` contained the old smoke test implementation (not a skeleton). The plan directed replacing it with the skeleton, which was the correct action.

## Issues Encountered

None. SSH to pop4090 succeeded, outbound curl to github.com/nushell releases worked on first attempt, nu binary installed and returned correct version.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- tpm-vm-test.yml skeleton is ready for PLAN-06 (Wave 4) to replace the placeholder step with the full T1-T6 test sequence
- Nushell is confirmed present on pop4090 — all `nu bin/*.nu` calls in subsequent CI steps will resolve
- Image path `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` (set by image build plans) is the next dependency

---
*Phase: 03-tpm-2-0-measured-boot*
*Completed: 2026-06-04*
