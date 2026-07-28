#!/bin/sh
# build-smolfire.sh — build the SMOLFIRE microVM kernel with embedded
# rescue MFS root. Runs INSIDE the FreeBSD 15 build VM as root.
#
# Output: /root/smolfire-kernel (PVH-bootable ELF, the entire OS)
# Log:    /var/tmp/smolfire-build.log
#
# SPDX-License-Identifier: Apache-2.0
set -eu

SRC=/usr/src
# RESCUE_SRC and ROOT are env-overridable so the rootfs-assembly section
# (pure POSIX sh) can run — and be tested — outside the FreeBSD build VM.
RESCUE_SRC=${RESCUE_SRC:-/rescue/rescue}
ROOT=${ROOT:-/root/smolfire-root}
IMG=/root/smolfire-mfs.img
OUT=/root/smolfire-kernel
LOG=/var/tmp/smolfire-build.log

# --rootfs-only: stop after the rootfs is assembled, before the
# FreeBSD-only makefs/buildkernel steps (lets CI test assembly on Linux).
ROOTFS_ONLY=no
if [ "${1:-}" = "--rootfs-only" ]; then
    ROOTFS_ONLY=yes
fi

RESCUE_DIR=$(dirname "$RESCUE_SRC")
echo "==> rootfs: static /rescue crunchgen userland ($(du -sh "$RESCUE_DIR" | cut -f1))"
rm -rf "$ROOT"
mkdir -p "$ROOT/dev" "$ROOT/etc" "$ROOT/rescue" "$ROOT/sbin" "$ROOT/bin" \
         "$ROOT/tmp" "$ROOT/mnt"
cp -p "$RESCUE_SRC" "$ROOT/rescue/rescue"
# crunchgen dispatches on argv[0]; hard-link the names we use (same fs).
for n in init sh ifconfig sysctl mount umount mount_nullfs devfs mdconfig \
         ls cat echo ps sleep hostname kenv dmesg df date reboot; do
    ln "$ROOT/rescue/rescue" "$ROOT/rescue/$n"
done
# kernel default init_path already includes /rescue/init, but /sbin/init
# is first — link it there so lookup is instant and intent is explicit.
ln "$ROOT/rescue/rescue" "$ROOT/sbin/init"
# init(8) hardcodes _PATH_BSHELL=/bin/sh to run /etc/rc (it does NOT
# honor the rc shebang) and single-user fallback wants it too — without
# this link init cannot run runcom at all.
ln "$ROOT/rescue/rescue" "$ROOT/bin/sh"

# init(8) runs /etc/rc and waits; rc never exits — it becomes the console
# shell. Gate protocol: SMOLFIRE_READY on serial, then interactive sh.
cat > "$ROOT/etc/rc" <<'EOF'
#!/rescue/sh
PATH=/rescue; export PATH
hostname smolfire
ifconfig lo0 inet 127.0.0.1/8 up 2>/dev/null || true
echo "SMOLFIRE_READY"
exec /rescue/sh </dev/console >/dev/console 2>&1
EOF
chmod 755 "$ROOT/etc/rc"

if [ "$ROOTFS_ONLY" = yes ]; then
    echo "==> --rootfs-only: rootfs assembled at $ROOT (skipping makefs/buildkernel)"
    exit 0
fi

# Below this point is FreeBSD-only (sysctl hw.ncpu, makefs, buildkernel).
NCPU=$(sysctl -n hw.ncpu)

# PVH early-delay patch: sys/x86/xen/pv.c installs xen_delay/xen_clock_init
# as the early DELAY/clock ops on EVERY PVH boot — but on non-Xen PVH
# (Firecracker, QEMU microvm) there is no shared-info page and xen_delay
# faults in pvclock_get_timecount (run #6). Both VMMs provide a KVM
# in-kernel i8254, so point the PVH ops at the same i8254_init/i8254_delay
# the native (known-good QEMU/GENERIC) path uses. This trades Xen-dom
# bootability (not a SMOLFIRE target) for working TSC calibration
# everywhere. Idempotent: skipped when already applied.
PV=/usr/src/sys/x86/xen/pv.c
if grep -q '\.early_delay = xen_delay,' "$PV"; then
    echo "==> patching pv.c: non-Xen PVH early clock/delay -> i8254"
    # awk for the multi-line insert (BSD sed does not expand \n in
    # replacements); plain single-line seds for the member swaps.
    awk '/^struct init_ops xen_pvh_init_ops = \{/ {
             print "extern void i8254_init(void);"
             print "extern void i8254_delay(int);"
             print ""
         } { print }' "$PV" > "$PV.new" && mv "$PV.new" "$PV"
    sed -i '' \
        -e 's/\.early_clock_source_init = xen_clock_init,/.early_clock_source_init = i8254_init,/' \
        -e 's/\.early_delay = xen_delay,/.early_delay = i8254_delay,/' \
        "$PV"
    grep -q '\.early_delay = i8254_delay,' "$PV" || { echo "ERROR: pv.c patch did not apply"; exit 1; }
    grep -q 'extern void i8254_delay' "$PV" || { echo "ERROR: pv.c extern insert did not apply"; exit 1; }
fi

echo "==> makefs (UFS image with free-space headroom)"
# -b 10%: without it makefs sizes the image to its contents and the
# root filesystem boots ~100% full — any runtime write would fail.
makefs -t ffs -o version=2 -o label=smolfire -b 10% "$IMG" "$ROOT"
ls -lh "$IMG"

echo "==> kernel-toolchain + buildkernel SMOLFIRE (log: $LOG)"
# kernel-toolchain is the small buildworld subset buildkernel needs.
make -C "$SRC" -j "$NCPU" kernel-toolchain >> "$LOG" 2>&1
make -C "$SRC" -j "$NCPU" buildkernel \
    KERNCONF=SMOLFIRE MFS_IMAGE="$IMG" >> "$LOG" 2>&1

KERNEL="/usr/obj${SRC}/amd64.amd64/sys/SMOLFIRE/kernel"
test -f "$KERNEL" || { echo "ERROR: no kernel at $KERNEL"; tail -50 "$LOG"; exit 1; }
cp "$KERNEL" "$OUT"
echo "==> smolfire kernel: $(du -h "$OUT" | cut -f1) (rootfs embedded)"
