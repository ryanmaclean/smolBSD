#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# spool-emit-control.nu — emit control messages into the smolfire mbox spool
#
# Supported actions: rotate-key, halt, halt-all, resume
#
# Usage:
#   nu bin/spool-emit-control.nu --action halt     --task-id t42 --reason "manual pause"
#   nu bin/spool-emit-control.nu --action resume   --task-id t42 --resume-action retry
#   nu bin/spool-emit-control.nu --action halt-all --reason "emergency stop"

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def main [
    --action:        string                   # rotate-key | halt | halt-all | resume
    --task-id:       string = ""              # target task (required except for halt-all)
    --reason:        string = ""
    --resume-action: string = "retry"         # retry | abort | edit  (resume only)
    --spool:         string = "var/mail/spool"
    --root:          string = "."
] {
    let valid_actions = ["rotate-key", "halt", "halt-all", "resume"]
    if $action == null or not ($action in $valid_actions) {
        error make {msg: $"--action must be one of: ($valid_actions | str join ', ')"}
    }
    if $action != "halt-all" and ($task_id == "" or $task_id == null) {
        error make {msg: $"--task-id required for action '($action)'"}
    }

    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join
    let mail_dir  = $abs_spool | path dirname
    if not ($mail_dir | path exists) { mkdir $mail_dir }

    let ts     = date now | date to-timezone utc | format date "%Y%m%d%H%M%S"
    let ts_iso = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let safe_id = if $task_id != "" { $task_id } else { "all" }
    let msg_id  = $"<ctrl.($action).($safe_id).($ts)@smolfire.local>"

    mut body_lines = [
        $"category      = \"control\""
        $"action        = \"($action)\""
        $"task_id       = \"($task_id)\""
        $"reason        = \"($reason)\""
    ]
    if $action == "resume" {
        $body_lines = ($body_lines | append $"resume_action = \"($resume_action)\"")
    }

    let mbox_msg = ([
        $"From coordinator@smolfire.local ($ts)"
        "From: coordinator@smolfire.local"
        "To: coordinator@smolfire.local"
        $"Subject: [CONTROL] ($action) ($safe_id)"
        $"Message-ID: ($msg_id)"
        $"X-Control-Action: ($action)"
        "Content-Type: text/toml; charset=utf-8"
        ""
        ($body_lines | str join "\n")
        ""
    ] | str join "\n")

    $mbox_msg | save --append $abs_spool
    log-step "control-emit" "control message appended" {action: $action, task_id: $task_id, message_id: $msg_id}

    # HALT marker side-effects
    if $action == "halt" {
        let p = [$abs_root, "var", "mail", $"HALT.($task_id)"] | path join
        $"task_id = \"($task_id)\"\nreason = \"($reason)\"\nhalted_at = \"($ts_iso)\"\n" | save --force $p
        log-step "control-halt" "per-task HALT marker written" {task_id: $task_id, path: $p}
    } else if $action == "halt-all" {
        let p = [$abs_root, "var", "mail", "HALT"] | path join
        $"reason = \"($reason)\"\nhalted_at = \"($ts_iso)\"\n" | save --force $p
        log-step "control-halt-all" "global HALT marker written" {path: $p}
    } else if $action == "resume" {
        let p = [$abs_root, "var", "mail", $"HALT.($task_id)"] | path join
        if ($p | path exists) {
            ^rm -f $p
            log-step "control-resume" "HALT marker removed" {task_id: $task_id, path: $p}
        } else {
            log-step "control-resume" "no HALT marker found" {task_id: $task_id}
        }
    }

    log-step "control-done" "complete" {action: $action, task_id: $task_id}
}
