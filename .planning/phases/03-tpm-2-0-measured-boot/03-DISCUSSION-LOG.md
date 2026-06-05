# Phase 3: TPM 2.0 Measured Boot — Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-04
**Phase:** 03-tpm-2-0-measured-boot
**Mode:** auto (--auto flag; all options auto-selected from recommended defaults)
**Areas discussed:** Image Build Strategy, tpm2-tools Inclusion, CI Integration, T2–T6 Test Execution, fix-freebsd-vm.py applicability

---

## Image Build Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| FreeBSD QEMU VM on pop4090 | Boot a FreeBSD VM on pop4090, clone smolBSD repo, run `make release` inside | ✓ |
| fbuild via SSH | SSH to the existing fbuild host (was saturated/unavailable in prior sessions) | |
| Hetzner ccx23 | Cloud AMD-V instance provisioned by `bin/smolbsd.nu provision hetzner` (needs HCLOUD_TOKEN) | |

**Auto-selected:** FreeBSD QEMU VM on pop4090 — pop4090 has `/home/studio/bsd-build/src/freebsd-src` with postworld artifacts, KVM, and all tooling in place. No external dependencies.

---

## tpm2-tools Inclusion

| Option | Description | Selected |
|--------|-------------|----------|
| Bake into release conf (vm_extra_install_packages) | Pre-install during `make release`; image ships ready | ✓ |
| pkg install at test time via SSH | Requires working SLIRP + DHCP + pkg bootstrap; fragile | |
| Manually copy binaries into image | Complex; breaks pkg dependency tracking | |

**Auto-selected:** Bake into release conf. Avoids the SLIRP/DHCP issue at test time entirely.

**Note on SLIRP:** FreeBSD under QEMU SLIRP only has internet if `ifconfig_vtnet0="DHCP"` is in rc.conf. The smolBSD release conf sets this, so `make release` CAN run `pkg` during the image build phase. This is different from the CI test phase where we avoid pkg completely. (FreeBSD Handbook §4.3 + SLIRP docs referenced by docs-first hook during session.)

---

## CI Integration

| Option | Description | Selected |
|--------|-------------|----------|
| pop4090 local path | Store built image at stable local path; CI references it directly | ✓ |
| GitHub Releases artifact | Upload to GH releases; download in CI | |
| Rebuild in every CI run | `build-image.yml` triggers on every push; slow (1-2h per build) | |

**Auto-selected:** pop4090 local path — runner has direct filesystem access, avoids multi-gigabyte downloads on every run. SHA256 manifest tracks freshness.

---

## T2–T6 Test Execution

| Option | Description | Selected |
|--------|-------------|----------|
| Existing test scripts (bhyve-tpm-pcr-verify.nu + tpm-seal-test.nu + tpm-attest.exp) | All T1–T6 already implemented per the Phase 3 spec | ✓ |
| Inline SSH commands in tpm-vm-test.yml | Simpler YAML but duplicates logic already in .nu scripts | |
| New unified test runner script | Would need to be written from scratch | |

**Auto-selected:** Existing test scripts — `tests/bhyve-tpm-pcr-verify.nu` already implements T1–T6 per the spec in `plans/tinyos/PHASE-3-TPM.md`. `bin/run-vm-tests.nu --tpm` orchestrates them.

---

## fix-freebsd-vm.py Applicability

| Option | Description | Selected |
|--------|-------------|----------|
| Not needed for real smolBSD image | smolBSD conf bakes in sshd_keygen_enable=NO, XMSS removal, PermitRootLogin | ✓ |
| Keep as fallback for debugging | Useful if testing with stock FreeBSD UFS images | |

**Auto-selected:** Not needed for real image. Document it as stock-image-only utility.

---

## Claude's Discretion

- Exact QEMU flags for smolBSD image run (memory, CPU count, accel)
- swtpm state directory path on pop4090 for CI runs
- T3 fallback: if `tpmctl(8)` is absent, use `tpm2_getcap properties-fixed`
- bhyve vs QEMU choice for T2–T6 suite (QEMU preferred: already validated)

## Deferred Ideas

- Physical board (Pi5, RK3588) TPM — Phase 4
- Remote attestation / TPM quotes — Phase 4  
- aarch64 QEMU TPM (ControlArea=0 blocker) — needs hardware
