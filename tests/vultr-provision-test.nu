#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# vultr-provision-test.nu — dry-run smoke tests for bin/vultr-bhyve-provision.nu
#
# --dry-run prints the API request body without sending it.
# No VULTR_API_KEY is needed in dry-run mode.
# Safe to run on any machine.
#
# Run from repo root:
#   nu tests/vultr-provision-test.nu

# ── helpers ───────────────────────────────────────────────────────────────────

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Test 1: --dry-run exits 0 and prints recognisable output ─────────────────
print "test 1: vultr-bhyve-provision --dry-run exits 0 and prints recognisable output"

let r1 = ^nu --no-config-file bin/vultr-bhyve-provision.nu --dry-run | complete

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
    ($out1 | str contains "bare-metal") or
    ($out1 | str contains "bare_metal") or
    ($out1 | str contains "vultr") or
    ($out1 | str contains "vbm-6c-32gb") or
    ($out1 | str contains "freebsd")
)
assert $has_recognisable "output contains recognisable vultr provision info"

print "  PASS"

# ── Test 2: --dry-run --plan vbm-4c-32gb --region ord exits 0 ───────────────
print "test 2: vultr-bhyve-provision --dry-run --plan vbm-4c-32gb --region ord exits 0"

let r2 = ^nu --no-config-file bin/vultr-bhyve-provision.nu --dry-run --plan vbm-4c-32gb --region ord | complete

if $r2.exit_code != 0 {
    print $"  FAIL: exit code ($r2.exit_code)"
    print $"  stdout: ($r2.stdout)"
    print $"  stderr: ($r2.stderr)"
    exit 1
}

let out2 = $r2.stdout
assert ($out2 | str contains "vbm-4c-32gb") "custom plan vbm-4c-32gb in output"
assert ($out2 | str contains "ord") "custom region ord in output"

print "  PASS"

# ── Test 3: --dry-run --instance-fallback exits 0 ────────────────────────────
print "test 3: vultr-bhyve-provision --dry-run --instance-fallback exits 0"

let r3 = ^nu --no-config-file bin/vultr-bhyve-provision.nu --dry-run --instance-fallback | complete

if $r3.exit_code != 0 {
    print $"  FAIL: exit code ($r3.exit_code)"
    print $"  stdout: ($r3.stdout)"
    print $"  stderr: ($r3.stderr)"
    exit 1
}

let out3 = ($r3.stdout | str downcase)
let has_instance_output = (
    ($out3 | str contains "instance") or
    ($out3 | str contains "dry-run") or
    ($out3 | str contains "dry_run") or
    ($out3 | str contains "smolbsd")
)
assert $has_instance_output "instance-fallback dry-run produces recognisable output"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All vultr-bhyve-provision dry-run tests passed."
