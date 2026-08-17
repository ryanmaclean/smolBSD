#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# coord-escalate.nu — D3 escalation entry point for the smolfire coordinator
#
# Appends a structured ESCALATE message to the spool and writes a per-task
# HALT marker.  Called by coord-tick when the D2 retry table is exhausted or
# a credential-fingerprint mismatch forces an immediate escalation.
#
# Usage:
#   nu bin/coord-escalate.nu --task-id t42 --reason retry-exhausted --attempts 3
#   nu bin/coord-escalate.nu --task-id t7  --reason credential-fingerprint-mismatch --verdict fail

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def main [
    --task-id:  string              # task being escalated (required)
    --reason:   string              # e.g. retry-exhausted, credential-fingerprint-mismatch, probe-disagreement
    --verdict:  string = ""         # last verdict ("fail", "blocked", etc.)
    --attempts: int    = 0          # number of attempts made
    --spool:    string = "var/mail/spool"
    --root:     string = "."
] {
    if $task_id == null or $task_id == "" {
        error make {msg: "--task-id is required"}
    }
    if $reason == null or $reason == "" {
        error make {msg: "--reason is required"}
    }

    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join
    let mail_dir  = $abs_spool | path dirname

    if not ($mail_dir | path exists) { mkdir $mail_dir }

    let ts      = date now | date to-timezone utc | format date "%Y%m%d%H%M%S"
    let ts_iso  = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let msg_id  = $"<escalate.($task_id).($ts)@smolfire.local>"
    let subject = $"[ESCALATE] ($task_id): ($reason)"
    let ask     = $"Human review required: ($reason) after ($attempts) attempts. Check var/mail/HALT.($task_id) for details."

    let body = [
        $"task_id  = \"($task_id)\""
        $"category = \"escalation\""
        $"reason   = \"($reason)\""
        $"verdict  = \"($verdict)\""
        $"attempts = ($attempts)"
        "proposed_actions = [\"retry\", \"abort\", \"edit\"]"
        $"ask      = \"($ask)\""
    ] | str join "\n"

    let mbox_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: operator@smolfire.local
Subject: ($subject)
Message-ID: ($msg_id)
X-Halt-Reason: ($reason)
Content-Type: text/toml; charset=utf-8

($body)
"

    $mbox_msg | save --append $abs_spool
    log-step "escalate-spool" "escalation message appended to spool" {
        task_id:    $task_id
        reason:     $reason
        message_id: $msg_id
        spool:      $abs_spool
    }

    # Write per-task HALT marker
    let halt_path = [$abs_root, "var", "mail", $"HALT.($task_id)"] | path join
    let halt_content = [
        $"task_id       = \"($task_id)\""
        $"reason        = \"($reason)\""
        $"verdict       = \"($verdict)\""
        $"attempts      = ($attempts)"
        $"escalated_at  = \"($ts_iso)\""
    ] | str join "\n"

    $halt_content | save --force $halt_path
    log-step "escalate-halt" "HALT marker written" {
        task_id:   $task_id
        halt_path: $halt_path
    }

    log-step "escalate-done" "D3 escalation complete — awaiting operator action" {
        task_id:    $task_id
        reason:     $reason
        message_id: $msg_id
    }
}
