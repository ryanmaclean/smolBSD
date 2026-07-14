#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# bin/harvest.sh — Harvest qcow2 build artifacts from remote build hosts
#                  and run acceptance tests.
#
# Build hosts (internal names/addresses are NOT committed — see private
# inventory; pass via env):
#   aarch64: JUMP_HOST=<jump> AARCH64_REMOTE=builder@localhost:<path>
#   amd64:   AMD64_REMOTE=<user@host>:<path>
#
# Acceptance gates:
#   Artifact size: <= 512 MiB
#   Boot test: expect script exits 0

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/var/artifacts}"
REPORT="$ARTIFACTS_DIR/harvest-report.txt"

# FIX-9: cloudware-release writes the artifact to the release objdir root as
# ${CLOUDWARE:tl}.${FS}.${FMT} — smolbsd.ufs.qcow2 on releng/15.0 (verified in
# Makefile.vm). Default paths use the unified objdir layout
# (/usr/obj/usr/src/<arch>/release — src.sys.obj.mk MK_UNIFIED_OBJDIR=yes).
# Defaults are overridable per-run: AMD64_REMOTE=... sh bin/harvest.sh
AMD64_REMOTE="${AMD64_REMOTE:-root@REDACTED-VULTR-IP:/usr/obj/usr/src/amd64.amd64/release/smolbsd.ufs.qcow2}"
AARCH64_REMOTE="${AARCH64_REMOTE:-builder@localhost:/usr/obj/usr/src/arm64.aarch64/release/smolbsd.ufs.qcow2}"

AMD64_IMAGE="$ARTIFACTS_DIR/FreeBSD-15.0-RELEASE-amd64-SMOLBSD.qcow2"
AARCH64_IMAGE="$ARTIFACTS_DIR/FreeBSD-15.0-RELEASE-arm64-SMOLBSD.qcow2"

# 512 MiB in bytes
SIZE_LIMIT=536870912

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

OVERALL_FAIL=0

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

report() {
    printf '%s\n' "$*" | tee -a "$REPORT"
}

gate_pass() {
    report "  PASS  $*"
}

gate_fail() {
    report "  FAIL  $*"
    OVERALL_FAIL=1
}

# Check file size gate. $1 = label, $2 = path to qcow2.
check_size() {
    _label="$1"
    _path="$2"

    if [ ! -f "$_path" ]; then
        gate_fail "[$_label] size gate — image not found: $_path"
        return
    fi

    _bytes="$(wc -c < "$_path")"
    _mib=$(( _bytes / 1048576 ))

    report "  INFO  [$_label] size: ${_bytes} bytes (${_mib} MiB), limit: 512 MiB"
    if [ "$_bytes" -le "$SIZE_LIMIT" ]; then
        gate_pass "[$_label] size gate: ${_mib} MiB <= 512 MiB"
    else
        gate_fail "[$_label] size gate: ${_mib} MiB > 512 MiB"
    fi
}

# Run an expect boot test. $1 = label, $2 = expect script path.
check_boot() {
    _label="$1"
    _script="$2"

    if ! command -v expect > /dev/null 2>&1; then
        report "  SKIP  [$_label] boot gate — expect not found"
        return
    fi

    log "Running expect script for [$_label]: $_script"
    if expect "$_script"; then
        gate_pass "[$_label] boot gate: expect script exited 0"
    else
        gate_fail "[$_label] boot gate: expect script exited non-zero"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mkdir -p "$ARTIFACTS_DIR"
: > "$REPORT"

report "smolBSD Harvest Report"
report "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
report "============================================================"
report ""

# ---------------------------------------------------------------------------
# Step 1: Harvest aarch64 from <aarch64-builder> (via jump host)
# ---------------------------------------------------------------------------

report "--- Harvesting aarch64 from the aarch64 build host ---"
log "SCP aarch64: $AARCH64_REMOTE -> $AARCH64_IMAGE"

if scp -J "${JUMP_HOST:?Set JUMP_HOST to the aarch64 jump host (internal — not committed)}" -P 2222 \
        "$AARCH64_REMOTE" \
        "$AARCH64_IMAGE"; then
    report "  OK    aarch64 image fetched: $AARCH64_IMAGE"
    report "  INFO  aarch64 timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
else
    gate_fail "aarch64 SCP from build host failed"
fi

# ---------------------------------------------------------------------------
# Step 2: Harvest amd64 from Vultr
# ---------------------------------------------------------------------------

report ""
report "--- Harvesting amd64 from the amd64 build host ---"
log "SCP amd64: $AMD64_REMOTE -> $AMD64_IMAGE"

if scp "$AMD64_REMOTE" "$AMD64_IMAGE"; then
    report "  OK    amd64 image fetched: $AMD64_IMAGE"
    report "  INFO  amd64 timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
else
    gate_fail "amd64 SCP from build host failed"
fi

# ---------------------------------------------------------------------------
# Step 3: Size gates
# ---------------------------------------------------------------------------

report ""
report "--- Size Gates ---"
check_size "amd64"   "$AMD64_IMAGE"
check_size "aarch64" "$AARCH64_IMAGE"

# ---------------------------------------------------------------------------
# Step 4: Boot-time acceptance tests
# ---------------------------------------------------------------------------

report ""
report "--- Boot Acceptance Tests ---"
check_boot "amd64"   "$ROOT/tests/time-to-ready.exp"
check_boot "aarch64" "$ROOT/tests/time-to-ready-arm64.exp"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

report ""
report "============================================================"
if [ "$OVERALL_FAIL" -eq 0 ]; then
    report "RESULT: ALL GATES PASSED"
else
    report "RESULT: ONE OR MORE GATES FAILED — see above"
fi
report "Report: $REPORT"

log "Harvest complete. OVERALL_FAIL=$OVERALL_FAIL"

exit "$OVERALL_FAIL"
