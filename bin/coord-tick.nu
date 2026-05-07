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
        version:          $STATE_VERSION
        tick_count:       0
        fsm_state:        "idle"
        seen_ids:         []
        last_tick_at:     (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        pending_dispatch: null
        waiting_for_id:   ""
    }
}

# Load state from TOML file, or return the default if file absent / parse fails.
def load-state [path: string] {
    if not ($path | path exists) {
        log-event "state_init" {path: $path, reason: "file absent"}
        return (default-state)
    }
    try {
        open --raw $path | from toml
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
# Queues the first unmatched REQUEST found for dispatch (transitions to dispatching).
def state-harvesting [state: record, spool: string, root: string, remaining: int] {
    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut new_seen = $state.seen_ids

    for msg in $messages {
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

            # If this looks like an unmatched request (no In-Reply-To, not yet seen),
            # queue it for dispatch by transitioning to dispatching.
            if $direction == "request" {
                let in_reply_to = $msg.headers | get "In-Reply-To"? | default ""
                if $in_reply_to == "" {
                    log-event "queue_dispatch" {
                        task_id:    $task_id
                        to_role:    $to_addr
                        message_id: $id
                    }
                    # Record this id as seen before we break out, so it is not
                    # re-queued on the next tick while we are still in dispatching.
                    $new_seen = $new_seen | append $id
                    # Persist seen_ids and queue the pending_dispatch, then hand off.
                    let dispatch_state = $state
                        | update seen_ids $new_seen
                        | update fsm_state "dispatching"
                        | update pending_dispatch {
                            task_id:    $task_id
                            to_addr:    $to_addr
                            message_id: $id
                            body:       $msg.body
                        }
                    return (tick $dispatch_state $spool $root ($remaining - 1))
                }
            }
        }

        $new_seen = $new_seen | append $id
    }

    $state
    | update seen_ids $new_seen
    | update fsm_state "idle"
}

# waiting: a request has been dispatched; poll the spool for a reply.
# Checks state.pending for a msg_id to wait on.
# If a reply is found, logs reply_received, clears pending, and transitions to harvesting.
# If no reply yet, logs waiting_no_reply with elapsed time and stays in waiting.
# If state.pending is absent/empty, logs waiting_no_pending and returns to idle.
def state-waiting [state: record, spool: string, root: string, remaining: int] {
    # Read the pending field safely — may be absent in older state files.
    let pending = $state | get pending? | default {}

    let pending_msg_id = $pending | get msg_id? | default ""

    if $pending_msg_id == "" {
        log-event "waiting_no_pending" {note: "state.pending missing or has no msg_id; returning to idle"}
        return ($state | update fsm_state "idle")
    }

    if not ($spool | path exists) {
        log-event "waiting_no_reply" {
            pending_msg_id: $pending_msg_id
            reason:         "spool absent"
        }
        return $state
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    # Look for a message whose In-Reply-To matches our dispatched msg_id
    # and whose own Message-ID has not yet been seen.
    let replies = (
        $messages
        | where {|m|
            let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
            let id          = msg-id $m
            $in_reply_to == $pending_msg_id and $id != "" and not ($id in $state.seen_ids)
        }
        | first 1
    )

    if ($replies | length) == 0 {
        # No reply yet — compute elapsed time and stay in waiting.
        let dispatched_at = $pending | get dispatched_at? | default ""
        let elapsed_note = if $dispatched_at != "" {
            try {
                let dispatched_dt = $dispatched_at | into datetime
                let now_dt        = date now
                let elapsed_secs  = ($now_dt - $dispatched_dt) / 1sec
                $"($elapsed_secs | into int)s"
            } catch {
                "unknown"
            }
        } else {
            "unknown"
        }

        log-event "waiting_no_reply" {
            pending_msg_id: $pending_msg_id
            elapsed:        $elapsed_note
        }
        return $state
    }

    # Reply found — extract details and transition to harvesting.
    let reply_msg = $replies | first
    let reply_id  = msg-id $reply_msg
    let payload   = extract-toml $reply_msg
    let verdict   = $payload | get "verdict"? | default "none"
    let task_id   = $pending | get task_id? | default "unknown"

    log-event "reply_received" {
        task_id:        $task_id
        pending_msg_id: $pending_msg_id
        reply_id:       $reply_id
        verdict:        $verdict
    }

    # Clear pending and mark the reply as seen; hand off to harvesting.
    $state
    | update seen_ids ($state.seen_ids | append $reply_id)
    | update pending  {}
    | update fsm_state "harvesting"
}

# dispatching: detect the most recent coordinator dispatch with no matching reply,
# record it in state.pending, and transition to waiting.
# For now (no real subagent launch infrastructure) this means: scan the spool,
# find the first coordinator→agent message that has no In-Reply-To pointing at it,
# and write that as a pending record in state.
def state-dispatching [state: record, spool: string, root: string, remaining: int] {
    let pd = $state | get pending_dispatch? | default null

    if $pd == null {
        log-event "dispatching_no_pending" {note: "pending_dispatch absent; returning to idle"}
        return ($state | update fsm_state "idle")
    }

    if not ($spool | path exists) {
        log-event "dispatching_spool_absent" {note: "spool absent; cannot scan for unmatched dispatch"}
        return ($state | update fsm_state "idle")
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    # Build a set of all In-Reply-To values across the entire spool,
    # so we can check which coordinator messages have no reply yet.
    let all_in_reply_to = (
        $messages
        | each {|m| $m.headers | get "In-Reply-To"? | default ""}
        | where {|s| $s != ""}
    )

    # Find the first coordinator message (From: coordinator@) that has no
    # matching reply (no other message has In-Reply-To == its Message-ID).
    let unmatched = (
        $messages
        | where {|m|
            let from_addr = $m.headers | get "From"? | default ""
            let id        = msg-id $m
            ($from_addr | str contains "coordinator@") and $id != "" and not ($id in $all_in_reply_to)
        }
        | first 1
    )

    # Use the pending_dispatch queued by harvesting, or the first unmatched spool message.
    let task_id    = $pd.task_id
    let message_id = $pd.message_id

    let now_ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"

    let pending_record = {
        task_id:       $task_id
        msg_id:        $message_id
        dispatched_at: $now_ts
    }

    log-event "dispatch_registered" {
        task_id:    $task_id
        msg_id:     $message_id
        dispatched_at: $now_ts
    }

    # Also log whether we found an unmatched spool entry (informational).
    if ($unmatched | length) > 0 {
        let u = $unmatched | first
        let u_id = msg-id $u
        if $u_id != $message_id {
            log-event "dispatching_unmatched_found" {
                unmatched_msg_id: $u_id
                note: "spool has additional unmatched coordinator dispatch"
            }
        }
    }

    let next_state = $state
        | update pending_dispatch null
        | update pending          $pending_record
        | update fsm_state        "waiting"

    tick $next_state $spool $root ($remaining - 1)
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

# ── Phase-II batch dispatch ───────────────────────────────────────────────────

# Parse the §8 files-to-create markdown table from PHASE-2-PHYSICAL-BOOT.md.
# Returns a list of records: {path: string, purpose: string, status: string}.
# Rows with a backtick-quoted path cell are handled; leading/trailing spaces trimmed.
def parse-phase-ii-table [doc_path: string] {
    if not ($doc_path | path exists) {
        error make {msg: $"Phase-II plan not found: ($doc_path)"}
    }

    let raw = open --raw $doc_path

    # Isolate the §8 block: everything from "## 8." up to the next "---" separator.
    let after_s8 = $raw | split row "## 8." | last
    let section  = $after_s8 | split row "\n---" | first

    # Extract pipe-delimited data rows (skip the header and separator rows).
    # A data row: starts with '|', has at least 3 cells, does NOT consist solely
    # of pipes and dashes (separator row).
    let rows = (
        $section
        | lines
        | where {|ln|
            let t        = $ln | str trim
            # Keep rows that start with "|" and are not pure separator lines
            # (separator rows contain only |, -, and spaces after stripping).
            let stripped = $t | str replace --all "|" "" | str replace --all "-" "" | str replace --all " " ""
            ($t | str starts-with "|") and (not ($stripped | is-empty))
        }
        | skip 1   # skip the header row (| Path | Purpose | Status |)
        | each {|ln|
            # Split on "|", drop first and last empty segments from leading/trailing "|".
            let cells = $ln | split row "|" | skip 1 | drop 1 | each {|c| $c | str trim}
            if ($cells | length) < 3 {
                null
            } else {
                # Strip surrounding backticks from path cell.
                let raw_path = $cells | get 0
                let path     = $raw_path | str replace --all "`" ""
                let purpose  = $cells | get 1
                let status   = $cells | get 2 | str downcase | str trim
                {path: $path, purpose: $purpose, status: $status}
            }
        }
        | where {|r| $r != null}
    )

    $rows
}

# Build a slug suitable for use in a Message-ID / task_id from a file path.
# e.g. "release/tools/smolbsd-pi5.conf" -> "release-tools-smolbsd-pi5-conf"
def path-to-slug [p: string] {
    $p
    | str replace --all "/" "-"
    | str replace --all "." "-"
    | str replace --all "_" "-"
}

# Emit one coordinator dispatch mbox message to the spool for a Phase-II file task.
# Returns the Message-ID string emitted.
def emit-dispatch [spool: string, task_id: string, path: string, purpose: string] {
    let env_ts  = date now | format date "%a %b %d %H:%M:%S %Y"
    let hdr_ts  = date now | format date "%a, %d %b %Y %H:%M:%S -0000"
    let msg_id  = $"<($task_id).coord@smolbsd.local>"
    let to_addr = "builder@smolbsd.local"
    let from_addr = "coordinator@smolbsd.local"
    let subject = $"[($task_id)] Phase-II create ($path)"

    # Build TOML body line-by-line to avoid Nushell string-interpolation
    # conflicts with bracket characters and filenames containing dots.
    let lines = [
        $"task_id   = \"($task_id)\""
        $"title     = \"Create ($path)\""
        "phase     = \"tinyos/physical-boot\""
        "deadline  = \"2026-05-31\""
        ""
        "[brief]"
        "summary = \"\"\""
        "Phase-II file creation task (see PHASE-2-PHYSICAL-BOOT plan, section 8)."
        $"Purpose: ($purpose)"
        $"Path: ($path)"
        "\"\"\""
        ""
        "[context_pointers]"
        "read = ["
        "  \"plans/tinyos/PHASE-2-PHYSICAL-BOOT.md\","
        "]"
        ""
        "[acceptance]"
        "must_pass = ["
        $"  \"File ($path) exists and is non-empty\","
        $"  \"Content matches purpose: ($purpose)\","
        "]"
        ""
        "[reply_contract]"
        "output_to            = \"coordinator@smolbsd.local\""
        "output_format        = \"mbox+toml-v1\""
        "attestation_required = true"
        "tools_required       = [\"Read\", \"Write\"]"
        "tools_allowed        = [\"Read\", \"Write\", \"Edit\", \"Bash\", \"Grep\", \"Glob\"]"
        "budget_tokens        = 40000"
    ]
    let body = $lines | str join "\n"

    let envelope = $"From smolbsd-coord ($env_ts)
From: ($from_addr)
To: ($to_addr)
Subject: ($subject)
Date: ($hdr_ts)
Message-ID: ($msg_id)
X-Project: smolbsd
X-Phase: tinyos/physical-boot
Content-Type: text/toml; charset=utf-8

($body)
"
    # Ensure spool directory exists.
    let spool_dir = $spool | path dirname
    if not ($spool_dir | path exists) {
        mkdir $spool_dir
    }

    $envelope | save --append $spool

    $msg_id
}

# Read PHASE-2-PHYSICAL-BOOT.md §8, emit a coordinator dispatch mbox message
# to the spool for each row whose status is "pending".
# Returns {dispatched: int, skipped: int}.
export def dispatch-phase-ii [
    --spool: string = "var/mail/spool"   # path to mbox spool
    --root:  string = "."                # project root
] {
    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join
    let doc_path  = [$abs_root, "plans", "tinyos", "PHASE-2-PHYSICAL-BOOT.md"] | path join

    log-event "phase_ii_dispatch_start" {doc: $doc_path, spool: $abs_spool}

    let rows = parse-phase-ii-table $doc_path

    mut dispatched = 0
    mut skipped    = 0

    for row in $rows {
        if ($row.status != "pending") {
            log-event "phase_ii_dispatch" {
                action:  "skipped"
                path:    $row.path
                status:  $row.status
                reason:  "not pending"
            }
            $skipped = $skipped + 1
            continue
        }

        let slug    = path-to-slug $row.path
        let task_id = $"phase-ii-($slug)"
        let msg_id  = emit-dispatch $abs_spool $task_id $row.path $row.purpose

        log-event "phase_ii_dispatch" {
            action:    "dispatched"
            task_id:   $task_id
            path:      $row.path
            purpose:   $row.purpose
            message_id: $msg_id
            spool:     $abs_spool
        }

        $dispatched = $dispatched + 1
    }

    let summary = {dispatched: $dispatched, skipped: $skipped}

    log-event "phase_ii_dispatch_done" $summary

    $summary
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
# --state-file       path to the persistent TOML state file (created if absent)
# --spool            path to the mbox spool file
# --max-ticks        maximum FSM transitions in this invocation (budget guard)
# --root             project root directory (default: current working directory)
# --dispatch-phase-ii  emit Phase-II §8 pending tasks to spool then exit (no FSM tick)
export def main [
    --state-file:       string = "var/run/coord-state.toml"
    --spool:            string = "var/mail/spool"
    --max-ticks:        int    = 100
    --root:             string = "."
    --dispatch-phase-ii              # emit Phase-II §8 pending-file tasks to spool
] {
    # Resolve all paths relative to --root so the binary works from any cwd.
    let abs_root       = $root | path expand
    let abs_state_file = [$abs_root, $state_file] | path join
    let abs_spool      = [$abs_root, $spool]      | path join

    # --dispatch-phase-ii: batch-emit Phase-II tasks then return; skip FSM tick.
    if $dispatch_phase_ii {
        let summary = dispatch-phase-ii --spool $spool --root $root
        print ($summary | to toml)
        return
    }

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
