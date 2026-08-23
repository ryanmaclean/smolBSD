# SPDX-License-Identifier: Apache-2.0
# spool-compact-test.nu — hermetic tests for bin/spool-compact.nu
#
# Run from repo root:
#   nu tests/spool-compact-test.nu

use ../bin/mbox-parse.nu [parse-mbox, msg-id]

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

# Build a minimal well-formed mbox message with a unique integer index.
def make-msg [idx: int] {
    let id = $"<msg.($idx).test@smolfire.local>"
    $"From agent@smolfire.local Wed Jan  1 00:00:00 2026
From: agent@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($id)
Content-Type: text/toml; charset=utf-8

task_id = \"task-($idx)\"
verdict = \"pass\"
"
}

# Build a duplicate of message idx — same Message-ID, different body.
def make-dup-msg [idx: int] {
    let id = $"<msg.($idx).test@smolfire.local>"
    $"From agent@smolfire.local Wed Jan  1 00:01:00 2026
From: agent@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($id)
Content-Type: text/toml; charset=utf-8

task_id = \"task-($idx)-dup\"
verdict = \"fail\"
"
}

# Write a custom list of raw message strings into a spool file.
def write-spool [path: string, msgs: list<string>] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    "" | save --force $path
    for m in $msgs {
        $m | save --append $path
    }
}

# Seed a spool with N unique messages (indices 1..N).
def seed-spool [path: string, count: int] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    "" | save --force $path
    for i in 1..($count) {
        (make-msg $i) | save --append $path
    }
}

# Count messages in a spool file (returns 0 if absent or empty).
def count-spool [path: string] {
    if not ($path | path exists) { return 0 }
    let content = open --raw $path
    if ($content | str trim | str length) == 0 { return 0 }
    parse-mbox $content | length
}

# Return the list of Message-IDs in a spool file.
def spool-ids [path: string] {
    if not ($path | path exists) { return [] }
    let content = open --raw $path
    if ($content | str trim | str length) == 0 { return [] }
    parse-mbox $content | each {|m| msg-id $m}
}

# Run spool-compact.nu with the given flags; returns stdout parsed as a record.
def run-compact [
    spool:      string
    --keep-last: int = 200
    --dry-run
] {
    let dry_flag = if $dry_run { ["--dry-run"] } else { [] }
    let cmd_args = (
        [
            "bin/spool-compact.nu"
            "--spool" $spool
            "--keep-last" ($keep_last | into string)
        ] | append $dry_flag | str join " "
    )
    let raw = ^sh -c $"nu ($cmd_args) 2>/dev/null"
    $raw | str trim | from json
}

# ── Test 1: dedup removes duplicate Message-IDs ───────────────────────────────
print "test 1: dedup removes duplicate Message-IDs (keep first occurrence)"

let t1 = make-temp-dir
let t1_spool = [$t1, "var", "mail", "spool"] | path join

# Write 5 unique messages, then duplicate msgs 2 and 4.
write-spool $t1_spool [
    (make-msg 1)
    (make-msg 2)
    (make-msg 3)
    (make-dup-msg 2)   # duplicate of msg 2
    (make-msg 4)
    (make-dup-msg 4)   # duplicate of msg 4
    (make-msg 5)
]

# Before: 7 messages (5 unique, 2 duplicates)
assert equal (count-spool $t1_spool) 7 "pre: 7 messages in spool"

let r1 = run-compact $t1_spool --keep-last 200

assert equal $r1.original_count    7 "original_count"
assert equal $r1.duplicates_removed 2 "duplicates_removed"
assert equal $r1.trimmed_count     0 "trimmed_count (no trim needed)"
assert equal $r1.final_count       5 "final_count"
assert equal $r1.dry_run          false "dry_run flag"

# Spool now has 5 messages
assert equal (count-spool $t1_spool) 5 "spool has 5 messages after dedup"

# Unique Message-IDs only — each of 1..5 appears exactly once
let ids = spool-ids $t1_spool
assert equal ($ids | length) 5 "5 unique IDs remain"
assert ($ids | any {|id| $id | str contains "msg.1."}) "msg 1 present"
assert ($ids | any {|id| $id | str contains "msg.2."}) "msg 2 present"
assert ($ids | any {|id| $id | str contains "msg.3."}) "msg 3 present"
assert ($ids | any {|id| $id | str contains "msg.4."}) "msg 4 present"
assert ($ids | any {|id| $id | str contains "msg.5."}) "msg 5 present"

# Verify first occurrence is kept (task_id = "task-2", not "task-2-dup")
let content1 = open --raw $t1_spool
let msgs1 = parse-mbox $content1
let msg2 = $msgs1 | where {|m| (msg-id $m) == "<msg.2.test@smolfire.local>"} | first
assert ($msg2.body | str contains "task-2\"") "first occurrence of msg 2 kept"
assert (not ($msg2.body | str contains "task-2-dup")) "duplicate body not kept"

print "  PASS"

# ── Test 2: keep-last trims to N most recent messages ────────────────────────
print "test 2: keep-last trims oldest messages to N most recent"

let t2 = make-temp-dir
let t2_spool = [$t2, "var", "mail", "spool"] | path join

# Seed 50 unique messages
seed-spool $t2_spool 50

let r2 = run-compact $t2_spool --keep-last 20

assert equal $r2.original_count    50 "original_count"
assert equal $r2.duplicates_removed 0  "no duplicates"
assert equal $r2.trimmed_count     30 "trimmed_count (50 - 20)"
assert equal $r2.final_count       20 "final_count"
assert equal $r2.dry_run          false "dry_run flag"

# Spool now has exactly 20 messages
assert equal (count-spool $t2_spool) 20 "spool has 20 messages after trim"

# The 20 most recent messages (31..50) must be kept; oldest (1..30) dropped.
let ids2 = spool-ids $t2_spool
assert ($ids2 | any {|id| $id | str contains "msg.50."}) "msg 50 kept (newest)"
assert ($ids2 | any {|id| $id | str contains "msg.31."}) "msg 31 kept (boundary)"
let msg1_present = $ids2 | any {|id| $id == "<msg.1.test@smolfire.local>"}
assert (not $msg1_present) "msg 1 dropped (oldest)"
let msg30_present = $ids2 | any {|id| $id == "<msg.30.test@smolfire.local>"}
assert (not $msg30_present) "msg 30 dropped (just below boundary)"

print "  PASS"

# ── Test 3: dry-run makes no changes to the file ─────────────────────────────
print "test 3: --dry-run makes no changes to the spool file"

let t3 = make-temp-dir
let t3_spool = [$t3, "var", "mail", "spool"] | path join

# 10 messages with duplicates
write-spool $t3_spool [
    (make-msg 1)
    (make-msg 2)
    (make-dup-msg 1)   # duplicate
    (make-msg 3)
    (make-msg 4)
    (make-msg 5)
]

# Capture file content before the dry-run
let before_content = open --raw $t3_spool
let before_count = count-spool $t3_spool
assert equal $before_count 6 "pre: 6 messages"

let r3 = run-compact $t3_spool --keep-last 3 --dry-run

# dry-run must report what WOULD happen
assert equal $r3.original_count    6 "dry-run: original_count"
assert equal $r3.duplicates_removed 1 "dry-run: duplicates_removed"
assert equal $r3.trimmed_count     2 "dry-run: trimmed_count (5 - 3 = 2 after dedup)"
assert equal $r3.final_count       3 "dry-run: final_count"
assert equal $r3.dry_run          true "dry_run flag set"

# File must be completely unchanged
let after_content = open --raw $t3_spool
assert equal $after_content $before_content "spool content unchanged after dry-run"
assert equal (count-spool $t3_spool) 6 "spool count unchanged after dry-run"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All spool-compact tests passed."
