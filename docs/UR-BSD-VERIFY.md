# ur-BSD — verification runbook for the next FreeBSD build host session

Companion to `docs/UR-BSD.md`. This is the plan to execute **when a FreeBSD 15
build host is available again** (fbuild for aarch64; a Linux/KVM x86 host for
amd64). It records what was changed on branch `claude/ur-bsd-26-qnmjho`, what was
verified without a build, and the ordered steps to validate — including one
likely latent bug that must be confirmed before trusting the build scripts.

## State of the branch

Commit `4e077df` (Fable session) + the FFS fix below. All changes are repo-side;
**none have been run on a FreeBSD host.** The Linux container this work was done
in cannot build a FreeBSD image.

| Change | File(s) | Verified? |
|---|---|---|
| `MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` | `sys/{arm64,amd64}/conf/SMOLBSD` | Logic reviewed against `releng/15.0` |
| `options FFS` added (amd64 only) | `sys/amd64/conf/SMOLBSD` | **Required fix — see Finding 2** |
| `VMSIZE`/`SWAPSIZE` respect caller (`${VMSIZE:-2g}`) | `release/tools/smolbsd-qemu*.conf` | Mechanism verified TRUE |
| pkgbase filter widened (lld, dtrace, zfs, rescue, games, sendmail, telnet) | `release/tools/smolbsd-qemu*.conf` | `grep -v` — safe no-op if absent |
| size-trim widened (firmware, rescue, clang, share/*, etcupdate) | `release/tools/smolbsd-qemu*.conf` | Safe `rm -rf` with DESTDIR guard |
| in-VM make `VMSIZE=2g` (was 4g) | `bin/build-smolbsd-image.nu` | — |

## Findings from source review (releng/15.0)

### Finding 1 — VMSIZE override was a real bug; the fix is correct (VERIFIED)
In `release/scripts/mk-vmimage.sh`, `-s <size>` is parsed by `getopts` into the
shell var `VMSIZE`, then the conf is sourced (`. "${VMCONFIG}"`) *before* VMSIZE
is consumed in `vm_create_disk()` (`vmimage.subr`, `MAKEFSARGS="-s ${VMSIZE} -D"`).
An unconditional `export VMSIZE=4g` in the conf therefore clobbered the
command-line `2g`. The fix `export VMSIZE="${VMSIZE:-2g}"` preserves the
caller's value. Correct, not a no-op, not harmful.

### Finding 2 — amd64 MODULES_OVERRIDE would panic at mountroot (FIXED HERE)
`sys/amd64/conf/SMOLBSD` does `include MINIMAL`, and **amd64 MINIMAL ships
UFS/FFS as a loadable module (`ufs.ko`), not compiled in.** With
`MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` stripping the module set and no
`ufs_load="YES"` in loader.conf, the kernel could not mount its UFS root →
mountroot panic. **Fix applied:** added `options FFS` to the amd64 kernconf.
arm64 is unaffected — `std.arm64` already compiles `options FFS` in.
(virtio/vtnet/ahci/nvme are statically compiled in both arches — confirmed — so
the device side is fine; only the filesystem driver was the gap.)

The four override modules (tmpfs/nullfs/fdescfs/procfs) are not actually needed
to reach login (no fstab mounts them), but are cheap, conservative insurance.

### Finding 3 — the build scripts likely never source the conf (UNCONFIRMED — verify first)
A source review concluded that `make -C /usr/src/release vm-image ...
CLOUDWARE_CONF=<conf>` — the invocation in `bin/build-smolbsd.nu` and
`bin/build-smolbsd-image.nu` — does **not** source the conf:
- `CLOUDWARE_CONF` is not a real variable in `release/Makefile.vm`; the
  per-provider variable is `${TYPE}CONF` (e.g. `EC2CONF`).
- Only `cw-*` cloudware targets pass `-c <conf>` to `mk-vmimage.sh`. The plain
  `vm-image` target passes no `-c`, and its recipe is gated behind
  `WITH_VMIMAGES`.
- Consequence: `vm_extra_pre_umount()` (SSH keygen + size-trim) and
  `vm_extra_filter_base_packages()` would stay as no-op prototypes — so the
  trim/filter changes in the confs would have **no effect** via this path.

This is consistent with `PHASE-1-RESULTS.md`, which states the Phase-1 image was
created **manually** (`makefs` + `mkimg`), not via the scripted target. So the
scripts may never have been validated end-to-end.

**Caveat on confidence:** this review used the GitHub source mirror (canonical
cgit was bot-gated), so confirm against the real `/usr/src` tree on the build
host before acting. Candidate correct invocation to test:
```sh
make -C /usr/src/release cw-basic-cloudinit-ufs-qcow2 \
    WITH_CLOUDWARE=yes CLOUDWARE=BASIC-CLOUDINIT \
    BASIC-CLOUDINITCONF=$PWD/release/tools/smolbsd-qemu-aarch64.conf \
    KERNCONF=SMOLBSD WITH_PKGBASE=yes VMSIZE=2g VMFORMATS=qcow2
```
(exact target/variable names must be read from this host's
`release/Makefile.vm`).

## Ordered plan for the build host

1. **Confirm Finding 3 against the real tree.** On the host:
   `grep -n CLOUDWARE_CONF /usr/src/release/Makefile.vm` (expect: no match) and
   `grep -n 'mk-vmimage.sh' /usr/src/release/Makefile.vm` to see which targets
   pass `-c`. Read the `cw-*` target list and the `${TYPE}CONF` variable name.
   Decide: either (a) switch `bin/build-smolbsd.nu` to the correct `cw-*` target,
   or (b) set `WITH_VMIMAGES=yes` and patch the conf-sourcing in, or (c) keep the
   manual makefs+mkimg path Phase 1 used and stop pretending the scripted target
   works. Update the build scripts to match reality.
2. **Build aarch64 on fbuild** with the corrected invocation:
   `sudo nu bin/build-smolbsd.nu --arch aarch64` (after step 1's fix).
   Stream `/var/tmp/smolbsd-build.log`.
3. **Run the size audit** on the artifact: `sh bin/analyze-image.sh <qcow2>`.
   Capture the top-30 dir/file lists and the budget delta. This is the ground
   truth that replaces all the estimation above.
4. **Boot gate:** `expect tests/time-to-ready-arm64.exp` — confirm login ≤ 30s
   and that sshd comes up (the MODULES_OVERRIDE + FFS changes are validated here:
   a mountroot panic or missing-module failure shows up immediately on serial).
5. **Attribute the savings.** Compare against the 1.41 GiB Phase-1 baseline and
   record per-change deltas (VMSIZE 2g vs 4g; module strip; pkg filter; trim) in
   `docs/PHASE-1-RESULTS.md`. If still over 512 MiB, the analyze-image report
   names the next targets.
6. **amd64** on a Linux/KVM host via `bin/build-smolbsd-image.nu` (after the
   step-1 fix is mirrored into that script's in-VM make line), then
   `bin/analyze-image.sh` + `tests/time-to-ready-amd64-tcg.exp` (or KVM gate).
7. **Then pursue the sub-100 MiB ur-image** per `docs/UR-BSD.md`: direct kernel
   boot (`-kernel`, drop EFI partition), MFS/ramdisk root, and coordinator-driven
   "smallest package set that still passes the gate."

## Rollback criteria
- If aarch64 fails to boot after the module strip: check serial for missing-module
  or mountroot errors; if a needed `.ko` was stripped, add it to MODULES_OVERRIDE
  (or compile the device in) rather than reverting the whole change.
- If the image is not smaller despite a clean build: Finding 3 is the cause — the
  conf was not sourced; fix the invocation (step 1) and rebuild.
