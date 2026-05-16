# SPDX-License-Identifier: Apache-2.0
# tests/ci-gate-test.nu — smoke tests for bin/ci-gate.nu
#
# Run from repo root:
#   nu tests/ci-gate-test.nu
#
# All tests use temp directories; no network, SSH, or real hardware required.

# ── Inline assert helpers ─────────────────────────────────────────────────────

def "assert equal" [left: any, right: any, label: string = ""] {
    if $left != $right {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert equal failed($ctx)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def make-temp-dir [] {
    ^mktemp -d | str trim
}

def repo-root [] {
    $env.PWD
}

# Run ci-gate.nu with given args; returns {exit_code, stdout, stderr}.
def run-gate [args: list<string>] {
    let script = ([( repo-root ) "bin" "ci-gate.nu"] | path join)
    do { ^nu --no-config-file $script ...$args } | complete
}

# Write a result TOML file with a given overall verdict into results_dir.
# Name is a timestamp-style string so lexicographic = chronological order.
def write-result [results_dir: string, name: string, overall: string] {
    let path = [$results_dir $"($name).toml"] | path join
    $"overall = \"($overall)\"\n" | save --force $path
}

# ── Test 1: empty results dir → gate=closed, exit 2 ──────────────────────────
print "test 1: empty results dir → gate=closed, exit 2"

let t1 = make-temp-dir
mkdir $t1

let r1 = run-gate ["--results-dir" $t1]

assert equal $r1.exit_code 2 "exit code 2 for empty results dir"
assert ($r1.stdout | str contains "closed") "output contains 'closed'"

print "  PASS"

# ── Test 2: 3 consecutive pass files → gate=open, exit 0 ─────────────────────
print "test 2: 3 consecutive pass files → gate=open, exit 0"

let t2 = make-temp-dir
mkdir $t2
write-result $t2 "20260101T000000Z" "pass"
write-result $t2 "20260101T000001Z" "pass"
write-result $t2 "20260101T000002Z" "pass"

let r2 = run-gate ["--results-dir" $t2]

assert equal $r2.exit_code 0 "exit code 0 for 3 consecutive passes"
assert ($r2.stdout | str contains "open") "output contains 'open'"

print "  PASS"

# ── Test 3: 2 pass + 1 fail (oldest) → gate=open ─────────────────────────────
print "test 3: 2 recent passes + 1 older fail → gate=open (required=2)"

let t3 = make-temp-dir
mkdir $t3
# oldest file = fail, two newest = pass; use --required 2 so 2 trailing passes suffice
write-result $t3 "20260101T000000Z" "fail"
write-result $t3 "20260101T000001Z" "pass"
write-result $t3 "20260101T000002Z" "pass"

let r3 = run-gate ["--results-dir" $t3 "--required" "2"]

assert equal $r3.exit_code 0 "exit code 0: 2 trailing passes with 1 older fail"
assert ($r3.stdout | str contains "open") "output contains 'open'"

print "  PASS"

# ── Test 4: 2 passes then a fail → gate=closed, exit 2 ───────────────────────
print "test 4: 2 passes then newest is fail → gate=closed, exit 2"

let t4 = make-temp-dir
mkdir $t4
write-result $t4 "20260101T000000Z" "pass"
write-result $t4 "20260101T000001Z" "pass"
write-result $t4 "20260101T000002Z" "fail"

let r4 = run-gate ["--results-dir" $t4]

assert equal $r4.exit_code 2 "exit code 2: newest file is fail"
assert ($r4.stdout | str contains "closed") "output contains 'closed'"

print "  PASS"

# ── Test 5: --required 1 with 1 pass → gate=open, exit 0 ─────────────────────
print "test 5: --required 1 with single pass file → gate=open, exit 0"

let t5 = make-temp-dir
mkdir $t5
write-result $t5 "20260101T000000Z" "pass"

let r5 = run-gate ["--results-dir" $t5 "--required" "1"]

assert equal $r5.exit_code 0 "exit code 0 for 1 pass with --required 1"
assert ($r5.stdout | str contains "open") "output contains 'open'"

print "  PASS"

# ── Done ──────────────────────────────────────────────────────────────────────
print ""
print "All ci-gate tests passed."
