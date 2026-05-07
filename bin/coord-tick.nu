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
#   waiting      — request dispatched, polling spool for matching reply
#   harvesting   — new replies present; cross-check claims
#   halted       — global var/mail/HALT present OR all tasks failed; clears per-task on resume
#
# HALT check: one `stat var/mail/HALT` per tick entry — O(1) per spec §13.

use mbox-parse.nu [parse-mbox, extract-toml, msg-id]

const AGENT_CAPABILITIES = {
    "general-purpose":          ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch"]
    "feature-dev:code-architect": ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"]
    "architect":                ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"]
    "researcher":               ["Read", "Glob", "Grep", "WebFetch", "WebSearch"]
    "security":                 ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    "ops":                      ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    "builder":                  ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    "reviewer":                 ["Read", "Glob", "Grep", "WebFetch"]
}

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
        dispatched_at:      ""
        attempt_counts:     {}   # record keyed by task_id → int attempt count
        halted_tasks:       []
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

# Write a per-task HALT marker. Returns the path written.
def write-halt-marker [root: string, task_id: string, reason: string, verdict: string, message_id: string, attempts: int] {
    let halt_path = [$root, "var", "mail", $"HALT.($task_id)"] | path join
    let halt_dir  = $halt_path | path dirname
    if not ($halt_dir | path exists) { mkdir $halt_dir }
    {
        task_id:    $task_id
        verdict:    $verdict
        message_id: $message_id
        halted_at:  (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        reason:     $reason
        attempts:   $attempts
        halt_msgid: $"<halt-($task_id).coord@smolbsd.local>"
        resume_tag: $"resume-($task_id)"
    } | to toml | save --force $halt_path
    $halt_path
}

# Append a spec-compliant HALT mbox message to the spool.
def append-halt-message [spool: string, task_id: string, reason: string, verdict: string, attempts: int, proposed_actions: list<string>] {
    let ts        = date now | format date "%Y%m%d%H%M%S"
    let halt_msgid = $"<halt-($task_id).coord@smolbsd.local>"
    let resume_tag = $"resume-($task_id)"
    let x_halt_reason = match $reason {
        "retry-exhausted"  => "retry-exhausted"
        "no-unblocker"     => "claim-verification-failed"
        _                  => $reason
    }
    let mbox_msg = $"From coordinator@smolbsd.local ($ts)
From: coordinator@smolbsd.local
To: user@smolbsd.local
Subject: [HALT] ($task_id) — ($reason)
Message-ID: ($halt_msgid)
X-Halt-Reason: ($x_halt_reason)
X-Resume-Tag: ($resume_tag)
Content-Type: text/toml; charset=utf-8

task_id           = \"($task_id)\"
halt_msgid        = \"($halt_msgid)\"
resume_tag        = \"($resume_tag)\"
reason            = \"($reason)\"
last_verdict      = \"($verdict)\"
attempts          = ($attempts)
proposed_actions  = [($proposed_actions | each {|a| $"\"($a)\""} | str join ', ')]
"
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    $"($existing)($mbox_msg)" | save --force $spool
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
# Implements D2 retry table: fail/blocked retries up to 3 attempts, then HALT.
def state-harvesting [state: record, spool: string, root: string, remaining: int] {
    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut new_seen       = $state.seen_ids
    mut dispatch_state = null   # set when we find a request to dispatch
    mut current_state  = $state

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
            let direction = if $to_addr == "coordinator@smolbsd.local" { "reply" } else { "request" }

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
                # Get current attempt count for this task
                let attempt_n = $current_state.attempt_counts | get $task_id? | default 0

                if $verdict == "pass" {
                    # Check attestation requirement
                    let attestation_required = $payload | get "attestation_required"? | default false
                    let claims = $payload | get "claims"? | default []

                    if $attestation_required and (($claims | length) == 0) {
                        # Treat as MALFORMED (treat as fail for retry purposes)
                        log-event "harvest_malformed" {
                            message_id:  $id
                            task_id:     $task_id
                            reason:      "attestation_required=true but no [[claims]] block present"
                        }
                        if $attempt_n < 3 {
                            $new_seen = $new_seen | append $id
                            $dispatch_state = ($current_state
                                | update seen_ids           $new_seen
                                | update pending_request_id $id
                                | update pending_task_id    $task_id
                                | update pending_to_addr    $from_addr
                                | update fsm_state          "dispatching")
                            log-event "harvest_reply_retry" {message_id: $id, task_id: $task_id, verdict: "fail", attempt: $attempt_n}
                        } else {
                            let _ = write-halt-marker $root $task_id "retry-exhausted" $verdict $id $attempt_n
                            append-halt-message $spool $task_id "retry-exhausted" $verdict $attempt_n ["retry", "abort"]
                            $current_state = ($current_state | update halted_tasks ($current_state.halted_tasks | append $task_id))
                            log-event "harvest_reply_halt" {message_id: $id, task_id: $task_id, verdict: $verdict, reason: "retry-exhausted"}
                            $new_seen = $new_seen | append $id
                            return ($current_state | update seen_ids $new_seen | update fsm_state "idle")
                        }
                    } else {
                        # pass + verified
                        log-event "harvest_reply_pass" {message_id: $id, task_id: $task_id}
                        let cleared_counts = $current_state.attempt_counts | reject $task_id?
                        $new_seen = $new_seen | append $id
                        $current_state = ($current_state | update seen_ids $new_seen | update attempt_counts $cleared_counts)
                        continue
                    }
                } else if $verdict == "fail" {
                    # D2 retry table: retry if attempts < 3, else HALT
                    if $attempt_n < 3 {
                        $new_seen = $new_seen | append $id
                        $dispatch_state = ($current_state
                            | update seen_ids           $new_seen
                            | update pending_request_id $id
                            | update pending_task_id    $task_id
                            | update pending_to_addr    $from_addr
                            | update fsm_state          "dispatching")
                        log-event "harvest_reply_retry" {message_id: $id, task_id: $task_id, verdict: $verdict, attempt: $attempt_n}
                    } else {
                        let _ = write-halt-marker $root $task_id "retry-exhausted" $verdict $id $attempt_n
                        append-halt-message $spool $task_id "retry-exhausted" $verdict $attempt_n ["retry", "abort"]
                        $current_state = ($current_state | update halted_tasks ($current_state.halted_tasks | append $task_id))
                        log-event "harvest_reply_halt" {message_id: $id, task_id: $task_id, verdict: $verdict, reason: "retry-exhausted"}
                        $new_seen = $new_seen | append $id
                        return ($current_state | update seen_ids $new_seen | update fsm_state "idle")
                    }
                } else if $verdict == "blocked" {
                    # D2 retry table: blocked_by present → retry up to 3; no blocked_by → immediate HALT
                    let blocked_by = $payload | get "blocked_by"? | default ""
                    if ($blocked_by | str length) > 0 {
                        # unblocker named — retry if attempts < 3
                        if $attempt_n < 3 {
                            $new_seen = $new_seen | append $id
                            $dispatch_state = ($current_state
                                | update seen_ids           $new_seen
                                | update pending_request_id $id
                                | update pending_task_id    $task_id
                                | update pending_to_addr    $from_addr
                                | update fsm_state          "dispatching")
                            log-event "harvest_reply_retry" {message_id: $id, task_id: $task_id, verdict: $verdict, attempt: $attempt_n}
                        } else {
                            let _ = write-halt-marker $root $task_id "retry-exhausted" $verdict $id $attempt_n
                            append-halt-message $spool $task_id "retry-exhausted" $verdict $attempt_n ["retry", "abort"]
                            $current_state = ($current_state | update halted_tasks ($current_state.halted_tasks | append $task_id))
                            log-event "harvest_reply_halt" {message_id: $id, task_id: $task_id, verdict: $verdict, reason: "retry-exhausted"}
                            $new_seen = $new_seen | append $id
                            return ($current_state | update seen_ids $new_seen | update fsm_state "idle")
                        }
                    } else {
                        # no blocked_by — immediate HALT, no retry
                        let _ = write-halt-marker $root $task_id "no-unblocker" $verdict $id $attempt_n
                        append-halt-message $spool $task_id "no-unblocker" $verdict $attempt_n ["abort", "edit"]
                        $current_state = ($current_state | update halted_tasks ($current_state.halted_tasks | append $task_id))
                        log-event "harvest_reply_halt" {message_id: $id, task_id: $task_id, verdict: $verdict, reason: "no-unblocker"}
                        $new_seen = $new_seen | append $id
                        return ($current_state | update seen_ids $new_seen | update fsm_state "idle")
                    }
                }
            }

            # If this is an unmatched outbound request, dispatch it (first one wins).
            if $direction == "request" {
                # Skip tasks that are already halted.
                if $task_id in $current_state.halted_tasks {
                    log-event "dispatch_skipped_halted" {task_id: $task_id, message_id: $id}
                    $new_seen = $new_seen | append $id
                    continue
                }

                # §17: check tools_required against known agent capabilities
                let tools_required = $payload | get "tools_required"? | default []
                let agent_type     = $payload | get "agent_type"?     | default "general-purpose"
                let capabilities   = $AGENT_CAPABILITIES | get $agent_type? | default ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
                let missing_tools  = $tools_required | where {|t| not ($t in $capabilities)}

                if ($missing_tools | length) > 0 {
                    log-event "dispatch_capability_mismatch" {
                        task_id:       $task_id
                        agent_type:    $agent_type
                        tools_required: ($tools_required | str join ", ")
                        missing_tools:  ($missing_tools | str join ", ")
                        message_id:    $id
                    }
                    $new_seen = $new_seen | append $id
                    # Skip dispatch — mark seen so we don't retry this message
                    continue
                }

                let in_reply_to = $msg.headers | get "In-Reply-To"? | default ""
                if $in_reply_to == "" {
                    log-event "would_dispatch" {
                        task_id:    $task_id
                        to_role:    $to_addr
                        message_id: $id
                    }
                    $new_seen = $new_seen | append $id
                    $dispatch_state = ($current_state
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
        $current_state
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
            | update dispatched_at      ""
            | update fsm_state          "harvesting"
        tick $next_state $spool $root ($remaining - 1)
    } else {
        log-event "waiting_no_reply" {pending_request_id: $state.pending_request_id}

        # Timeout: treat no-reply > 300s as a fail (triggers D2 retry table on next harvest)
        if $state.dispatched_at != "" {
            let elapsed = (date now) - ($state.dispatched_at | into datetime)
            if ($elapsed | into int) > 300_000_000_000 {   # 300s in nanoseconds
                log-event "waiting_timeout" {
                    pending_request_id: $state.pending_request_id
                    pending_task_id:    $state.pending_task_id
                    dispatched_at:      $state.dispatched_at
                }
                # Inject a synthetic fail reply into the spool so the next harvest triggers retry
                let ts = date now | format date "%Y%m%d%H%M%S"
                let synth_id = $"<timeout.($state.pending_task_id).($ts)@smolbsd.local>"
                let synth_msg = $"From coordinator@smolbsd.local ($ts)
From: coordinator@smolbsd.local
To: coordinator@smolbsd.local
Message-ID: ($synth_id)
In-Reply-To: ($state.pending_request_id)
Content-Type: text/toml; charset=utf-8

task_id = \"($state.pending_task_id)\"
verdict = \"fail\"
failure_reason = \"timeout: no reply within 300s\"
"
                let existing = if ($spool | path exists) { open --raw $spool } else { "" }
                $"($existing)($synth_msg)" | save --force $spool
                return ($state | update fsm_state "idle" | update dispatched_at "")
            }
        }

        $state
    }
}

# dispatching: compose and append an outbound mbox message to the spool,
# then transition to waiting. Tracks attempt counts with retry-aware headers.
def state-dispatching [state: record, spool: string, root: string, remaining: int] {
    let task_id      = $state | get pending_task_id? | default "unknown"
    let attempt_n    = $state.attempt_counts | get $task_id? | default 0
    let next_attempt = $attempt_n + 1
    let ts           = date now | format date "%Y%m%d%H%M%S"
    let msg_id       = $"<coord.($state.tick_count).r($next_attempt).($ts)@smolbsd.local>"
    let to_addr      = if $state.pending_to_addr != "" { $state.pending_to_addr } else { $"($task_id)@smolbsd.local" }
    let from_addr    = "coordinator@smolbsd.local"

    let mbox_msg = $"From ($from_addr) ($ts)
From: ($from_addr)
To: ($to_addr)
Message-ID: ($msg_id)
X-Attempt: ($next_attempt)
Content-Type: text/toml; charset=utf-8
In-Reply-To: ($state.pending_request_id)

task_id = \"($task_id)\"
action = \"dispatch\"
"

    # Append the message to the spool file.
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    $"($existing)($mbox_msg)" | save --force $spool

    log-event "dispatch_sent" {
        message_id: $msg_id
        task_id:    $task_id
        to:         $to_addr
        attempt:    $next_attempt
    }

    let updated_counts = $state.attempt_counts | insert $task_id $next_attempt
    tick ($state
        | update fsm_state          "waiting"
        | update attempt_counts     $updated_counts
        | update pending_request_id $msg_id
        | update dispatched_at      (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    ) $spool $root ($remaining - 1)
}

# halted: global HALT marker is present or all tasks failed.
# Per spec §13: wait for user to rm var/mail/HALT and post a resume message.
# We return here; the next cron/manual invocation will re-check.
def state-halted [state: record, root: string, spool: string] {
    let halt_path = [$root, "var", "mail", "HALT"] | path join
    let halt_info = try { open --raw $halt_path | from toml } catch { {} }
    log-event "halted" {
        halt_file:    $halt_path
        info:         ($halt_info | to nuon)
        halted_tasks: ($state.halted_tasks | str join ", ")
        note:         "coordinator paused; rm var/mail/HALT + append resume message to unblock"
    }

    # Scan spool for resume messages matching tasks in halted_tasks.
    if ($spool | path exists) {
        let content  = open --raw $spool
        let messages = parse-mbox $content
        for msg in $messages {
            let resume_tag = $msg.headers | get "X-Resume-Tag"? | default ""
            if $resume_tag != "" {
                let matched = $state.halted_tasks | where {|t| $"resume-($t)" == $resume_tag }
                if ($matched | length) > 0 {
                    let task = $matched | first
                    let action_hdr = $msg.headers | get "X-Resume-Action"? | default "retry"
                    log-event "halted_resume_action" {
                        task_id:    $task
                        resume_tag: $resume_tag
                        action:     $action_hdr
                    }
                    if $action_hdr == "retry" or $action_hdr == "edit" {
                        # Remove from halted_tasks; delete per-task HALT marker
                        let per_halt = [$root, "var", "mail", $"HALT.($task)"] | path join
                        if ($per_halt | path exists) { rm $per_halt }
                        # Return state with task removed from halted_tasks, back to idle for re-dispatch
                        return ($state
                            | update halted_tasks ($state.halted_tasks | where {|t| $t != $task})
                            | update fsm_state "idle")
                    } else {
                        # abort — keep halted, do nothing
                        log-event "halted_abort" {task_id: $task}
                    }
                }
            }
        }
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
        return (state-halted $state $root $spool)
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
        "halted"      => { state-halted      $stamped $root $spool }
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
