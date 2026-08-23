#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# bin/copy-configs-to-freebsd.sh — copy smolfire kernel and release configs into a
#                                  FreeBSD source tree.
#
# Usage:
#   sh bin/copy-configs-to-freebsd.sh [freebsd-src-root] [smolfire-repo-root]
#
# Arguments:
#   $1  FreeBSD src root  (default: /usr/src)
#   $2  smolfire repo root (default: directory containing this script / ..)
#
# Files copied:
#   sys/amd64/conf/SMOLFIRE-VM              -> $1/sys/amd64/conf/SMOLFIRE-VM
#   release/tools/smolfire-qemu.conf     -> $1/release/tools/smolfire-qemu.conf
#   release/tools/smolfire-qemu-aarch64.conf -> $1/release/tools/smolfire-qemu-aarch64.conf
#
# Exit codes:
#   0  — all files copied successfully
#   1  — one or more source files not found, or destination parent dir missing

set -e

# ── Resolve paths ─────────────────────────────────────────────────────────────

# $1: FreeBSD src root (default /usr/src)
FBSD_SRC="${1:-/usr/src}"

# $2: smolfire repo root.  Default: two levels above this script
#     bin/copy-configs-to-freebsd.sh  ->  dirname -> bin/  ->  dirname -> ./
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${2:-$(dirname "$SCRIPT_DIR")}"

echo "FreeBSD src root : ${FBSD_SRC}"
echo "smolfire repo root: ${REPO_ROOT}"
echo ""

# ── Validation ────────────────────────────────────────────────────────────────

if [ ! -d "${FBSD_SRC}" ]; then
    echo "ERROR: FreeBSD src root not found: ${FBSD_SRC}" >&2
    exit 1
fi

# ── Copy helper ───────────────────────────────────────────────────────────────

copy_file() {
    src="${REPO_ROOT}/${1}"
    dst="${FBSD_SRC}/${1}"
    dst_dir="$(dirname "${dst}")"

    if [ ! -f "${src}" ]; then
        echo "SKIP (not found): ${src}" >&2
        MISSING=$((MISSING + 1))
        return
    fi

    if [ ! -d "${dst_dir}" ]; then
        echo "ERROR: destination directory does not exist: ${dst_dir}" >&2
        MISSING=$((MISSING + 1))
        return
    fi

    cp "${src}" "${dst}"
    echo "copied: ${src}"
    echo "     -> ${dst}"
}

# ── Copy files ────────────────────────────────────────────────────────────────

MISSING=0

copy_file "sys/amd64/conf/SMOLFIRE-VM"
copy_file "release/tools/smolfire-qemu.conf"
copy_file "release/tools/smolfire-qemu-aarch64.conf"

echo ""

if [ "${MISSING}" -gt 0 ]; then
    echo "WARNING: ${MISSING} file(s) were not copied — see messages above." >&2
    exit 1
fi

echo "All configs copied successfully."
