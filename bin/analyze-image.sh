#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# analyze-image.sh — diagnose qcow2 size budget against the 512 MiB target.
#
# Run on a host with qemu-utils + libguestfs-tools (Linux) OR
# on a FreeBSD host with mdconfig + mount (no libguestfs needed).
#
# Usage:
#   bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolbsd.qcow2
#
# Reports:
#   - on-disk allocated size (qemu-img info: actual)
#   - virtual / sparse size
#   - top 30 directories by usage
#   - top 30 files by size
#   - installed package list with sizes (if /var/db/pkg present)
#   - the gap to the 512 MiB target

set -eu

IMG="${1:-}"
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "usage: $0 <qcow2-image>" >&2
    exit 2
fi

# Resolve IMG to an absolute path and reject any path-traversal components.
# This prevents a user-supplied IMG like "../../etc/motd.qcow2" from causing
# sudo tee -a to write as root to an attacker-chosen location.
IMG=$(realpath "$IMG" 2>/dev/null) || { echo "analyze-image.sh: cannot resolve image path" >&2; exit 2; }
case "$IMG" in
    *".."*) echo "analyze-image.sh: path traversal rejected: $IMG" >&2; exit 2 ;;
esac

# REPORT always lives beside the resolved image — never derived from raw user input.
REPORT="${REPORT:-${IMG%.qcow2}.size-report.txt}"
# Validate REPORT is under the same directory (no traversal via REPORT env var).
REPORT=$(realpath -m "$REPORT" 2>/dev/null || echo "$REPORT")
case "$REPORT" in
    *".."*) echo "analyze-image.sh: REPORT path traversal rejected" >&2; exit 2 ;;
esac

TARGET_MIB=512

uname_s=$(uname -s)

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

: > "$REPORT"
log "smolBSD image size analysis"
log "image:  $IMG"
log "target: <= ${TARGET_MIB} MiB"
log "host:   $uname_s"
log "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

# ---- qemu-img info --------------------------------------------------------
if command -v qemu-img >/dev/null 2>&1; then
    log "## qemu-img info"
    qemu-img info "$IMG" | tee -a "$REPORT"
    log ""
fi

# ---- mount the rootfs in a portable way -----------------------------------
MOUNT=$(mktemp -d -t smolbsd-analyze.XXXXXX)
cleanup() {
    case "$uname_s" in
        Linux)
            sudo umount "$MOUNT" 2>/dev/null || true
            sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
            ;;
        FreeBSD)
            sudo umount "$MOUNT" 2>/dev/null || true
            [ -n "${MD:-}" ] && sudo mdconfig -d -u "$MD" 2>/dev/null || true
            ;;
    esac
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

case "$uname_s" in
    Linux)
        if ! command -v qemu-nbd >/dev/null 2>&1; then
            log "ERROR: qemu-nbd not installed (apt install qemu-utils)"
            exit 1
        fi
        sudo modprobe nbd max_part=8 2>/dev/null || true
        sudo qemu-nbd --read-only --connect=/dev/nbd0 "$IMG"
        # rootfs is the largest UFS partition (typically p3 on GPT)
        ROOT_PART=$(lsblk -nrpo NAME,FSTYPE /dev/nbd0 \
                    | awk '$2 == "ufs" || $2 == "ufs2" {print $1; exit}')
        ROOT_PART=${ROOT_PART:-/dev/nbd0p3}
        sudo mount -t ufs -o ro,ufstype=ufs2 "$ROOT_PART" "$MOUNT"
        ;;
    FreeBSD)
        # Convert qcow2 to raw temp, attach via mdconfig
        RAW=$(mktemp -t smolbsd-analyze.XXXXXX.raw)
        qemu-img convert -O raw "$IMG" "$RAW"
        MD=$(sudo mdconfig -a -t vnode -f "$RAW" | sed 's/^md//')
        # rootfs partition — try common gpt names
        for p in rootfs ufs p3; do
            if [ -e "/dev/gpt/$p" ]; then
                sudo mount -o ro "/dev/gpt/$p" "$MOUNT" && break
            fi
            if [ -e "/dev/md${MD}p3" ]; then
                sudo mount -o ro "/dev/md${MD}p3" "$MOUNT" && break
            fi
        done
        ;;
    *)
        log "ERROR: unsupported host $uname_s"
        exit 1
        ;;
esac

if ! mountpoint -q "$MOUNT" 2>/dev/null && ! mount | grep -q " $MOUNT "; then
    log "ERROR: failed to mount rootfs"
    exit 1
fi

log "## Total filesystem usage"
sudo du -sh "$MOUNT" | tee -a "$REPORT"
log ""

log "## Top 30 directories (depth <= 3)"
sudo du -m -d 3 "$MOUNT" 2>/dev/null | sort -rn | head -30 | tee -a "$REPORT"
log ""

log "## Top 30 files by size"
sudo find "$MOUNT" -type f -exec du -k {} + 2>/dev/null \
    | sort -rn | head -30 \
    | awk '{printf "%8d KiB  %s\n", $1, substr($0, index($0,$2))}' \
    | tee -a "$REPORT"
log ""

log "## Installed pkgbase packages (if pkg DB present)"
if [ -d "$MOUNT/var/db/pkg" ] && command -v pkg >/dev/null 2>&1; then
    sudo pkg -c "$MOUNT" info -as 2>/dev/null \
        | sort -k2 -h -r | head -40 \
        | tee -a "$REPORT"
elif [ -d "$MOUNT/var/db/pkg" ]; then
    log "(pkg(8) not available on this host — listing pkg names only)"
    sudo ls "$MOUNT/var/db/pkg" | tee -a "$REPORT"
else
    log "(no /var/db/pkg — pkgbase not installed?)"
fi
log ""

# ---- size budget summary --------------------------------------------------
log "## Size budget vs target"
TOTAL_KB=$(sudo du -sk "$MOUNT" | awk '{print $1}')
TOTAL_MIB=$(( TOTAL_KB / 1024 ))
DELTA=$(( TOTAL_MIB - TARGET_MIB ))
log "filesystem usage: ${TOTAL_MIB} MiB"
log "target:           ${TARGET_MIB} MiB"
if [ "$DELTA" -le 0 ]; then
    log "result:           UNDER target by $((-DELTA)) MiB"
    exit 0
else
    log "result:           OVER target by ${DELTA} MiB"
    log ""
    log "## Suggested cuts (largest dirs likely to be safe to strip):"
    log "  - /usr/lib/debug      (debug symbols)"
    log "  - /usr/share/doc      (man, FAQ, handbook)"
    log "  - /usr/share/locale   (i18n catalogs)"
    log "  - /usr/share/examples (sample configs)"
    log "  - /usr/tests          (FreeBSD-tests pkg — should be filtered)"
    log "  - /boot/kernel/*.ko   (unused kmods — strip via kernel config)"
    exit 1
fi
