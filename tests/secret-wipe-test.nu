# SPDX-License-Identifier: Apache-2.0
# tests/secret-wipe-test.nu — smoke tests for bin/secret-wipe.nu
#
# Run from repo root:
#   nu tests/secret-wipe-test.nu
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

# Run secret-wipe.nu with given args; returns {exit_code, stdout, stderr}.
def run-wipe [args: list<string>] {
    let script = ([( repo-root ) "bin" "secret-wipe.nu"] | path join)
    do { ^nu --no-config-file $script ...$args } | complete
}

# Run secret-materialize.nu with given args; returns {exit_code, stdout, stderr}.
def run-materialize [args: list<string>] {
    let script = ([( repo-root ) "bin" "secret-materialize.nu"] | path join)
    do { ^nu --no-config-file $script ...$args } | complete
}

# ── Test 1: basic wipe removes directory ──────────────────────────────────────
print "test 1: basic wipe — creates files in temp dir, wipe removes the directory"

let t1 = make-temp-dir
let secret_dir = [$t1 "var" "run" "secrets" "task-wipe1"] | path join
mkdir $secret_dir
"secret1" | save --force ([$secret_dir "api_key"] | path join)
"secret2" | save --force ([$secret_dir "db_pass"] | path join)

assert ($secret_dir | path exists) "secret dir exists before wipe"

let r1 = run-wipe ["--task-id" "task-wipe1" "--root" $t1]

assert equal $r1.exit_code 0 "exit code 0"
assert (not ($secret_dir | path exists)) "secret directory removed after wipe"

print "  PASS"

# ── Test 2: wipe non-existent task → exits 0 with "nothing to wipe" ──────────
print "test 2: wipe non-existent task → exits 0, prints 'nothing to wipe'"

let t2 = make-temp-dir
let r2 = run-wipe ["--task-id" "no-such-task" "--root" $t2]

assert equal $r2.exit_code 0 "exit code 0 for non-existent task"
assert ($r2.stdout | str contains "nothing to wipe") "output contains 'nothing to wipe'"

print "  PASS"

# ── Test 3: missing --task-id → non-zero exit ─────────────────────────────────
print "test 3: missing --task-id → non-zero exit"

let t3 = make-temp-dir
let r3 = run-wipe ["--root" $t3]

assert ($r3.exit_code != 0) "non-zero exit when --task-id missing"

print "  PASS"

# ── Test 4: materialize then wipe — value file is gone ───────────────────────
print "test 4: after materialize+wipe, secret value file is gone"

let t4 = make-temp-dir

let rm4 = run-materialize ["--task-id" "t4" "--key" "my_token" "--value" "topsecret" "--root" $t4]
assert equal $rm4.exit_code 0 "materialize exits 0"

let secret_path4 = [$t4 "var" "run" "secrets" "t4" "my_token"] | path join
assert ($secret_path4 | path exists) "secret file exists after materialize"

let rw4 = run-wipe ["--task-id" "t4" "--root" $t4]
assert equal $rw4.exit_code 0 "wipe exits 0"

assert (not ($secret_path4 | path exists)) "secret value file gone after wipe"

let secret_dir4 = [$t4 "var" "run" "secrets" "t4"] | path join
assert (not ($secret_dir4 | path exists)) "entire task secret dir gone after wipe"

print "  PASS"

# ── Done ──────────────────────────────────────────────────────────────────────
print ""
print "All secret-wipe tests passed."
