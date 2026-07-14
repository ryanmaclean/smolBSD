# ur-BSD — closing the gap from 1.41 GiB to the 512 MiB gate (and below)

Status note, 2026-06-12. Companion to `docs/PHASE-1-RESULTS.md`.

## Framing

The ur-BSD question is "what is the irreducible kernel of BSD-ness?" — and
history answered it once already: PicoBSD booted FreeBSD off a 1.44 MB floppy
in 1998 (kernel, init, sh, login). Everything since is accretion. The 512 MiB
gate is therefore a waypoint, not a destination; the honest floor for a
QEMU-only FreeBSD 15 guest is a ~10 MB stripped kernel, a small dynamic
userland, and a qcow2 well under 100 MiB.

Prior art worth knowing:

- **PicoBSD** (1998) — the original existence proof.
- **OccamBSD** (Michael Dexter) — modern "subtract until it breaks" FreeBSD;
  gets a bootable system into the tens-of-MB range.
- **NetBSD smolBSD** (this repo's namesake) — sub-second boots into
  Firecracker-style microVMs via direct kernel boot and MFS root.
- **pkgbase in FreeBSD 15** — base is ~400 packages instead of one monolith,
  so minimization is a package-set problem, not a `WITHOUT_*` archaeology dig.

## Why the Phase 1 image was 1.41 GiB

Analysis of the build inputs (not yet a mounted-image audit — run
`bin/analyze-image.sh` on the next artifact to confirm proportions):

1. **`VMSIZE=4g` override.** Both `release/tools/smolbsd-qemu*.conf`
   unconditionally exported `VMSIZE=4g` / `SWAPSIZE=512m`. Because
   `mk-vmimage.sh` sources the conf *after* parsing `-s`, this silently
   defeated the pipeline's `VMSIZE=2g` (FIX-3 in `bin/build-smolbsd.nu`) —
   matching the "virtual 4 GiB sparse / 3551 MB rootfs" layout recorded in
   PHASE-1-RESULTS.
2. **Full kernel module set.** Neither SMOLBSD kernconf set
   `MODULES_OVERRIDE`, so every buildable module (~800 of them — wireless,
   GPU, storage controllers the kernel itself `nodevice`s) shipped in
   `/boot/kernel`. This is the single largest avoidable chunk in a
   non-debug image.
3. **pkgbase filter gaps.** lld, dtrace, zfs (UFS root — zfs is dead
   weight), rescue, games, sendmail, telnet were all installed.
4. **size-trim gaps.** `/boot/firmware` (wireless firmware blobs),
   `/rescue`, `/usr/lib/clang`, `/usr/share/{i18n,dict,games,sendmail,openssl}`,
   and `/var/db/etcupdate` survived the trim.

## Changes made (this branch)

| File | Change |
|---|---|
| `sys/arm64/conf/SMOLBSD`, `sys/amd64/conf/SMOLBSD` | `MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` — only modules the VM can load; everything else is compiled in |
| `release/tools/smolbsd-qemu-aarch64.conf`, `smolbsd-qemu.conf` | `VMSIZE`/`SWAPSIZE` now respect the caller (`${VMSIZE:-2g}`); pkgbase filter replaced by an explicit leaf-package list (FIX-10 — see UR-BSD-VERIFY.md Finding 4); size-trim extended (firmware, rescue, clang runtime, share/* leftovers, etcupdate db) |
| `bin/build-smolbsd-image.nu` | in-VM release step now `cloudware-release` + `SMOLBSDCONF=` with `VMSIZE=2g` (was `vm-image ... CLOUDWARE_CONF=` at 4g — see FIX-9 in UR-BSD-VERIFY.md) |

Notes on safety:

- `MODULES_OVERRIDE` keeps tmpfs/nullfs/fdescfs/procfs as loadable modules
  because rc and common tooling auto-load them on mount; all storage, net,
  console, and TPM support is compiled into the kernel via `std.virt` /
  `MINIMAL` plus explicit `device` lines.
- The pkgbase filter is an explicit leaf-package allowlist (FIX-10): the old
  `grep -v` could never exclude set dependencies. The failure mode is now
  fail-closed — a listed-but-missing package breaks `pkg install` visibly,
  and an omitted one drops functionality; see UR-BSD-VERIFY.md Finding 4.
- The physical-board configs (`SMOLBSD-PI5`, `SMOLBSD-RK3588`,
  `smolbsd-pi5.conf`, `smolbsd-rk3588.conf`) are deliberately untouched —
  boards need real driver modules and firmware.

## What's next (in descending value)

1. **Rebuild on <aarch64-builder> and run `bin/analyze-image.sh`** against the new
   artifact; the report's top-30 lists will show what's still heavy.
2. **Direct kernel boot** (QEMU `-kernel`, skip EFI/loader): removes the
   32 MB EFI partition and most of the 11 s boot time. The NetBSD smolBSD
   approach.
3. **MFS/ramdisk root** for the true ur-image: makefs a tiny UFS into the
   kernel, qcow2 becomes optional.
4. **Treat minimization as a search problem**: let the coordinator drive
   "smallest package set that still passes the boot+login gate" — gates as
   the fitness function, agents doing the subtraction.
