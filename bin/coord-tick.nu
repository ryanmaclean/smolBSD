# SPDX-License-Identifier: Apache-2.0
# coord-tick.nu — smolBSD coordinator tick (actor model, tail-recursive FSM)
#
# Each invocation of `main` is ONE tick of the coordinator actor.
# State is loaded from --state-file at startup and saved back at exit.
# No global mutable state; every transition is a `tick` call with a new record.
#
# FSM states (per spec §12):
#   idle         — no work in progress; scan spool for new messages
#   dispatching  — writing a request into the spool and queuing a subagent launch
#   waiting      — request dispatched, awaiting reply (not yet implemented)
#   harvesting   — new replies present; cross-check claims
#   halted       — var/mail/HALT file exists; block until user clears it
#
# HALT check: one `stat var/mail/HALT` per tick entry — O(1) per spec §13.

use mbox-parse.nu [parse-mbox, extract-toml, msg-id]

const STATE_VERSION = "1"

# Default state for a fresh coordinator with no prior history.
def default-state [] {
    {
        version:            $STATE_VERSION
        tick_count:         0
        fsm_state:          "idle"
        seen_ids:           []
        last_tick_at:       (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
    }
}

# Load state from TOML file, or return the default if file absent / parse fails.
# Missing keys are filled in from default-state so old state files remain compatible.
def load-state [path: string] {
    if not ($path | path exists) {
        log-event "state_init" {path: $path, reason: "file absent"}
        return (default-state)
    }
    try {
        let loaded = open --raw $path | from toml
        (default-state) | merge $loaded
    } catch {|err|
        log-event "state_load_error" {path: $path, error: ($err | get msg? | default "parse error")}
        default-state
    }
}

# Persist state back to disk as TOML.
def save-state [state: record, path: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) {
        mkdir $dir
    }
    $state | to toml | save --force $path
}

# Emit a structured TOML log line to stdout.
# Every coordinator action is observable via stdout — pipe to `tee` if needed.
def log-event [event: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, event: $event} | merge $payload
    $row | to toml | print
    print "---"
}

# Check whether the HALT marker exists.
# Per spec §13: one stat per tick — do not call this in a loop.
def halt-present [root: string] {
    let halt_path = [$root, "var", "mail", "HALT"] | path join
    $halt_path | path exists
}

# ── FSM states ────────────────────────────────────────────────────────────────

# idle: scan spool for new messages not in seen_ids.
# If unseen replies are found, transition to harvesting.
# If no new messages, remain idle and finish this tick.
def state-idle [state: record, spool: string, root: string, remaining: int] {
    if not ($spool | path exists) {
        log-event "spool_absent" {spool: $spool}
        return ($state | update fsm_state "idle")
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    let new_msgs = (
        $messages
        | where {|m|
            let id = msg-id $m
            $id != "" and not ($id in $state.seen_ids)
        }
    )

    if ($new_msgs | length) == 0 {
        log-event "idle_no_new_messages" {spool: $spool, total_msgs: ($messages | length)}
        return ($state | update fsm_state "idle")
    }

    log-event "idle_new_messages_found" {count: ($new_msgs | length)}
    # Transition to harvesting — process the unseen messages.
    tick ($state | update fsm_state "harvesting") $spool $root ($remaining - 1)
}

# harvesting: process each unseen message; update seen_ids.
# If an unmatched outbound request is found, set pending fields and transition to dispatching.
def state-harvesting [state: record, spool: string, root: string, remaining: int] {
    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut new_seen       = $state.seen_ids
    mut dispatch_state = null   # set when we find a request to dispatch

    for msg in $messages {
        # Stop processing once we've identified a dispatch target.
        if $dispatch_state != null { break }

        let id = msg-id $msg
        if $id == "" or ($id in $new_seen) { continue }

        let payload = extract-toml $msg

        if "_parse_error" in $payload {
            log-event "harvest_malformed" {
                message_id:  $id
                from_line:   $msg.from_line
                parse_error: ($payload._parse_error)
            }
        } else {
            let to_addr   = $msg.headers | get "To"? | default "unknown"
            let from_addr = $msg.headers | get "From"? | default "unknown"
            let subject   = $msg.headers | get "Subject"? | default ""
            let verdict   = $payload | get "verdict"? | default "none"
            let task_id   = $payload | get "task_id"? | default "unknown"

            # Determine whether this is a coord→agent request or agent→coord reply.
            let direction = if ($to_addr | str contains "coordinator@") { "reply" } else { "request" }

            log-event "harvest_message" {
                message_id: $id
                direction:  $direction
                task_id:    $task_id
                from:       $from_addr
                to:         $to_addr
                subject:    $subject
                verdict:    $verdict
            }

            if $direction == "reply" {
                if $verdict == "fail" or $verdict == "blocked" {
                    let halt_path = [$root, "var", "mail", "HALT"] | path join
                    let halt_dir  = $halt_path | path dirname
                    if not ($halt_dir | path exists) { mkdir $halt_dir }
                    {
                        task_id:    $task_id
                        verdict:    $verdict
                        message_id: $id
                        halted_at:  (date now | format date "%Y-%m-%dT%H:%M:%SZ")
                    } | to toml | save --force $halt_path
                    log-event "harvest_reply_halt" {
                        message_id: $id
                        task_id:    $task_id
                        verdict:    $verdict
                    }
                    $new_seen = $new_seen | append $id
                    # Return early — halt on the next tick's HALT check
                    return ($state | update seen_ids $new_seen | update fsm_state "idle")
                }
            }

            # If this is an unmatched outbound request, dispatch it (first one wins).
            if $direction == "request" {
                let in_reply_to = $msg.headers | get "In-Reply-To"? | default ""
                if $in_reply_to == "" {
                    log-event "would_dispatch" {
                        task_id:    $task_id
                        to_role:    $to_addr
                        message_id: $id
                    }
                    $new_seen = $new_seen | append $id
                    $dispatch_state = ($state
                        | update seen_ids           $new_seen
                        | update pending_request_id $id
                        | update pending_task_id    $task_id
                        | update pending_to_addr    $to_addr
                        | update fsm_state          "dispatching")
                    # break is implicit: dispatch_state != null will stop outer loop
                }
            }
        }

        if $dispatch_state == null {
            $new_seen = $new_seen | append $id
        }
    }

    if $dispatch_state != null {
        tick $dispatch_state $spool $root ($remaining - 1)
    } else {
        $state
        | update seen_ids $new_seen
        | update fsm_state "idle"
    }
}

# waiting: a request has been dispatched; poll the spool for a matching reply.
# Transitions to harvesting if a reply is found; stays in waiting otherwise.
def state-waiting [state: record, spool: string, root: string, remaining: int] {
    if not ($spool | path exists) {
        log-event "waiting_no_reply" {pending_request_id: $state.pending_request_id, reason: "spool absent"}
        return $state
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    let reply = (
        $messages
        | where {|m|
            let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
            $in_reply_to == $state.pending_request_id
        }
        | first 1
    )

    if ($reply | length) > 0 {
        log-event "waiting_reply_received" {
            pending_request_id: $state.pending_request_id
            pending_task_id:    $state.pending_task_id
        }
        let next_state = $state
            | update pending_request_id ""
            | update pending_task_id    ""
            | update pending_to_addr    ""
            | update fsm_state          "harvesting"
        tick $next_state $spool $root ($remaining - 1)
    } else {
        log-event "waiting_no_reply" {pending_request_id: $state.pending_request_id}
        $state
    }
}

# dispatching: compose and append an outbound mbox message to the spool,
# then transition to waiting.
def state-dispatching [state: record, spool: string, root: string, remaining: int] {
    let ts        = date now | format date "%Y%m%d%H%M%S"
    let msg_id    = $"<coord.($state.tick_count).($ts)@smolbsd.local>"
    let to_addr   = if $state.pending_to_addr != "" { $state.pending_to_addr } else { $"($state.pending_task_id)@smolbsd.local" }
    let from_addr = "coordinator@smolbsd.local"

    let mbox_msg = $"From ($from_addr) ($ts)
From: ($from_addr)
To: ($to_addr)
Message-ID: ($msg_id)
Content-Type: text/toml; charset=utf-8
In-Reply-To: ($state.pending_request_id)

task_id = \"($state.pending_task_id)\"
action = \"dispatch\"
"

    # Append the message to the spool file.
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    $"($existing)($mbox_msg)" | save --force $spool

    log-event "dispatch_sent" {
        message_id: $msg_id
        task_id:    $state.pending_task_id
        to:         $to_addr
    }

    tick ($state | update fsm_state "waiting") $spool $root ($remaining - 1)
}

# halted: HALT marker is present.  Log and stop — do not recurse further.
# Per spec §13: wait for user to rm var/mail/HALT and post a resume message.
# We return here; the next cron/manual invocation will re-check.
def state-halted [state: record, root: string] {
    let halt_path = [$root, "var", "mail", "HALT"] | path join
    let halt_info = try { open --raw $halt_path | from toml } catch { {} }
    log-event "halted" {
        halt_file: $halt_path
        info:      ($halt_info | to nuon)
        note:      "coordinator paused; rm var/mail/HALT + append resume message to unblock"
    }
    $state | update fsm_state "halted"
}

# ── Tail-recursive dispatch core ──────────────────────────────────────────────

# The coordinator FSM.  Each call is one state transition.
# Recursion terminates when:
#   - remaining hits 0  (tick budget exhausted)
#   - the idle state finds no new work  (natural quiescence)
#   - halted state is entered  (HALT marker present)
def tick [state: record, spool: string, root: string, remaining: int] {
    if $remaining <= 0 {
        log-event "tick_budget_exhausted" {tick_count: $state.tick_count}
        return $state
    }

    # O(1) HALT check before every state dispatch — spec §13.
    if (halt-present $root) {
        return (state-halted $state $root)
    }

    let next_count = $state.tick_count + 1
    let stamped = $state
        | update tick_count $next_count
        | update last_tick_at (date now | format date "%Y-%m-%dT%H:%M:%SZ")

    log-event "tick_enter" {tick: $next_count, fsm_state: $stamped.fsm_state, remaining: $remaining}

    match $stamped.fsm_state {
        "idle"        => { state-idle        $stamped $spool $root $remaining }
        "dispatching" => { state-dispatching $stamped $spool $root $remaining }
        "waiting"     => { state-waiting     $stamped $spool $root $remaining }
        "harvesting"  => { state-harvesting  $stamped $spool $root $remaining }
        "halted"      => { state-halted      $stamped $root }
        _             => {
            log-event "unknown_state" {fsm_state: $stamped.fsm_state}
            $stamped | update fsm_state "idle"
        }
    }
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Run one coordinator tick.
#
# --state-file  path to the persistent TOML state file (created if absent)
# --spool       path to the mbox spool file
# --max-ticks   maximum FSM transitions in this invocation (budget guard)
# --root        project root directory (default: current working directory)
export def main [
    --state-file: string = "var/run/coord-state.toml"
    --spool:      string = "var/mail/spool"
    --max-ticks:  int    = 100
    --root:       string = "."
] {
    # Resolve all paths relative to --root so the binary works from any cwd.
    let abs_root       = $root | path expand
    let abs_state_file = [$abs_root, $state_file] | path join
    let abs_spool      = [$abs_root, $spool]      | path join

    log-event "coord_tick_start" {
        state_file: $abs_state_file
        spool:      $abs_spool
        max_ticks:  $max_ticks
        root:       $abs_root
    }

    let initial_state = load-state $abs_state_file
    let final_state   = tick $initial_state $abs_spool $abs_root $max_ticks

    save-state $final_state $abs_state_file

    log-event "coord_tick_done" {
        tick_count: $final_state.tick_count
        fsm_state:  $final_state.fsm_state
        seen_ids:   ($final_state.seen_ids | length)
    }
}
