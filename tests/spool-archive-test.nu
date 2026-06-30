# SPDX-License-Identifier: Apache-2.0
# spool-archive-test.nu — hermetic tests for bin/spool-archive.nu
#
# Run from repo root:
#   nu tests/spool-archive-test.nu

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
    let id = $"<msg.($idx).test@smolbsd.local>"
    $"From agent@smolbsd.local Wed Jan  1 00:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Message-ID: ($id)
Content-Type: text/toml; charset=utf-8

task_id = \"task-($idx)\"
verdict = \"pass\"
"
}

# Write N messages into a spool file at the given path.
def seed-spool [path: string, count: int] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    # Start fresh
    "" | save --force $path
    for i in 1..($count) {
        (make-msg $i) | save --append $path
    }
}

# Count messages in a spool file (returns 0 if file absent).
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

# Write a minimal coord-state.toml with the given pending_request_id.
def write-state [path: string, pending_id: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    {
        version:            "1"
        tick_count:         0
        fsm_state:          "waiting"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: $pending_id
        pending_task_id:    "task-pending"
        pending_to_addr:    "agent@smolbsd.local"
        dispatched_at:      "2026-01-01T00:00:00Z"
        attempt_counts:     {}
        halted_tasks:       []
    } | to toml | save --force $path
}

# Run spool-archive.nu with the given flags, returning stdout as a parsed record.
# We pass explicit --root, --spool, --state to keep tests hermetic.
def run-archive [
    root:      string
    --threshold: int = 100
    --dry-run
    --spool:   string = "var/mail/spool"
    --state:   string = "var/run/coord-state.toml"
] {
    let dry_flag = if $dry_run { ["--dry-run"] } else { [] }
    # Run archive; capture stdout only (stderr log lines go to /dev/null).
    # We use a shell wrapper so we can redirect stderr cleanly.
    let cmd_args = (
        [
            "bin/spool-archive.nu"
            "--root" $root
            "--threshold" ($threshold | into string)
            "--spool" $spool
            "--state" $state
        ] | append $dry_flag | str join " "
    )
    let raw = ^sh -c $"nu ($cmd_args) 2>/dev/null"
    # Output is a compact JSON line emitted by the archive script.
    $raw | str trim | from json
}

# ── Test 1: basic rotation — 150 msgs, threshold 50 ─────────────────────────
print "test 1: basic rotation (150 → keep 50, archive 100)"

let t1 = make-temp-dir
let t1_spool = [$t1, "var", "mail", "spool"] | path join
let t1_state = [$t1, "var", "run", "coord-state.toml"] | path join

seed-spool $t1_spool 150

# Write empty state (no pending request)
write-state $t1_state ""

let r1 = run-archive $t1 --threshold 50

assert equal $r1.archived_count 100  "archived_count"
assert equal $r1.active_count    50  "active_count"
assert (($r1.archive_path | str length) > 0) "archive_path set"
assert equal ($r1.skipped_reason | describe) "nothing" "skipped_reason is null"

# Active spool should now have exactly 50 messages
let active_count = count-spool $t1_spool
assert equal $active_count 50 "active spool message count"

# Archive file should have exactly 100 messages
let archive_count = count-spool $r1.archive_path
assert equal $archive_count 100 "archive file message count"

# Total must be preserved: 50 + 100 = 150
assert equal ($active_count + $archive_count) 150 "total preserved"

# Oldest messages go to the archive, newest stay active.
# msg-1 through msg-100 should be in archive; msg-101 through msg-150 active.
let active_ids  = spool-ids $t1_spool
let archive_ids = spool-ids $r1.archive_path

assert ($active_ids  | any {|id| $id | str contains "msg.150."}) "msg 150 in active"
assert ($active_ids  | any {|id| $id | str contains "msg.101."}) "msg 101 in active"
assert ($archive_ids | any {|id| $id | str contains "msg.1."})   "msg 1 in archive"
assert ($archive_ids | any {|id| $id | str contains "msg.100."}) "msg 100 in archive"
# msg 1 must NOT be in active spool
let msg1_in_active = $active_ids | any {|id| $id == "<msg.1.test@smolbsd.local>"}
assert (not $msg1_in_active) "msg 1 not in active"

print "  PASS"

# ── Test 2: --dry-run leaves files untouched ─────────────────────────────────
print "test 2: --dry-run leaves files untouched"

let t2 = make-temp-dir
let t2_spool = [$t2, "var", "mail", "spool"] | path join
let t2_state = [$t2, "var", "run", "coord-state.toml"] | path join

seed-spool $t2_spool 80
write-state $t2_state ""

let r2 = run-archive $t2 --threshold 50 --dry-run

# dry-run should report what would happen
assert equal $r2.archived_count 30 "dry-run archived_count"
assert equal $r2.active_count   50 "dry-run active_count"
assert ($r2.skipped_reason | str contains "dry-run") "dry-run skipped_reason"

# Spool must be untouched — still 80 messages
assert equal (count-spool $t2_spool) 80 "spool unchanged after dry-run"

# Archive file must NOT exist
let t2_archive = $r2.archive_path
assert (not ($t2_archive | path exists)) "archive file not created in dry-run"

print "  PASS"

# ── Test 3: below threshold — no-op ──────────────────────────────────────────
print "test 3: spool below threshold — no operation"

let t3 = make-temp-dir
let t3_spool = [$t3, "var", "mail", "spool"] | path join
let t3_state = [$t3, "var", "run", "coord-state.toml"] | path join

seed-spool $t3_spool 30
write-state $t3_state ""

let r3 = run-archive $t3 --threshold 50

assert equal $r3.archived_count 0  "no-op archived_count"
assert equal $r3.active_count  30  "no-op active_count"
assert (($r3.skipped_reason | str length) > 0) "no-op skipped_reason set"
assert equal (count-spool $t3_spool) 30 "spool unchanged when below threshold"

print "  PASS"

# ── Test 4: pending_request_id protection ────────────────────────────────────
print "test 4: pending_request_id blocks archive when live msg would be orphaned"

let t4 = make-temp-dir
let t4_spool = [$t4, "var", "mail", "spool"] | path join
let t4_state = [$t4, "var", "run", "coord-state.toml"] | path join

seed-spool $t4_spool 150

# Make the FSM state claim that message #5 (which would be in the archive set)
# is the pending request in flight.
let protected_id = "<msg.5.test@smolbsd.local>"
write-state $t4_state $protected_id

let r4 = run-archive $t4 --threshold 50

# Archive should be blocked
assert equal $r4.archived_count 0 "blocked archived_count"
assert equal $r4.active_count 150 "spool count unchanged"
assert ($r4.skipped_reason | str contains $protected_id) "skipped_reason mentions blocked id"

# Spool file must be unmodified — still 150 messages
assert equal (count-spool $t4_spool) 150 "spool unchanged when blocked"

print "  PASS"

# ── Test 5: pending_request_id is in the KEEP set — archive proceeds ─────────
print "test 5: pending_request_id in keep set — archive proceeds normally"

let t5 = make-temp-dir
let t5_spool = [$t5, "var", "mail", "spool"] | path join
let t5_state = [$t5, "var", "run", "coord-state.toml"] | path join

seed-spool $t5_spool 150

# Message #140 would be in the keep set (newest 100, i.e. 51–150).
# So the archive should proceed without blocking.
let safe_id = "<msg.140.test@smolbsd.local>"
write-state $t5_state $safe_id

let r5 = run-archive $t5 --threshold 100

assert equal $r5.archived_count 50  "safe pending: archived_count"
assert equal $r5.active_count  100  "safe pending: active_count"
assert equal ($r5.skipped_reason | describe) "nothing" "safe pending: no skip"
assert equal (count-spool $t5_spool) 100 "safe pending: active spool count"

print "  PASS"

# ── Test 6: same-day append — archive file grows, not clobbered ───────────────
print "test 6: same-day append — second run appends to existing archive"

let t6 = make-temp-dir
let t6_spool = [$t6, "var", "mail", "spool"] | path join
let t6_state = [$t6, "var", "run", "coord-state.toml"] | path join

# First run: 150 messages, keep 100 → archives 50
seed-spool $t6_spool 150
write-state $t6_state ""
let r6a = run-archive $t6 --threshold 100

assert equal $r6a.archived_count 50 "first run archived_count"

# Second run: add 60 more messages → total 160, archive 60 more to SAME file
for i in 151..210 {
    (make-msg $i) | save --append $t6_spool
}

let r6b = run-archive $t6 --threshold 100

# Both runs use the same UTC date → same archive path
assert equal $r6a.archive_path $r6b.archive_path "same archive path both runs"

# Archive file should now have 50 + 60 = 110 messages
let arc_count = count-spool $r6b.archive_path
assert equal $arc_count 110 "archive appended, not clobbered"

# Active spool still 100
assert equal (count-spool $t6_spool) 100 "active spool still 100 after second run"

print "  PASS"

# ── Done ─────────────────────────────────────────────────────────────────────
print ""
print "All spool-archive tests passed."
