# SPDX-License-Identifier: Apache-2.0
# tests/secret-materialize-test.nu — smoke tests for bin/secret-materialize.nu
#
# Run from repo root:
#   nu tests/secret-materialize-test.nu
#
# All tests use temp directories via --root; no network, SSH, or real hardware required.

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

# Run secret-materialize.nu with given args; returns {exit_code, stdout, stderr}.
def run-materialize [args: list<string>] {
    let script = ([( repo-root ) "bin" "secret-materialize.nu"] | path join)
    do { ^nu --no-config-file $script ...$args } | complete
}

# ── Test 1: basic happy path ──────────────────────────────────────────────────
print "test 1: basic — exits 0, secret file exists, .meta.toml exists, stdout has pointer table"

let t1 = make-temp-dir
let r1 = run-materialize ["--task-id" "t1" "--key" "api_token" "--value" "mysecret" "--root" $t1]

assert equal $r1.exit_code 0 "exit code 0"

let secret_path = [$t1 "var" "run" "secrets" "t1" "api_token"] | path join
let meta_path   = [$t1 "var" "run" "secrets" "t1" ".meta.toml"] | path join

assert ($secret_path | path exists) "secret file exists"
assert ($meta_path   | path exists) ".meta.toml sidecar exists"
assert ($r1.stdout | str contains "[secrets.api_token]") "stdout contains TOML pointer table header"
assert ($r1.stdout | str contains "envelope") "stdout contains envelope key"
assert ($r1.stdout | str contains "fingerprint") "stdout contains fingerprint key"

print "  PASS"

# ── Test 2: SHA-256 fingerprint is a 64-char hex string ──────────────────────
print "test 2: .meta.toml contains a 64-char hex fingerprint"

let t2 = make-temp-dir
let _r2 = run-materialize ["--task-id" "t2" "--key" "token" "--value" "hunter2" "--root" $t2]

let meta2_path = [$t2 "var" "run" "secrets" "t2" ".meta.toml"] | path join
let meta2_raw  = open --raw $meta2_path
let meta2      = $meta2_raw | from toml

assert ("fingerprint" in ($meta2 | columns)) ".meta.toml has fingerprint key"

let fp = $meta2 | get fingerprint
assert equal ($fp | str length) 64 "fingerprint is 64 chars"

# Verify it is a valid hex string (only 0-9 a-f)
let non_hex = $fp | str replace --all --regex '[0-9a-f]' ''
assert equal ($non_hex | str length) 0 "fingerprint contains only hex chars"

print "  PASS"

# ── Test 3: missing --task-id → non-zero exit ─────────────────────────────────
print "test 3: missing --task-id → non-zero exit"

let t3 = make-temp-dir
let r3 = run-materialize ["--key" "mykey" "--value" "val" "--root" $t3]

assert ($r3.exit_code != 0) "non-zero exit when --task-id missing"

print "  PASS"

# ── Test 4: missing --key → non-zero exit ─────────────────────────────────────
print "test 4: missing --key → non-zero exit"

let t4 = make-temp-dir
let r4 = run-materialize ["--task-id" "t4" "--value" "val" "--root" $t4]

assert ($r4.exit_code != 0) "non-zero exit when --key missing"

print "  PASS"

# ── Test 5: literal secret value NOT in stdout ────────────────────────────────
print "test 5: literal secret value does not appear in stdout (only fingerprint)"

let t5 = make-temp-dir
let secret_val = "supersecretvalue42"
let r5 = run-materialize ["--task-id" "t5" "--key" "pw" "--value" $secret_val "--root" $t5]

assert equal $r5.exit_code 0 "exit code 0"
assert (not ($r5.stdout | str contains $secret_val)) "stdout does NOT contain the literal secret value"

print "  PASS"

# ── Done ──────────────────────────────────────────────────────────────────────
print ""
print "All secret-materialize tests passed."
