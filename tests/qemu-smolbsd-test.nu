#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# qemu-smolbsd-test.nu — dry-run smoke tests for bin/qemu-smolbsd.nu
#
# --dry-run prints the QEMU command line without launching a VM.
# Safe to run on any host — no VM is started.
#
# The image path does not need to exist in dry-run mode (the script skips the
# file-existence check when --dry-run is active).  If QEMU is not installed,
# the preflight will exit non-zero with a clear "not found" error; that is
# acceptable — the test guards against crashes, not missing QEMU.
#
# Run from repo root:
#   nu tests/qemu-smolbsd-test.nu

# ── helpers ───────────────────────────────────────────────────────────────────

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Test 1: --dry-run with nonexistent image — no Nu crash ───────────────────
print "test 1: qemu-smolbsd --dry-run --image /nonexistent.qcow2 does not crash"

let r1 = ^nu --no-config-file bin/qemu-smolbsd.nu --dry-run --image /nonexistent.qcow2 | complete

let out1 = $r1.stdout + $r1.stderr

# Guard: no Rust/Nu internal panic
let no_panic1 = (
    not ($out1 | str contains "thread 'main' panicked") and
    not ($out1 | str contains "RUST_BACKTRACE")
)
assert $no_panic1 "no internal Nu/Rust panic"

# Acceptable outcomes:
#   exit 0  — QEMU found, dry-run printed command (contains "qemu")
#   exit 1  — QEMU not found; clear error message expected
let is_acceptable = (
    $r1.exit_code == 0 or
    ($out1 | str downcase | str contains "qemu") or
    ($out1 | str downcase | str contains "not found") or
    ($out1 | str downcase | str contains "error")
)
assert $is_acceptable "exit 0 or clear error (not a silent crash)"

# If exit 0, must have produced qemu in stdout
if $r1.exit_code == 0 {
    assert ($r1.stdout | str downcase | str contains "qemu") "stdout contains qemu on success"
}

print "  PASS"

# ── Test 2: --dry-run --arch amd64 with nonexistent image ─────────────────────
print "test 2: qemu-smolbsd --dry-run --arch amd64 --image /nonexistent.img does not crash"

let r2 = ^nu --no-config-file bin/qemu-smolbsd.nu --dry-run --arch amd64 --image /nonexistent.img | complete

let out2 = $r2.stdout + $r2.stderr

let no_panic2 = (
    not ($out2 | str contains "thread 'main' panicked") and
    not ($out2 | str contains "RUST_BACKTRACE")
)
assert $no_panic2 "no internal crash with --arch amd64"

let acceptable2 = (
    $r2.exit_code == 0 or
    ($out2 | str downcase | str contains "qemu") or
    ($out2 | str downcase | str contains "not found") or
    ($out2 | str downcase | str contains "error")
)
assert $acceptable2 "exit 0 or clear error for amd64 dry-run"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All qemu-smolbsd dry-run tests passed."
