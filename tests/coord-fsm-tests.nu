# SPDX-License-Identifier: Apache-2.0
# tests/coord-fsm-tests.nu — integration tests for the coord-tick.nu FSM
#
# Each test is hermetic: it creates a temp directory, exercises the FSM
# via `nu bin/coord-tick.nu`, reads back the state file, then cleans up.
#
# All tests return {name, status, detail} and are collected by run-coord-fsm-tests.

use ../bin/mbox-parse.nu [parse-mbox, msg-id]

# ── Helper: run coord-tick in a subprocess ─────────────────────────────────────

# Run coord-tick.nu once with the given temp root directory.
# spool and state paths are passed as relative paths (they get joined to root inside coord-tick).
# Returns {stdout, exit_code, state} where state is the parsed TOML state record (or {}).
def run-coord [
    root:      string        # temp root directory
    spool_rel: string        # spool path relative to root (e.g. "var/mail/spool")
    state_rel: string        # state-file path relative to root (e.g. "var/run/coord-state.toml")
    max_ticks: int = 5
] {
    let result = (^nu --no-config-file bin/coord-tick.nu
        --root $root
        --spool $spool_rel
        --state-file $state_rel
        --max-ticks $max_ticks
    ) | complete

    let state_path = [$root, $state_rel] | path join
    let state = if ($state_path | path exists) {
        try { open --raw $state_path | from toml } catch { {} }
    } else {
        {}
    }

    {
        stdout:    $result.stdout
        exit_code: $result.exit_code
        state:     $state
    }
}

# Create a minimal temp root with the required sub-directories.
# Returns the temp root path string.
def make-temp-root [] {
    let tmp = ^mktemp -d | str trim
    mkdir ($tmp | path join "var" "mail")
    mkdir ($tmp | path join "var" "run")
    $tmp
}

# Remove the temp root directory.
def cleanup [root: string] {
    if ($root | path exists) {
        rm -rf $root
    }
}

# Build a minimal mbox reply envelope (agent→coordinator).
def make-reply-msg [
    msg_id:     string   # e.g. "<task-0001.tester@smolbsd.local>"
    in_reply_to: string  # e.g. "<task-0001.coord@smolbsd.local>"  (empty string for fresh messages)
] {
    let dstamp = "Mon May  4 10:00:00 2026"
    let ts     = "Mon, 4 May 2026 10:00:00 -0000"
    let irt_header = if ($in_reply_to | str length) > 0 {
        $"In-Reply-To: ($in_reply_to)\n"
    } else {
        ""
    }

    $"From agent@smolbsd.local ($dstamp)\nFrom: agent@smolbsd.local\nTo: coordinator@smolbsd.local\nSubject: reply to task\nDate: ($ts)\nMessage-ID: ($msg_id)\n($irt_header)Content-Type: text/toml; charset=utf-8\n\ntask_id = \"test-task\"\nverdict  = \"pass\"\n"
}

# ── Test 1: idle → no-op when spool is empty ──────────────────────────────────

def test-idle-empty-spool [] {
    let name = "FSM: idle stays idle on empty spool"
    let root = make-temp-root

    # Create an empty spool file.
    "" | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 3

    let state = $r.state

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "idle"
        and ($state | get seen_ids? | default [] | length) == 0
        and ($state | get tick_count? | default 0) >= 1
        and ([$root, "var/run/coord-state.toml"] | path join | path exists)
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"exit=($r.exit_code) fsm_state=idle seen_ids=0"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) state=($state | to nuon)"}
    }
}

# ── Test 2: idle → harvesting → idle on one inbound reply message ─────────────

def test-idle-to-harvesting-to-idle [] {
    let name = "FSM: idle->harvesting->idle on new message"
    let root = make-temp-root

    let msg_id = "<task-0001.tester@smolbsd.local>"
    let envelope = make-reply-msg $msg_id ""

    $envelope | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state = $r.state
    let seen  = $state | get seen_ids? | default []

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "idle"
        and ($seen | length) == 1
        and ($seen | any {|id| $id == $msg_id})
        and ($r.stdout | str contains "harvest_message")
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"seen_ids=($seen | to nuon) harvest_message logged"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) state=($state | to nuon) stdout_snippet=($r.stdout | str substring ..300)"}
    }
}

# ── Test 3: dispatching → waiting → idle cycle ────────────────────────────────

def test-dispatching-to-waiting-to-idle [] {
    let name = "FSM: dispatching->waiting->idle cycle"
    let root = make-temp-root

    let task_id   = "task-0002"
    let spool_path = $root | path join "var" "mail" "spool"

    # Seed state: FSM in "dispatching" with a pending_dispatch record.
    let seed_state = {
        version:          "1"
        tick_count:       0
        fsm_state:        "dispatching"
        seen_ids:         []
        last_tick_at:     "2026-05-04T10:00:00Z"
        pending_dispatch: {
            task_id:   $task_id
            to_role:   "builder@smolbsd.local"
            subject:   "Test dispatch"
            toml_body: "task_id = \"task-0002\"\naction = \"build\"\n"
        }
        dispatch_pid:     0
    }

    let state_path = $root | path join "var" "run" "coord-state.toml"
    $seed_state | to toml | save $state_path

    # Start with empty spool.
    "" | save $spool_path

    # First tick: dispatching → writes envelope → moves to waiting.
    let r1 = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 3

    let state1        = $r1.state
    let spool_content = open --raw $spool_path
    let spool_msgs    = parse-mbox $spool_content

    let dispatched_ok = (
        $r1.exit_code == 0
        and ($state1 | get fsm_state? | default "") == "waiting"
        and ($spool_msgs | length) > 0
        and ($r1.stdout | str contains "dispatched")
    )

    if not $dispatched_ok {
        cleanup $root
        return {
            name: $name
            status: "fail"
            detail: $"tick1: exit=($r1.exit_code) fsm=($state1.fsm_state? | default '?') spool_msgs=($spool_msgs | length) stdout=($r1.stdout | str substring ..300)"
        }
    }

    # Now add a reply to the spool that references the dispatched task's Message-ID.
    let reply_irt = $"<($task_id).coord@smolbsd.local>"
    let reply_id  = "<task-0002.reply@smolbsd.local>"
    let reply_env = make-reply-msg $reply_id $reply_irt
    $reply_env | save --append $spool_path

    # Second tick: waiting → reply found → harvesting → idle.
    let r2     = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5
    let state2 = $r2.state
    let seen2  = $state2 | get seen_ids? | default []

    let ok = (
        $r2.exit_code == 0
        and ($state2 | get fsm_state? | default "") == "idle"
        and ($seen2 | any {|id| $id == $reply_id})
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"dispatch->waiting->idle complete; reply_id in seen_ids"}
    } else {
        {name: $name, status: "fail", detail: $"tick2: exit=($r2.exit_code) fsm=($state2 | get fsm_state? | default '?') seen=($seen2 | to nuon) stdout=($r2.stdout | str substring ..300)"}
    }
}

# ── Test 4: HALT detection ────────────────────────────────────────────────────

def test-halt-detection [] {
    let name = "FSM: HALT marker stops FSM immediately"
    let root = make-temp-root

    # Write the HALT marker at var/mail/HALT (relative to root, per halt-present).
    let halt_path = $root | path join "var" "mail" "HALT"
    "reason = \"test halt\"\n" | save $halt_path

    # Empty spool (no messages should be written).
    "" | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state          = $r.state
    let spool_after    = open --raw ($root | path join "var" "mail" "spool")
    let spool_msgs     = parse-mbox $spool_after

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "halted"
        and ($spool_msgs | length) == 0
        and ($r.stdout | str contains "halted")
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: "fsm_state=halted, spool untouched, 'halted' in stdout"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) fsm=($state | get fsm_state? | default '?') spool_msgs=($spool_msgs | length) stdout=($r.stdout | str substring ..300)"}
    }
}

# ── Test 5: malformed message body ────────────────────────────────────────────

def test-malformed-message [] {
    let name = "FSM: malformed message body does not crash FSM"
    let root = make-temp-root

    # A valid mbox envelope but with a non-TOML body.
    let msg_id  = "<task-0003.malformed@smolbsd.local>"
    let dstamp  = "Mon May  4 10:00:00 2026"
    let ts      = "Mon, 4 May 2026 10:00:00 -0000"
    let envelope = $"From agent@smolbsd.local ($dstamp)\nFrom: agent@smolbsd.local\nTo: coordinator@smolbsd.local\nSubject: malformed body test\nDate: ($ts)\nMessage-ID: ($msg_id)\nContent-Type: text/toml; charset=utf-8\n\nThis is NOT valid TOML @@@@\n= broken [\n"

    $envelope | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state = $r.state

    let ok = (
        $r.exit_code == 0
        and ($r.stdout | str contains "harvest_malformed")
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: "exit=0, harvest_malformed logged"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) stdout=($r.stdout | str substring ..400)"}
    }
}

# ── Public entry point ────────────────────────────────────────────────────────

# Run all FSM integration tests and return a list of {name, status, detail}.
export def run-coord-fsm-tests [] {
    mut results = []

    $results = $results | append (try { test-idle-empty-spool }            catch {|e| {name: "FSM: idle stays idle on empty spool",            status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-idle-to-harvesting-to-idle }  catch {|e| {name: "FSM: idle->harvesting->idle on new message",      status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-dispatching-to-waiting-to-idle } catch {|e| {name: "FSM: dispatching->waiting->idle cycle",        status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-halt-detection }               catch {|e| {name: "FSM: HALT marker stops FSM immediately",         status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-malformed-message }            catch {|e| {name: "FSM: malformed message body does not crash FSM", status: "fail", detail: $"exception: ($e.msg)"}})

    $results
}
