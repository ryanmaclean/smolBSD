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
ROOT=/root/smolfire-root
IMG=/root/smolfire-mfs.img
OUT=/root/smolfire-kernel
LOG=/var/tmp/smolfire-build.log
NCPU=$(sysctl -n hw.ncpu)

echo "==> rootfs: static /rescue crunchgen userland ($(du -sh /rescue | cut -f1))"
rm -rf "$ROOT"
mkdir -p "$ROOT/dev" "$ROOT/etc" "$ROOT/rescue" "$ROOT/sbin" "$ROOT/tmp" "$ROOT/mnt"
cp -p /rescue/rescue "$ROOT/rescue/rescue"
# crunchgen dispatches on argv[0]; hard-link the names we use (same fs).
for n in init sh ifconfig sysctl mount umount mount_nullfs devfs mdconfig \
         ls cat echo ps sleep hostname kenv dmesg df date reboot; do
    ln "$ROOT/rescue/rescue" "$ROOT/rescue/$n"
done
# kernel default init_path already includes /rescue/init, but /sbin/init
# is first — link it there so lookup is instant and intent is explicit.
ln "$ROOT/rescue/rescue" "$ROOT/sbin/init"

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

echo "==> makefs (auto-sized UFS image)"
makefs -t ffs -o version=2 -o label=smolfire "$IMG" "$ROOT"
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
