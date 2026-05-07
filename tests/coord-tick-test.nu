# SPDX-License-Identifier: Apache-2.0
# coord-tick-test.nu — test suite for bin/coord-tick.nu and bin/mbox-parse.nu
#
# Run from the project root:
#   nu --no-config-file tests/coord-tick-test.nu
#
# Exit code: 0 if all assertions pass, 1 if any fail.

use ../bin/mbox-parse.nu [parse-mbox, extract-toml, msg-id]

# ── Assertion helper ──────────────────────────────────────────────────────────

# Print PASS or FAIL with label.  Returns true on pass, false on fail.
# Comparison is by string representation so scalars, lists, and records all work.
def assert-eq [got: any, expected: any, label: string] {
    let g = $got      | into string
    let e = $expected | into string
    if $g == $e {
        print $"PASS  ($label)"
        true
    } else {
        print $"FAIL  ($label)"
        print $"      got:      ($g)"
        print $"      expected: ($e)"
        false
    }
}

# Accumulate pass/fail counts across a test run.
# Usage: let results = []; $results | append (assert-eq ...)
# Then check ($results | all {|r| $r}) at the end.

# ── Fixtures ──────────────────────────────────────────────────────────────────

# Three-message mbox fixture used by the mbox-parse and FSM tests.
#
# Msg 1 (coordinator dispatch): From coordinator→builder, no In-Reply-To.
# Msg 2 (agent reply):          From builder→coordinator, In-Reply-To msg1.
# Msg 3 (unmatched dispatch):   From coordinator→architect, no In-Reply-To.
#
# NOTE: The mbox format requires the first "From " to be at the very start of
# the string (position 0), with no leading newline.  Subsequent messages are
# delimited by "\nFrom ".
def fixture-mbox [] {
"From smolbsd-coord Mon Jan 01 00:00:00 2026
From: coordinator@smolbsd.local
To: builder@smolbsd.local
Subject: [task-A] build baseline
Message-ID: <task-A.coord@smolbsd.local>
X-Project: smolbsd
Content-Type: text/toml; charset=utf-8

task_id = \"task-A\"
verdict = \"none\"
title = \"Build baseline image\"

From smolbsd-builder Mon Jan 01 00:01:00 2026
From: builder@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-A] build baseline
Message-ID: <task-A.builder@smolbsd.local>
In-Reply-To: <task-A.coord@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-A\"
verdict = \"pass\"
note = \"image boots cleanly\"

From smolbsd-coord Mon Jan 01 00:02:00 2026
From: coordinator@smolbsd.local
To: architect@smolbsd.local
Subject: [task-B] design phase-ii
Message-ID: <task-B.coord@smolbsd.local>
X-Project: smolbsd
Content-Type: text/toml; charset=utf-8

task_id = \"task-B\"
verdict = \"none\"
title = \"Design Phase-II physical boot\"
"
}

# A three-message mbox where all messages are agent replies (To: coordinator).
# Used for the clean idle→harvesting→idle FSM test.
def fixture-mbox-replies [] {
"From smolbsd-builder Mon Jan 01 00:00:00 2026
From: builder@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-R1]
Message-ID: <task-R1.builder@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-R1\"
verdict = \"pass\"

From smolbsd-architect Mon Jan 01 00:01:00 2026
From: architect@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-R2]
Message-ID: <task-R2.architect@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-R2\"
verdict = \"pass\"

From smolbsd-reviewer Mon Jan 01 00:02:00 2026
From: reviewer@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-R3]
Message-ID: <task-R3.reviewer@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-R3\"
verdict = \"fail\"
"
}

# ── mbox-parse tests ──────────────────────────────────────────────────────────

def test-parse-mbox [] {
    print "\n=== parse-mbox tests ==="

    let msgs = parse-mbox (fixture-mbox)
    mut results = []

    # T1: correct message count
    $results = $results | append (assert-eq ($msgs | length) 3 "parse-mbox: returns 3 messages")

    # T2: first message from_line preserved
    let fl0 = $msgs | get 0 | get from_line
    $results = $results | append (assert-eq ($fl0 | str starts-with "From smolbsd-coord") true "parse-mbox: msg0 from_line starts with 'From smolbsd-coord'")

    # T3: Message-ID headers parsed correctly for all three messages
    $results = $results | append (assert-eq (msg-id ($msgs | get 0)) "<task-A.coord@smolbsd.local>"    "msg-id: msg0 = <task-A.coord@smolbsd.local>")
    $results = $results | append (assert-eq (msg-id ($msgs | get 1)) "<task-A.builder@smolbsd.local>"  "msg-id: msg1 = <task-A.builder@smolbsd.local>")
    $results = $results | append (assert-eq (msg-id ($msgs | get 2)) "<task-B.coord@smolbsd.local>"    "msg-id: msg2 = <task-B.coord@smolbsd.local>")

    # T4: From/To headers parsed
    let h0 = $msgs | get 0 | get headers
    $results = $results | append (assert-eq ($h0 | get "From"?) "coordinator@smolbsd.local" "parse-mbox: msg0 From header")
    $results = $results | append (assert-eq ($h0 | get "To"?)   "builder@smolbsd.local"     "parse-mbox: msg0 To header")

    # T5: In-Reply-To present on msg1, absent on msg0
    let h1 = $msgs | get 1 | get headers
    $results = $results | append (assert-eq ($h1 | get "In-Reply-To"?) "<task-A.coord@smolbsd.local>" "parse-mbox: msg1 In-Reply-To")
    let h0_irt = $h0 | get "In-Reply-To"? | default ""
    $results = $results | append (assert-eq $h0_irt "" "parse-mbox: msg0 has no In-Reply-To")

    $results
}

# ── extract-toml tests ────────────────────────────────────────────────────────

def test-extract-toml [] {
    print "\n=== extract-toml tests ==="

    let msgs = parse-mbox (fixture-mbox)
    mut results = []

    # T6: msg0 body parses cleanly — no _parse_error key
    let p0 = extract-toml ($msgs | get 0)
    $results = $results | append (assert-eq ("_parse_error" in $p0) false "extract-toml: msg0 has no _parse_error")

    # T7: task_id field correct in msg0
    $results = $results | append (assert-eq ($p0 | get "task_id"? | default "") "task-A" "extract-toml: msg0 task_id = task-A")

    # T8: verdict field correct in msg1 (the reply)
    let p1 = extract-toml ($msgs | get 1)
    $results = $results | append (assert-eq ($p1 | get "verdict"? | default "") "pass" "extract-toml: msg1 verdict = pass")

    # T9: note field present in msg1
    $results = $results | append (assert-eq ($p1 | get "note"? | default "") "image boots cleanly" "extract-toml: msg1 note field")

    # T10: malformed body returns _parse_error
    let bad_msg = {from_line: "From x", headers: {}, body: "this is not toml :::"}
    let bad_parsed = extract-toml $bad_msg
    $results = $results | append (assert-eq ("_parse_error" in $bad_parsed) true "extract-toml: malformed body yields _parse_error")

    # T11: empty body returns _parse_error
    let empty_msg = {from_line: "From x", headers: {}, body: ""}
    let empty_parsed = extract-toml $empty_msg
    $results = $results | append (assert-eq ("_parse_error" in $empty_parsed) true "extract-toml: empty body yields _parse_error")

    $results
}

# ── msg-id edge cases ─────────────────────────────────────────────────────────

def test-msg-id [] {
    print "\n=== msg-id tests ==="

    mut results = []

    # T12: absent Message-ID returns empty string
    let no_id_msg = {from_line: "From x", headers: {From: "a@b"}, body: ""}
    $results = $results | append (assert-eq (msg-id $no_id_msg) "" "msg-id: absent Message-ID returns empty string")

    # T13: present Message-ID returned verbatim
    let id_msg = {from_line: "From x", headers: {"Message-ID": "<abc@def>"}, body: ""}
    $results = $results | append (assert-eq (msg-id $id_msg) "<abc@def>" "msg-id: present Message-ID returned verbatim")

    $results
}

# ── FSM integration: idle→harvesting→idle (reply-only fixture) ────────────────

def test-fsm-idle-harvest-idle [] {
    print "\n=== FSM idle→harvesting→idle (reply-only fixture) ==="

    let tmp      = $"/tmp/coord-tick-test-(random uuid)"
    let spool    = $"($tmp)/spool"
    let statef   = $"($tmp)/state.toml"

    mkdir $tmp
    (fixture-mbox-replies) | save $spool

    # Run one full coordinator tick (max-ticks high enough to quiesce).
    # Suppress log output — we only care about the final state file.
    nu --no-config-file bin/coord-tick.nu --spool $spool --state-file $statef --root . --max-ticks 20 out+err> /dev/null

    let final = open --raw $statef | from toml

    mut results = []

    # T14: FSM quiesces back to idle
    $results = $results | append (assert-eq $final.fsm_state "idle" "FSM reply-only: final fsm_state = idle")

    # T15: all 3 messages marked seen
    $results = $results | append (assert-eq ($final.seen_ids | length) 3 "FSM reply-only: seen_ids count = 3")

    # T16: tick_count = 2 (tick 1 = idle→harvesting, tick 2 = harvesting→idle)
    $results = $results | append (assert-eq $final.tick_count 2 "FSM reply-only: tick_count = 2")

    # T17: all three Message-IDs appear in seen_ids
    $results = $results | append (assert-eq ("<task-R1.builder@smolbsd.local>" in $final.seen_ids) true "FSM reply-only: task-R1 in seen_ids")
    $results = $results | append (assert-eq ("<task-R2.architect@smolbsd.local>" in $final.seen_ids) true "FSM reply-only: task-R2 in seen_ids")
    $results = $results | append (assert-eq ("<task-R3.reviewer@smolbsd.local>" in $final.seen_ids) true "FSM reply-only: task-R3 in seen_ids")

    rm -rf $tmp
    $results
}

# ── FSM integration: mixed fixture (coord dispatch + reply + unmatched) ───────
#
# Expected FSM trace (max-ticks 20):
#   tick 1: idle        — finds 3 new messages → transition to harvesting
#   tick 2: harvesting  — task-A.coord is "request" with no IRT → queue_dispatch
#                         adds task-A.coord to seen_ids, → dispatching
#   tick 3: dispatching — pending_dispatch → write pending record → waiting
#   tick 4: waiting     — finds task-A.builder (IRT = task-A.coord) → reply_received
#                         adds task-A.builder to seen_ids → harvesting (no further tick)
#
# Final state: fsm_state=harvesting, tick_count=4, seen_ids=[task-A.coord, task-A.builder]

def test-fsm-mixed-fixture [] {
    print "\n=== FSM mixed fixture (dispatch+reply+unmatched) ==="

    let tmp      = $"/tmp/coord-tick-test-(random uuid)"
    let spool    = $"($tmp)/spool"
    let statef   = $"($tmp)/state.toml"

    mkdir $tmp
    (fixture-mbox) | save $spool

    nu --no-config-file bin/coord-tick.nu --spool $spool --state-file $statef --root . --max-ticks 20 out+err> /dev/null

    let final = open --raw $statef | from toml

    mut results = []

    # T18: FSM lands in harvesting (reply detected, handed back to harvesting)
    $results = $results | append (assert-eq $final.fsm_state "harvesting" "FSM mixed: final fsm_state = harvesting")

    # T19: tick_count = 4
    $results = $results | append (assert-eq $final.tick_count 4 "FSM mixed: tick_count = 4")

    # T20: exactly 2 messages seen (task-A.coord queued in harvesting, task-A.builder found in waiting)
    $results = $results | append (assert-eq ($final.seen_ids | length) 2 "FSM mixed: seen_ids count = 2")

    # T21: task-A.coord in seen_ids (marked seen before dispatching)
    $results = $results | append (assert-eq ("<task-A.coord@smolbsd.local>" in $final.seen_ids) true "FSM mixed: task-A.coord in seen_ids")

    # T22: task-A.builder in seen_ids (marked seen when reply found in waiting)
    $results = $results | append (assert-eq ("<task-A.builder@smolbsd.local>" in $final.seen_ids) true "FSM mixed: task-A.builder in seen_ids")

    # T23: task-B.coord NOT yet seen (harvesting for it hasn't run)
    $results = $results | append (assert-eq ("<task-B.coord@smolbsd.local>" in $final.seen_ids) false "FSM mixed: task-B.coord not yet in seen_ids")

    rm -rf $tmp
    $results
}

# ── FSM: spool-absent guard ───────────────────────────────────────────────────

def test-fsm-spool-absent [] {
    print "\n=== FSM spool-absent guard ==="

    let tmp    = $"/tmp/coord-tick-test-(random uuid)"
    let spool  = $"($tmp)/no-such-spool"
    let statef = $"($tmp)/state.toml"

    mkdir $tmp

    nu --no-config-file bin/coord-tick.nu --spool $spool --state-file $statef --root . --max-ticks 5 out+err> /dev/null

    let final = open --raw $statef | from toml

    mut results = []

    # T24: stays idle when spool is absent
    $results = $results | append (assert-eq $final.fsm_state "idle" "FSM spool-absent: fsm_state = idle")

    # T25: tick_count = 1 (one idle tick that found no spool)
    $results = $results | append (assert-eq $final.tick_count 1 "FSM spool-absent: tick_count = 1")

    # T26: seen_ids empty
    $results = $results | append (assert-eq ($final.seen_ids | length) 0 "FSM spool-absent: seen_ids empty")

    rm -rf $tmp
    $results
}

# ── Main runner ───────────────────────────────────────────────────────────────

def main [] {
    print "coord-tick-test.nu — smolBSD coordinator test suite"
    print "===================================================="

    mut all_results = []

    $all_results = $all_results | append (test-parse-mbox)
    $all_results = $all_results | append (test-extract-toml)
    $all_results = $all_results | append (test-msg-id)
    $all_results = $all_results | append (test-fsm-idle-harvest-idle)
    $all_results = $all_results | append (test-fsm-mixed-fixture)
    $all_results = $all_results | append (test-fsm-spool-absent)

    let total  = $all_results | length
    let passed = $all_results | where {|r| $r == true}  | length
    let failed = $total - $passed

    print $"\n===================================================="
    print $"Results: ($passed)/($total) passed, ($failed) failed"

    if $failed > 0 {
        exit 1
    }
}
