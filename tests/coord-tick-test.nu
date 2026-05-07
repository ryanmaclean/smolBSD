# SPDX-License-Identifier: Apache-2.0
# coord-tick-test.nu — integration tests for bin/coord-tick.nu FSM

use std assert

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a fresh temporary directory.
def make-temp-dir [] {
    ^mktemp -d | str trim
}

# Write a TOML state file at the given absolute path.
def write-state [path: string, state: record] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $state | to toml | save --force $path
}

# Read back the TOML state file.
def read-state [path: string] {
    open --raw $path | from toml
}

# Write raw mbox content to an absolute spool path.
def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

# Run one coordinator tick.
# --state-file and --spool are relative paths joined to --root inside coord-tick.nu.
def run-tick [
    root:      string
    state_rel: string   # relative to root
    spool_rel: string   # relative to root
] {
    ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $root | ignore
}

# Build a minimal mbox message string.
def make-msg [
    from_addr:  string
    to_addr:    string
    message_id: string
    body:       string
    --in-reply-to: string = ""
] {
    mut header_lines = [
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ]
    if $in_reply_to != "" {
        $header_lines = $header_lines | append $"In-Reply-To: ($in_reply_to)"
    }
    ($header_lines | str join "\n") + "\n\n" + $body + "\n"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

print "test 1: idle — no spool"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert equal $state.tick_count 1

    ^rm -rf $tmp
}

print "test 2: idle — spool exists but message already in seen_ids"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<already.seen@host>"
    let msg = make-msg "sender@host" "recipient@host" $msg_id 'task_id = "t0"'
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         1
        fsm_state:          "idle"
        seen_ids:           [$msg_id]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert equal $state.tick_count 2

    ^rm -rf $tmp
}

print "test 3: idle → harvesting → idle (reply message, pass verdict)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<reply.pass.001@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t1\""
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert ($msg_id in $state.seen_ids)

    ^rm -rf $tmp
}

print "test 4: idle → harvesting → dispatching → waiting (request message)"
do {
    # An unseen request (not addressed to coordinator, no In-Reply-To) triggers:
    # idle → harvesting → dispatching → waiting
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<request.t2.001@host>"
    let body = "task_id = \"t2\""
    let msg = make-msg "coordinator@smolbsd.local" "agent@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # After harvesting a request: dispatching appends to spool and transitions to waiting.
    assert equal $state.fsm_state "waiting"
    assert (($state.pending_request_id | str length) > 0)

    ^rm -rf $tmp
}

print "test 5: waiting → waiting (no matching reply in spool)"
do {
    # state-waiting checks for In-Reply-To matching pending_request_id.
    # No such message in spool → stays in waiting.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<unrelated.001@host>"
    let body = "task_id = \"other\""
    let msg = make-msg "sender@host" "recipient@host" $msg_id $body
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         3
        fsm_state:          "waiting"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: "<req.123@host>"
        pending_task_id:    "t2"
        pending_to_addr:    "agent@smolbsd.local"
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "waiting"

    ^rm -rf $tmp
}

print "test 6: waiting → harvesting (reply found — In-Reply-To matches)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let pending_id = "<req.123@host>"
    let reply_id   = "<reply.for.req123@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t2\""
    let msg = (make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $reply_id $body
               --in-reply-to $pending_id)
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         2
        fsm_state:          "waiting"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: $pending_id
        pending_task_id:    "t2"
        pending_to_addr:    "agent@smolbsd.local"
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # waiting detects reply → transitions to harvesting → processes reply → idle.
    assert ($reply_id in $state.seen_ids)
    assert (($state.fsm_state == "idle") or ($state.fsm_state == "harvesting"))

    ^rm -rf $tmp
}

print "test 7: HALT file present → halted"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"

    let halt_dir = [$tmp, "var", "mail"] | path join
    mkdir $halt_dir
    "" | save --force ([$halt_dir, "HALT"] | path join)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "halted"

    ^rm -rf $tmp
}

print "test 8: verdict fail → HALT file created"
do {
    # Harvesting a fail-verdict reply creates var/mail/HALT in the temp root.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<reply.fail.t3@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t3\""
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let halt_path = [$tmp, "var", "mail", "HALT"] | path join
    assert ($halt_path | path exists)

    ^rm -rf $tmp
}

print "test 9: attempt counter increments on fail"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<fail.1@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t-retry\""
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # attempt_counts should have an entry for t-retry (value >= 1)
    assert ($state | get -i attempt_counts | default {} | get -i t-retry | default 0) >= 1
    # retry should have been dispatched → waiting
    assert equal $state.fsm_state "waiting"

    ^rm -rf $tmp
}

print "test 10: retry exhausted → HALT file created"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Seed spool dir so HALT can be written
    let spool_dir = [$tmp, "var", "mail"] | path join
    mkdir $spool_dir

    # Manually write state with attempt_counts = {t-exhaust: 3}
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir
    (
        "version = \"1\"\n" +
        "tick_count = 0\n" +
        "fsm_state = \"idle\"\n" +
        "seen_ids = []\n" +
        "last_tick_at = \"2026-01-01T00:00:00Z\"\n" +
        "pending_request_id = \"\"\n" +
        "pending_task_id = \"\"\n" +
        "pending_to_addr = \"\"\n\n" +
        "[attempt_counts]\n" +
        "t-exhaust = 3\n"
    ) | save --force $state_abs

    let msg_id = "<fail.exhaust@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t-exhaust\""
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    # Accept either per-task HALT or bare HALT
    let halt1 = [$tmp, "var", "mail", "HALT.t-exhaust"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"] | path join
    assert (($halt1 | path exists) or ($halt2 | path exists))

    ^rm -rf $tmp
}

print "test 11: capability mismatch → message skipped, no dispatch"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<cap.mismatch.t-cap@host>"
    let body = "task_id = \"t-cap\"\nagent_type = \"reviewer\"\ntools_required = [\"Write\", \"Bash\"]"
    # outbound request (not to coordinator)
    let msg = make-msg "coordinator@smolbsd.local" "reviewer@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # reviewer lacks Write/Bash → skipped, no dispatch → idle
    assert equal $state.fsm_state "idle"
    assert ($msg_id in $state.seen_ids)

    ^rm -rf $tmp
}

print "test 12: attestation fail → treated as retry"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<attest.fail.t-attest@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t-attest\"\nattestation_required = true"
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # pass without claims → MALFORMED → retry → waiting
    assert equal $state.fsm_state "waiting"
    assert ($state | get -i attempt_counts | default {} | get -i t-attest | default 0) >= 1

    ^rm -rf $tmp
}

print "test 13: blocked+no-unblocker → immediate HALT, no retry"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<blocked.no-unblocker.t-block@host>"
    let body = "verdict = \"blocked\"\ntask_id = \"t-block\""
    let msg = make-msg "agent@smolbsd.local" "coordinator@smolbsd.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    # HALT file must exist
    let halt1 = [$tmp, "var", "mail", "HALT.t-block"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"] | path join
    assert (($halt1 | path exists) or ($halt2 | path exists))

    # No retry should have been attempted (attempt_counts for t-block == 0 or absent)
    let state = read-state $state_abs
    let attempt = $state | get -i attempt_counts | default {} | get -i t-block | default 0
    assert equal $attempt 0

    ^rm -rf $tmp
}

print "all tests passed"
