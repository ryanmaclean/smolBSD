#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# hetzner-provision-test.nu — dry-run smoke tests for bin/hetzner-bhyve-provision.nu
#
# --dry-run prints the API request body without sending it.
# No HCLOUD_TOKEN or HETZNER_ROBOT credentials are needed in dry-run mode.
# Safe to run on any machine.
#
# Run from repo root:
#   nu tests/hetzner-provision-test.nu

# ── helpers ───────────────────────────────────────────────────────────────────

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Test 1: --dry-run (hcloud, default) exits 0 ──────────────────────────────
print "test 1: hetzner-bhyve-provision --dry-run exits 0 and prints recognisable output"

let r1 = ^nu --no-config-file bin/hetzner-bhyve-provision.nu --dry-run | complete

if $r1.exit_code != 0 {
    print $"  FAIL: exit code ($r1.exit_code)"
    print $"  stdout: ($r1.stdout)"
    print $"  stderr: ($r1.stderr)"
    exit 1
}

let out1 = ($r1.stdout | str downcase)
let has_recognisable = (
    ($out1 | str contains "dry-run") or
    ($out1 | str contains "dry_run") or
    ($out1 | str contains "smolbsd") or
    ($out1 | str contains "ccx23") or
    ($out1 | str contains "hetzner") or
    ($out1 | str contains "server_type")
)
assert $has_recognisable "output contains recognisable hcloud provision info"

print "  PASS"

# ── Test 2: --dry-run --type robot exits 0 ───────────────────────────────────
print "test 2: hetzner-bhyve-provision --dry-run --type robot exits 0"

let r2 = ^nu --no-config-file bin/hetzner-bhyve-provision.nu --dry-run --type robot | complete

if $r2.exit_code != 0 {
    print $"  FAIL: exit code ($r2.exit_code)"
    print $"  stdout: ($r2.stdout)"
    print $"  stderr: ($r2.stderr)"
    exit 1
}

let out2 = ($r2.stdout | str downcase)
let has_robot_output = (
    ($out2 | str contains "robot") or
    ($out2 | str contains "bare-metal") or
    ($out2 | str contains "dry-run") or
    ($out2 | str contains "dry_run") or
    ($out2 | str contains "smolbsd")
)
assert $has_robot_output "robot dry-run output contains recognisable content"

print "  PASS"

# ── Test 3: --dry-run --server-type ccx33 --location fsn1 exits 0 ───────────
print "test 3: hetzner-bhyve-provision --dry-run --server-type ccx33 --location fsn1 exits 0"

let r3 = ^nu --no-config-file bin/hetzner-bhyve-provision.nu --dry-run --server-type ccx33 --location fsn1 | complete

if $r3.exit_code != 0 {
    print $"  FAIL: exit code ($r3.exit_code)"
    print $"  stdout: ($r3.stdout)"
    print $"  stderr: ($r3.stderr)"
    exit 1
}

# Custom server type and location should appear in output
let out3 = $r3.stdout
assert ($out3 | str contains "ccx33") "custom server_type ccx33 in output"
assert ($out3 | str contains "fsn1") "custom location fsn1 in output"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All hetzner-bhyve-provision dry-run tests passed."
