#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# harvest-build-test.nu — dry-run smoke tests for bin/harvest-build.nu
#
# --dry-run prints SSH commands without connecting to any remote host.
# Safe to run on any machine — no SSH connections are made.
#
# Run from repo root:
#   nu tests/harvest-build-test.nu

# ── helpers ───────────────────────────────────────────────────────────────────

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Test 1: --dry-run exits 0 and prints ssh commands ────────────────────────
print "test 1: harvest-build --dry-run exits 0 and prints ssh commands"

let r1 = ^nu --no-config-file bin/harvest-build.nu --dry-run | complete

if $r1.exit_code != 0 {
    print $"  FAIL: exit code ($r1.exit_code)"
    print $"  stdout: ($r1.stdout)"
    print $"  stderr: ($r1.stderr)"
    exit 1
}

let out1 = ($r1.stdout | str downcase)
let has_ssh = (
    ($out1 | str contains "ssh") or
    ($out1 | str contains "dry-run") or
    ($out1 | str contains "dry_run")
)
assert $has_ssh "output contains ssh or dry-run"

print "  PASS"

# ── Test 2: --dry-run --ssh-jump with a custom jump host exits 0 ─────────────
print "test 2: harvest-build --dry-run --ssh-jump testhost exits 0"

let r2 = ^nu --no-config-file bin/harvest-build.nu --dry-run --ssh-jump testhost | complete

if $r2.exit_code != 0 {
    print $"  FAIL: exit code ($r2.exit_code)"
    print $"  stdout: ($r2.stdout)"
    print $"  stderr: ($r2.stderr)"
    exit 1
}

# The custom jump host should appear in the output
let out2 = $r2.stdout
assert ($out2 | str contains "testhost") "custom jump host appears in output"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All harvest-build dry-run tests passed."
