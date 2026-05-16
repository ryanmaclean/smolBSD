# SPDX-License-Identifier: Apache-2.0
# tests/spool-emit-control-test.nu — smoke tests for bin/spool-emit-control.nu
#
# Run from repo root:
#   nu tests/spool-emit-control-test.nu

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

def run-emit [args: list<string>] {
    do { ^nu --no-config-file bin/spool-emit-control.nu ...$args } | complete
}

# ── Test 1: halt action writes HALT message and HALT marker ──────────────────
print "test 1: --action halt writes HALT message to spool and creates per-task HALT marker"

let t1 = make-temp-dir
let t1_spool = [$t1, "var", "mail", "spool"] | path join
let t1_halt  = [$t1, "var", "mail", "HALT.t77"] | path join

let r1 = run-emit [
    "--action"  "halt"
    "--task-id" "t77"
    "--reason"  "test"
    "--spool"   $t1_spool
    "--root"    $t1
]

assert equal $r1.exit_code 0 "exit code 0"
assert ($t1_spool | path exists) "spool file created"
let s1 = open --raw $t1_spool
assert ($s1 | str contains "halt") "spool contains halt action"
assert ($s1 | str contains "t77") "spool contains task id"
assert ($t1_halt | path exists) "per-task HALT marker created"

print "  PASS"

# ── Test 2: resume action writes resume message with X-Resume-Action ─────────
print "test 2: --action resume writes resume message with X-Resume-Action: retry"

let t2 = make-temp-dir
let t2_spool = [$t2, "var", "mail", "spool"] | path join

# Pre-create a HALT marker so resume can remove it
let t2_halt = [$t2, "var", "mail", "HALT.t77"] | path join
mkdir ($t2_halt | path dirname)
"task_id = \"t77\"\n" | save --force $t2_halt

let r2 = run-emit [
    "--action"        "resume"
    "--task-id"       "t77"
    "--resume-action" "retry"
    "--spool"         $t2_spool
    "--root"          $t2
]

assert equal $r2.exit_code 0 "exit code 0"
assert ($t2_spool | path exists) "spool file created"
let s2 = open --raw $t2_spool
assert ($s2 | str contains "resume") "spool contains resume action"
assert ($s2 | str contains "retry") "spool contains resume_action=retry"
# HALT marker should be removed
assert (not ($t2_halt | path exists)) "per-task HALT marker removed after resume"

print "  PASS"

# ── Test 3: halt-all writes global HALT marker ────────────────────────────────
print "test 3: --action halt-all writes global HALT marker"

let t3 = make-temp-dir
let t3_spool = [$t3, "var", "mail", "spool"] | path join
let t3_halt_global = [$t3, "var", "mail", "HALT"] | path join

let r3 = run-emit [
    "--action" "halt-all"
    "--reason" "emergency"
    "--spool"  $t3_spool
    "--root"   $t3
]

assert equal $r3.exit_code 0 "exit code 0"
assert ($t3_spool | path exists) "spool file created"
let s3 = open --raw $t3_spool
assert ($s3 | str contains "halt-all") "spool contains halt-all action"
assert ($t3_halt_global | path exists) "global HALT marker created"
let halt_content = open --raw $t3_halt_global
assert ($halt_content | str contains "emergency") "global HALT marker contains reason"

print "  PASS"

# ── Test 4: invalid action errors with non-zero exit ─────────────────────────
print "test 4: invalid --action → non-zero exit"

let t4 = make-temp-dir
let t4_spool = [$t4, "var", "mail", "spool"] | path join

let r4 = run-emit [
    "--action" "explode"
    "--spool"  $t4_spool
    "--root"   $t4
]

assert ($r4.exit_code != 0) "exit code non-zero for invalid action"

print "  PASS"

# ── Test 5: rotate-key action works for completeness ─────────────────────────
print "test 5: --action rotate-key exits 0"

let t5 = make-temp-dir
let t5_spool = [$t5, "var", "mail", "spool"] | path join

let r5 = run-emit [
    "--action"  "rotate-key"
    "--task-id" "t1"
    "--reason"  "scheduled"
    "--spool"   $t5_spool
    "--root"    $t5
]

assert equal $r5.exit_code 0 "exit code 0 for rotate-key"
assert ($t5_spool | path exists) "spool file created"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All spool-emit-control tests passed."
