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
for n in init sh ifconfig route ping fetch nc sysctl mount umount \
         mount_nullfs devfs mdconfig \
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
# Static net, kenv-fed: the PVH cmdline becomes static kenv (pv.c
# boot_parse_cmdline_delim), so Firecracker boot_args / QEMU -append
# "smolfire.ip=..." land here. Defaults match QEMU SLIRP topology.
# Values must contain no spaces/commas (kenv cmdline delimiters).
if ifconfig vtnet0 >/dev/null 2>&1; then
    ip=$(kenv smolfire.ip 2>/dev/null) || ip=10.0.2.15/24
    gw=$(kenv smolfire.gw 2>/dev/null) || gw=10.0.2.2
    ifconfig vtnet0 inet "$ip" up
    route -q add default "$gw" 2>/dev/null || true
    # CI net gate: fetch a per-run random token over TCP and echo it.
    url=$(kenv smolfire.fetch 2>/dev/null) || url=""
    if [ -n "$url" ]; then
        tok=$(fetch -q -T 5 -o - "$url" 2>/dev/null) \
            && echo "SMOLFIRE_NET_OK $tok" \
            || echo "SMOLFIRE_NET_FAIL"
    fi
fi
echo "SMOLFIRE_READY"
exec /rescue/sh </dev/console >/dev/console 2>&1
EOF
chmod 755 "$ROOT/etc/rc"

if [ "$ROOTFS_ONLY" = yes ]; then
    echo "==> --rootfs-only: rootfs assembled at $ROOT (skipping makefs/buildkernel)"
    exit 0
fi

# Net tools are MK_INET/MK_NETCAT-conditional upstream — fail loud if this
# base's stock /rescue lacks them (run #7 lesson: guards never skip silently).
for n in route ping fetch nc; do
    [ -e "$RESCUE_DIR/$n" ] \
        || { echo "ERROR: $RESCUE_DIR/$n missing — stock rescue lacks $n"; exit 1; }
done

# Below this point is FreeBSD-only (sysctl hw.ncpu, makefs, buildkernel).
NCPU=$(sysctl -n hw.ncpu)

# PVH early-delay patch (upstream-shaped): dispatch early_delay /
# early_clock_source_init on isxen() at runtime instead of using
# xen_delay unconditionally — xen_delay faults on non-Xen PVH
# (Firecracker, QEMU microvm) because HYPERVISOR_shared_info is never
# mapped (run #6). Preserves real Xen PVH boots, unlike the old sed
# swap. Upstream submission draft; drop once it lands in releng.
# Idempotent: skipped when already applied.
PV=/usr/src/sys/x86/xen/pv.c
if grep -q 'pvh_early_delay' "$PV"; then
    echo "==> pv.c already patched (pvh_early_delay dispatch present)"
else
    # Fail LOUD if the file shape is unrecognized (run #7's lesson) —
    # also catches a tree still carrying the old i8254 sed swap.
    grep -Eq 'early_delay[[:space:]]*=[[:space:]]*xen_delay' "$PV" \
        || { echo "ERROR: pv.c shape unrecognized — refusing to build unpatched"; exit 1; }
    echo "==> patching pv.c: isxen() runtime dispatch for early clock/delay"
    patch -p1 -d /usr/src <<'PVEOF'
--- a/sys/x86/xen/pv.c
+++ b/sys/x86/xen/pv.c
@@ -69,6 +69,7 @@
 #include <machine/md_var.h>
 #include <machine/metadata.h>
 #include <machine/cpu.h>
+#include <machine/clock.h>
 
 #include <xen/xen-os.h>
 #include <xen/hvm.h>
@@ -95,6 +96,8 @@
 
 /*--------------------------- Forward Declarations ---------------------------*/
 static void xen_pvh_parse_preload_data(uint64_t);
+static void pvh_early_clock_source_init(void);
+static void pvh_early_delay(int);
 static void pvh_parse_memmap(vm_paddr_t *, int *);
 
 /*---------------------------- Extern Declarations ---------------------------*/
@@ -107,8 +110,8 @@
 /*-------------------------------- Global Data -------------------------------*/
 struct init_ops xen_pvh_init_ops = {
 	.parse_preload_data		= xen_pvh_parse_preload_data,
-	.early_clock_source_init	= xen_clock_init,
-	.early_delay			= xen_delay,
+	.early_clock_source_init	= pvh_early_clock_source_init,
+	.early_delay			= pvh_early_delay,
 	.parse_memmap			= pvh_parse_memmap,
 };
 
@@ -147,6 +150,34 @@
 	return (xen);
 }
 
+/*
+ * Early clock source and DELAY dispatch for PVH boots.
+ *
+ * The Xen implementations rely on the shared info page, and thus on
+ * hypercalls, which are only functional when running under Xen.  When
+ * booted in PVH mode by another VMM (e.g. Firecracker or QEMU microvm)
+ * fall back to the emulated i8254, mirroring the native init_ops.
+ */
+static void
+pvh_early_clock_source_init(void)
+{
+
+	if (isxen())
+		xen_clock_init();
+	else
+		i8254_init();
+}
+
+static void
+pvh_early_delay(int n)
+{
+
+	if (isxen())
+		xen_delay(n);
+	else
+		i8254_delay(n);
+}
+
 #define CRASH(...) do {					\
 	if (isxen())					\
 		xc_printf(__VA_ARGS__);			\
PVEOF
    grep -q 'pvh_early_delay' "$PV" \
        || { echo "ERROR: pv.c patch did not apply"; exit 1; }
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
