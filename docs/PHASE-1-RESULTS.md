# Phase I Results

## aarch64 (primary leg)
- Build host: fbuild (FreeBSD 15.0-RELEASE-p5 arm64, QEMU on minim4-24)
- Kernel: VIRT-MINIMAL (SMOLBSD config), exit=0, 12MB staged
- Buildworld + release: exit=0 (dist stage complete 2026-05-07)
- qcow2 sha256: 709fbab6c327e6026b0aa4fd197965ccfcaa0c6f0c2c377f7afbd6ff8a0b292f
- qcow2 size: 1.41 GiB (1509359616 bytes), virtual 4 GiB sparse
- qcow2 path (fbuild): /tmp/smolbsd-out/FreeBSD-15-aarch64-smolbsd.qcow2
- qcow2 path (local): build/FreeBSD-15-aarch64-smolbsd.qcow2
- Time-to-login: 11s (gate: <=30s) — PASS
- EDK2 firmware: edk2-aarch64-code.fd (64MB, sourced from minim4-24)
- Date: 2026-05-07

### Build notes
- `make release` ran buildworld + dist stage successfully (exit=0)
- vm-image created manually: makefs (UFS) + mkimg (GPT/qcow2) on fbuild
- Disk layout: EFI/efiboot0 (32MB FAT32) + swap/swapfs (512MB) + ufs/rootfs (3551MB)
- Known issues: /etc/login.conf ownership warning (world/group write); sshd
  precmd fails due to /var/empty ownership — cosmetic, login prompt unaffected
- Test fixes: removed `-serial stdio` from expect script (conflicts with -nographic
  in QEMU 10.x); qcow2 path updated to build/ subdir; Nu string interpolation
  fix for `(<= 30s)` token

### Test results (2026-05-07)
```
=== Test Results: 7 pass / 0 fail / 0 skip ===
  [pass] parse-mbox: message count
  [pass] msg-id: first message
  [pass] msg-id: second message
  [pass] extract-toml: first message body
  [pass] extract-toml: nested TOML table
  [pass] extract-toml: empty body error
  [pass] e2e-aarch64: TIME_TO_LOGIN=11s — gate: <=30s PASS
```

## amd64 (secondary leg)
- Build host: Vultr vc2-4c-8gb (140.82.9.132)
- Status: buildworld in progress (WITHOUT_DEPEND_FILES=yes restart)
- ETA: ~4-6hr
