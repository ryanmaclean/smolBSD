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
| D-02: "SLIRP has no outbound internet at test time" → pre-bake tpm2-tools | FALSE for hosted runners — `.planning` 03-CONTEXT.md itself records a successful in-guest `pkg install tpm2-tools` over SLIRP (HTTP/HTTPS work; only ICMP doesn't), and run #6's boot gate shows dhclient DHCPACK | tpm2-tools evicted from the image (~15–30 MiB closure); tpm-hosted.yml installs it in-guest at test time, with a skip-if-present guard for pre-eviction artifacts |

## Image diet round 1 — VALIDATED: run #7 GREEN (2026-07-24)

**Run 30109365470, commit 0039c7c: raw 91 MiB (was 223 MiB), compressed
33 MiB shipped, boot gate TIME_TO_LOGIN=9s on the compressed image.**
Compress-step evidence: `raw_bytes=95682560 compressed_bytes=34275328`,
`qemu-img check` clean, `qemu-img compare` "Images are identical"; size
gate PASS at 32 MiB. The trims alone (pkg repo catalogs, tpm2-tools
closure, kernel symbols, static libs) cut ~130 MiB of raw — far above the
~35–60 MiB estimate, mostly the previously-unmeasured `/var/db/pkg/repos`
catalogs. The original sub-100 MiB raw target is MET; the download is
33 MB. The auto-chained TPM run (30122923572) went red exactly as
predicted pre-merge (main's copy predates the eviction — not a
regression; resolves on merge). The SIZEREPORT block is in the run's
`smolbsd-build-vm.log` artifact — parse with `nu bin/sizereport.nu` for
round-2 targeting. To publish: dispatch "Release smolBSD Image" with
run_id 30109365470.

Changes shipped together, validated by the run above:

1. **qcow2 compression on the runner** (`qemu-img convert -c`, default zlib —
   zstd would require qemu ≥ 5.1 in every consumer). The size gate, boot
   gate, and artifact now all use the compressed file; `qemu-img check` +
   `qemu-img compare` guard the replacement. **Raw bytes stay printed every
   run** — the size trend in this file and PHASE-1-RESULTS.md is tracked in
   raw bytes, and compression must not mask raw-image growth. Expected:
   ~100–130 MiB compressed from 223 MiB raw (run #6's 87 MB artifact zip
   proved ~2.5× whole-file deflate; per-cluster compression is slightly
   worse).
2. **tpm2-tools eviction** (D-02 retirement above).
3. **New trims**: `/boot/kernel/*.symbols|*.debug` (belt+braces, expected
   ~0), `/var/db/pkg/repos` + `repo-*.sqlite` (catalogs are re-fetchable;
   `local.sqlite` kept), recursive `/usr/lib` `*.a` sweep.
4. **SIZEREPORT instrumentation** at the end of `vm_extra_pre_umount`:
   du/largest-files/pkg-by-size printed into the in-VM make log
   (`smolbsd-build-vm.log` artifact); parse with `nu bin/sizereport.nu
   smolbsd-build-vm.log` (or raw: `grep '^SIZEREPORT:'`). This is
   the ground truth for round 2 (FreeBSD-utilities file-level cuts — the
   ~48 MiB grab-bag leaf with no narrower official replacement on pkgbase).

Deferred to later rounds (in rough value order): FreeBSD-utilities diet,
`WITHOUT_KERBEROS`-class src.conf knobs (blocked on the sshd/GSSAPI ldd
check above), dropping FreeBSD-vi, direct kernel boot dropping ESP+loader
(~35–40 MiB, the docs/UR-BSD.md next phase).

## Empirical results — hosted pipeline run #6: GREEN (2026-07-18)

**The scripted pipeline produced a gated smolBSD image end-to-end for the
first time.** Run 29637188773, commit bc852b7: buildworld+kernel ~3h,
cloudware-release ~5m, **size gate PASS** (<= 512 MiB; the whole artifact
zip incl. logs is 87 MB compressed), **boot gate PASS: TIME_TO_LOGIN=9s**
under KVM — serial log shows dhclient DHCPACK on vtnet0, syslogd, sshd,
cron, then the login prompt. FIX-1..FIX-10 all validated in one run.
Remaining from the original plan: aarch64 leg (cross-build + ARM-hardware
boot gate) and the T1-T6 TPM suite against this artifact.

## Empirical results — hosted pipeline runs #3-#4 (2026-07-18)

buildworld 1h50-3h10m (-j3) and buildkernel SMOLBSD **~2m**
(MODULES_OVERRIDE) both PASS. `make cloudware-release` exits 0 after ~10m —
**but exit 0 is NOT proof of an image**: the cw recipe ends in `|| true`,
and run #4 (with artifact-presence checking) proved no qcow2 was produced.
Run #3's failure at `first?` (fixed) masked the same underlying image-stage
failure. The real mk-vmimage.sh error lives in /var/tmp/smolbsd-build.log
inside the ephemeral VM — as of run #5 that log is always fetched and its
tail printed on failure, so the next cycle is self-diagnosing. Gates
(size/boot) still not reached.

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
