# SPDX-License-Identifier: Apache-2.0
# tests/pre-push-check-test.nu — smoke tests for bin/pre-push-check.nu
#
# Run from repo root:
#   nu tests/pre-push-check-test.nu
#
# pre-push-check.nu reads "var/mail/spool" (hardcoded, relative to CWD).
# Tests run the script in a temp dir via subprocess with the appropriate CWD.

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

# Run pre-push-check.nu from a given working directory.
# Returns a record with {exit_code, stdout, stderr}.
def run-check [work_dir: string] {
    let repo_root = $env.PWD
    let script = [$repo_root, "bin", "pre-push-check.nu"] | path join
    do { ^nu --no-config-file $script } | complete
}

# Write a spool at var/mail/spool inside work_dir, creating dirs as needed.
def write-spool [work_dir: string, content: string] {
    let spool_dir  = [$work_dir, "var", "mail"] | path join
    let spool_path = [$spool_dir, "spool"] | path join
    if not ($spool_dir | path exists) { mkdir $spool_dir }
    $content | save --force $spool_path
}

# ── Test 1: absent spool → exits 0 with "spool absent" ───────────────────────
print "test 1: absent spool → exits 0 with 'spool absent' message"

let t1 = make-temp-dir
# No spool written — run from repo root but override CWD via subprocess trick.
# We need the script to see no spool. Run it from t1 (empty temp dir).
let repo_root = $env.PWD
let script_path = [$repo_root, "bin", "pre-push-check.nu"] | path join

let r1 = do {
    ^sh -c $"cd '($t1)' && nu --no-config-file '($script_path)'"
} | complete

assert equal $r1.exit_code 0 "exit code 0 when spool absent"
assert ($r1.stdout | str contains "spool absent") "output contains 'spool absent'"

print "  PASS"

# ── Test 2: clean spool → exits 0 ────────────────────────────────────────────
print "test 2: clean spool (no sensitive content) → exits 0"

let t2 = make-temp-dir
write-spool $t2 "From agent@smolbsd.local Mon Jan  1 00:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-1] test
Content-Type: text/toml; charset=utf-8

task_id = \"task-1\"
verdict = \"pass\"
"

let r2 = do {
    ^sh -c $"cd '($t2)' && nu --no-config-file '($script_path)'"
} | complete

assert equal $r2.exit_code 0 "exit code 0 for clean spool"
assert ($r2.stdout | str contains "clean") "output says clean"

print "  PASS"

# ── Test 3: public IP in spool → exits 1 and mentions the IP ─────────────────
print "test 3: spool with public IP 107.191.39.47 → exits 1, IP mentioned in output"

let t3 = make-temp-dir
write-spool $t3 "From agent@smolbsd.local Mon Jan  1 00:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-2] build
Content-Type: text/toml; charset=utf-8

task_id = \"task-2\"
host_ip = \"107.191.39.47\"
verdict = \"pass\"
"

let r3 = do {
    ^sh -c $"cd '($t3)' && nu --no-config-file '($script_path)'"
} | complete

assert equal $r3.exit_code 1 "exit code 1 when public IP found"
assert ($r3.stdout | str contains "107.191.39.47") "output mentions the offending IP"

print "  PASS"

# ── Test 4: RFC1918 address → exits 0 (not flagged) ──────────────────────────
print "test 4: RFC1918 address 192.168.1.1 → exits 0 (not flagged as sensitive)"

let t4 = make-temp-dir
write-spool $t4 "From agent@smolbsd.local Mon Jan  1 00:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-3] internal
Content-Type: text/toml; charset=utf-8

task_id = \"task-3\"
host_ip = \"192.168.1.1\"
verdict = \"pass\"
"

let r4 = do {
    ^sh -c $"cd '($t4)' && nu --no-config-file '($script_path)'"
} | complete

assert equal $r4.exit_code 0 "exit code 0 for RFC1918 address 192.168.1.1"

print "  PASS"

# ── Test 5: 10.x RFC1918 address → exits 0 ───────────────────────────────────
print "test 5: RFC1918 address 10.0.0.1 → exits 0"

let t5 = make-temp-dir
write-spool $t5 "From agent@smolbsd.local Mon Jan  1 00:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-4] internal
Content-Type: text/toml; charset=utf-8

task_id = \"task-4\"
gw = \"10.0.0.1\"
verdict = \"pass\"
"

let r5 = do {
    ^sh -c $"cd '($t5)' && nu --no-config-file '($script_path)'"
} | complete

assert equal $r5.exit_code 0 "exit code 0 for RFC1918 address 10.0.0.1"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All pre-push-check tests passed."
