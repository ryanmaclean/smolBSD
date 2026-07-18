# ur-BSD — verification runbook for the next FreeBSD build host session

Companion to `docs/UR-BSD.md`. This is the plan to execute **when a FreeBSD 15
build host is available again** (<aarch64-builder> for aarch64; a Linux/KVM x86 host for
amd64). It records what was changed in PR #31 (branch
`claude/ur-bsd-26-qnmjho` at the time; read this doc from main), what was
verified without a build, and the ordered steps to validate — including one
likely latent bug that must be confirmed before trusting the build scripts.

## State of the branch

The ur-bsd changes merged via PR #30 + the fixes below. All changes are repo-side;
**none have been run on a FreeBSD host.** The Linux container this work was done
in cannot build a FreeBSD image.

| Change | File(s) | Verified? |
|---|---|---|
| `MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` | `sys/{arm64,amd64}/conf/SMOLBSD` | Logic reviewed against `releng/15.0` |
| `options FFS` added (amd64 only) | `sys/amd64/conf/SMOLBSD` | **Required fix — see Finding 2** |
| `VMSIZE`/`SWAPSIZE` respect caller (`${VMSIZE:-2g}`) | `release/tools/smolbsd-qemu*.conf` | Mechanism verified TRUE |
| pkgbase filter: grep replaced by explicit leaf-package list (FIX-10) | `release/tools/smolbsd-qemu*.conf` | Names verified vs pkg.freebsd.org 15 catalogs; see Finding 4 |
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

Same class, second instance (found in review): `vmimage.subr` appends a
`/dev/gpt/efiboot0 /boot/efi msdosfs` line to fstab AFTER `vm_extra_pre_umount`
runs, and amd64 MINIMAL has no `options MSDOSFS` — with the module set
stripped, `mount -a` fails at boot and rc drops to single-user. Fixed by
adding `options MSDOSFS` to the amd64 kernconf (arm64 has it via std.arm64).

The four override modules (tmpfs/nullfs/fdescfs/procfs) are not actually needed
to reach login (no fstab mounts them), but are cheap, conservative insurance.

### Finding 3 — the build scripts never sourced the conf (CONFIRMED — FIX-9 applied)
`make -C /usr/src/release vm-image ... CLOUDWARE_CONF=<conf>` — the old
invocation in `bin/build-smolbsd.nu` and `bin/build-smolbsd-image.nu` — did
**not** source the conf:
- `CLOUDWARE_CONF` is not a real variable in `release/Makefile.vm`; the
  per-type variable is `${TYPE}CONF` (`SMOLBSDCONF` for `CLOUDWARE=smolbsd`).
- Only `cw-*` cloudware targets pass `-c <conf>` to `mk-vmimage.sh`. The plain
  `vm-image` target passes no `-c`, and its recipe is gated behind
  `WITH_VMIMAGES` (without it the recipe is a no-op `touch`).
- Consequence: `vm_extra_pre_umount()` (SSH keygen + size-trim) and
  `vm_extra_filter_base_packages()` stayed as no-op prototypes via this path.

Confirmation came from the repo's own history, not just the mirror review: the
`.planning/phases/03-*` records and `.github/workflows/build-image.yml` show the
prior self-hosted CI builds succeeded with `cloudware-release` + `CLOUDWARE=smolbsd` +
`SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs` (generating `cw-smolbsd-ufs-qcow2`,
artifact at `<objdir>/usr/src/release/vm.ufs.qcow2`) — while still passing the
fake `CLOUDWARE_CONF`, meaning even those builds never sourced the conf. And
`PHASE-1-RESULTS.md` records the Phase-1 aarch64 image was created **manually**
(`makefs` + `mkimg`), so the scripted path was never validated end-to-end.

**FIX-9 (applied on this branch):** all build invocations now use
`cloudware-release` with `WITH_CLOUDWARE=yes CLOUDWARE=smolbsd
SMOLBSDCONF=<conf> SMOLBSD_FORMAT=<fmt> SMOLBSD_FSLIST=ufs`, in:
`bin/build-smolbsd.nu` (+ `find_qcow2` objdir-root candidates),
`bin/build-smolbsd-image.nu`, `.github/workflows/build-image.yml`
(`CLOUDWARE_CONF` → `SMOLBSDCONF`), `bin/harvest.sh` (remote paths, now
env-overridable), the four conf headers, README/BUILDING docs.

### Finding 4 — the pkgbase grep filter was structurally a no-op (FIX-10 applied)
Verified against `releng/15.0` `vmimage.subr` and the official
`pkg.freebsd.org FreeBSD:15 base_release_0` catalogs (496 pkgs): the stock flow
passes only the `FreeBSD-set-*` meta names through
`vm_extra_filter_base_packages()` — on releng/15.0 for amd64/aarch64 that is
six: base, kernels, lib32, each with a `-dbg` twin (`vm_base_packages_list`,
vmimage.subr:73–87) — then `pkg install -r FreeBSD-base $selected` pulls each
surviving set's full dependency closure. `grep -v` of individual names can
never exclude a set dependency — the old filter silently shipped clang
(~220M), zfs, dtrace, rescue, wpa/ppp/wifi-firmware, and the tests packages
via set dependencies. ZFS userland is fully confined to `FreeBSD-zfs*`
packages, but the surviving sets hard-depend on them, so only an explicit
package list excludes it.

**FIX-10 (applied on this branch):** both QEMU confs now emit an explicit
leaf-package list (kernel set, bootloader, clibs/runtime/rc/utilities, ufs,
geom, ssh, dhclient, resolvconf, syslogd/newsyslog/cron/devd,
caroot/certctl/pkg-bootstrap, vi); pkg resolves required libraries as
dependencies. The custom-KERNCONF risk is RETIRED: `release/packages/
create-sets.sh` builds set membership dynamically from the `set` annotations
of the packages actually present in the repo, so a `KERNCONF=SMOLBSD` build
yields a `FreeBSD-set-kernels` depending on the SMOLBSD kernel package.
Remaining watch item on first build: confirm sshd's kerberos/GSSAPI libs
arrive as declared dependencies of `FreeBSD-ssh` (expected; check
`ldd /usr/sbin/sshd` in the image). The pi5/rk3588 confs were left on the old
filter deliberately (boards need `FreeBSD-dtb`; fix separately once the VM
path is proven).

## Assumptions retired (verification pass against releng/15.0 sources)

Every FIX-9/FIX-10 assumption was checked directly against
`raw.githubusercontent.com/freebsd/freebsd-src/releng/15.0`:

| Assumption | Verdict | Action taken |
|---|---|---|
| `cloudware-release` exists and needs `WITH_CLOUDWARE` + non-empty `CLOUDWARE` | TRUE (Makefile.vm:112, 307–311; empty target otherwise) | We pass both; also added `WITH_CLOUDWARE=yes` to build-image.yml |
| Per-type conf var is `SMOLBSDCONF`; must be passed explicitly | TRUE (`${_CW:tu}CONF`; auto-default only if `tools/smolbsd.conf` exists — it doesn't) | Passed explicitly everywhere |
| `-s ${VMSIZE}` / `SWAPSIZE` reach mk-vmimage on the cw path | TRUE (Makefile.vm:141, 156) | Conf `${VMSIZE:-2g}` pattern correct as-is |
| Artifact basename | `smolbsd.ufs.qcow2` in release objdir root (`${_CW:tl}.${_FS}.${_FMT}`, Makefile.vm:124) — `vm.ufs.qcow2` seen in prior self-hosted CI runs is that tree's stable/15 naming | harvest.sh default updated; workflow ls/scp made glob-tolerant; find_qcow2 already globs |
| `WITH_PKGBASE=yes` selects pkgbase | FALSE — no such release variable; pkgbase is the DEFAULT, `NOPKGBASE=yes` opts out (vmimage.subr:98) | Removed from all invocations and headers |
| cw target self-builds the pkgbase repo | TRUE — depends on `pkgbase-repo-dir` → `make -C /usr/src packages` (release/Makefile:218–229), which requires buildworld | Added the missing buildworld step to `bin/build-smolbsd-image.nu` |
| `FreeBSD-set-kernels` works with custom KERNCONF | TRUE — sets are generated from package `set` annotations at repo-build time (create-sets.sh) | Watch item removed |
| Workflow header "NOPKGBASE skips tpm2-tools" | FALSE — `vm_extra_install_packages` chroot-installs `VM_EXTRA_PACKAGES` regardless of NOPKGBASE (only `WITHOUT_QEMU` skips it, vmimage.subr:205–247) | Header corrected; `NOPKGBASE=yes` kept in the proven pipeline |
| Conf-provided builds get DHCP/growfs defaults | N/A — `vm_extra_enable_services` adds `ifconfig_DEFAULT`/`growfs_enable` only when NO conf is passed (vmimage.subr:195–201); our conf sets `ifconfig_vtnet0="DHCP"` itself | No change needed (noted so nobody "fixes" it) |

## Ordered plan for the build host

1. **Spot-check FIX-9 spelling against the host's tree** (5 minutes, read-only):
   `grep -n 'CONF\b\|cw-\|CLOUDWARE' /usr/src/release/Makefile.vm | head -40` —
   confirm `cloudware-release` exists, the per-type variable is `${TYPE}CONF`
   (→ `SMOLBSDCONF`), and whether the type list variable is `CLOUDWARE` or
   `CLOUDWARE_TYPES` on this tree. Then dry-check the target:
   `make -C /usr/src/release -V CLOUDWARE_TYPES -V VMSIZE CLOUDWARE=smolbsd` .
   FIX-9 is already applied to the scripts with the CI-proven spelling;
   this step only guards against releng-branch drift.
2. **Build via pipeline or host.** Preferred: dispatch
   `.github/workflows/build-image-hosted.yml` (GitHub-hosted runner, KVM,
   no manual host needed — builds, size-gates, and boot-gates amd64
   end-to-end; cross-builds aarch64). Manual alternative: on a FreeBSD host,
   `sudo nu bin/build-smolbsd.nu --arch <arch>`, streaming
   `/var/tmp/smolbsd-build.log`.
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
6. **amd64** on a Linux/KVM host via `bin/build-smolbsd-image.nu`, then
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
