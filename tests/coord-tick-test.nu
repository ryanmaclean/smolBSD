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

print "all tests passed"
