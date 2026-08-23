#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/coord-submit.nu — submit a task to the smolfire coordinator
#
# Usage:
#   nu bin/coord-submit.nu --task-id "task-0042" --role "builder" --subject "Build kernel" --body '...'
#   nu bin/coord-submit.nu --from-file tasks/task-0042.toml
#   echo '...' | nu bin/coord-submit.nu --task-id "task-0042" --role "builder" --subject "..."
#   nu bin/coord-submit.nu --list   # show all pending (unmatched) tasks in spool
#   nu bin/coord-submit.nu --status # show full spool summary

use mbox-parse.nu [parse-mbox, msg-id]

# ── Helpers ────────────────────────────────────────────────────────────────────

# Scan spool for all task-NNNN numbers and return the max (0 if none found).
def max-task-number [spool: string] {
    if not ($spool | path exists) { return 0 }

    let content = open --raw $spool
    let messages = parse-mbox $content

    let task_nums = (
        $messages
        | each {|m|
            let id = msg-id $m
            # Match <task-NNNN.anything@smolfire.local>
            if ($id | str starts-with "<task-") {
                let inner = $id | str substring 1..($id | str length | $in - 2)  # strip < >
                let parts = $inner | split row "."
                if ($parts | length) > 0 {
                    let tag = $parts | first  # e.g. "task-0042"
                    if ($tag | str starts-with "task-") {
                        let num_str = $tag | str substring 5..  # strip "task-"
                        try { $num_str | into int } catch { 0 }
                    } else { 0 }
                } else { 0 }
            } else { 0 }
        }
        | where {|n| $n > 0 }
    )

    if ($task_nums | length) == 0 { 0 } else { $task_nums | math max }
}

# Check whether a task-id already appears in the spool.
def task-id-exists [spool: string, task_id: string] {
    if not ($spool | path exists) { return false }

    let content = open --raw $spool
    let messages = parse-mbox $content
    let target = $"<($task_id)."

    $messages | any {|m|
        let id = msg-id $m
        $id | str starts-with $target
    }
}

# Format an RFC 2822 date string from the current time.
def rfc2822-now [] {
    date now | format date "%a, %d %b %Y %H:%M:%S -0000"
}

# Format the mbox From_ envelope timestamp (asctime style).
def asctime-now [] {
    date now | format date "%a %b %e %H:%M:%S %Y"
}

# Build a minimal TOML task skeleton when no body is supplied.
def default-body [task_id: string, role: string, subject: string] {
    $"task_id = \"($task_id)\"\nrole    = \"($role)\"\n\n[brief]\nobjective = \"($subject)\"\ncontext_pointers = []\nacceptance = \"write reply to spool with verdict=pass and [[claims]] evidence\"\n"
}

# ── List mode ─────────────────────────────────────────────────────────────────

# Find pending (unmatched) tasks. "Requests" are messages NOT addressed to coordinator@.
# A request is "replied" when another message has In-Reply-To matching its Message-ID.
def cmd-list [spool: string] {
    if not ($spool | path exists) {
        print "Spool does not exist."
        return
    }

    let content = open --raw $spool
    let messages = parse-mbox $content

    # Build a set of all In-Reply-To values (replies present in spool).
    let reply_targets = (
        $messages
        | each {|m|
            $m.headers | get "In-Reply-To"? | default ""
        }
        | where {|s| $s != ""}
    )

    # Find requests: To is NOT coordinator@ and has a task- Message-ID.
    let requests = (
        $messages
        | where {|m|
            let to = $m.headers | get "To"? | default ""
            let id = msg-id $m
            let not_to_coord = not ($to | str contains "coordinator@")
            let is_task = ($id | str starts-with "<task-")
            $not_to_coord and $is_task
        }
    )

    if ($requests | length) == 0 {
        print "No task requests found in spool."
        return
    }

    # For each request, determine if a reply exists.
    let rows = $requests | each {|m|
        let id = msg-id $m
        let to = $m.headers | get "To"? | default "unknown"
        let subject = $m.headers | get "Subject"? | default ""
        let inner = $id | str substring 1..($id | str length | $in - 2)
        let parts = $inner | split row "."
        let task_tag = $parts | first | default ""
        let role = $to | split row "@" | first | default "unknown"

        # Check verdict if a reply exists.
        let matched_replies = (
            $messages
            | where {|r|
                let irt = $r.headers | get "In-Reply-To"? | default ""
                $irt == $id
            }
        )

        let status = if ($matched_replies | length) > 0 {
            # Try to extract verdict from the reply body.
            let reply = $matched_replies | first
            let body = $reply.body | str trim
            let verdict = try {
                $body | from toml | get "verdict"? | default "replied"
            } catch {
                "replied"
            }
            $"replied \(($verdict)\)"
        } else {
            "pending"
        }

        {task_id: $task_tag, role: $role, subject: $subject, status: $status}
    }

    print ($rows | table)
}

# ── Status mode ────────────────────────────────────────────────────────────────

def cmd-status [spool: string] {
    if not ($spool | path exists) {
        print "Spool does not exist (0 messages)."
        return
    }

    let content = open --raw $spool
    let messages = parse-mbox $content
    let total = $messages | length

    let halt_path = ($spool | path dirname) + "/HALT"
    let halt_present = $halt_path | path exists

    # Classify each message.
    let requests = $messages | where {|m|
        let to = $m.headers | get "To"? | default ""
        not ($to | str contains "coordinator@")
    }
    let replies = $messages | where {|m|
        let to = $m.headers | get "To"? | default ""
        $to | str contains "coordinator@"
    }

    # Build reply target set.
    let reply_targets = (
        $messages
        | each {|m| $m.headers | get "In-Reply-To"? | default ""}
        | where {|s| $s != ""}
    )

    let pending = $requests | where {|m|
        let id = msg-id $m
        not ($id in $reply_targets)
    }

    print $"total messages:    ($total)"
    print $"requests:          ($requests | length)"
    print $"replies:           ($replies | length)"
    print $"pending requests:  ($pending | length)"
    print $"HALT present:      ($halt_present)"
}

# ── Submit mode ────────────────────────────────────────────────────────────────

def cmd-submit [
    task_id:   string
    role:      string
    subject:   string
    body:      string
    spool:     string
    dry_run:   bool
    run_tick:  bool
] {
    # Ensure spool exists.
    if not ($spool | path exists) {
        let spool_dir = $spool | path dirname
        if not ($spool_dir | path exists) {
            mkdir $spool_dir
        }
        "" | save $spool
    }

    # Guard: task-id already present?
    if (task-id-exists $spool $task_id) {
        error make {msg: $"task ($task_id) already in spool"}
    }

    let role_addr = $"($role)@smolfire.local"
    let ts        = rfc2822-now
    let dstamp    = asctime-now

    let envelope = $"From coord@smolfire.local ($dstamp)\nFrom: coordinator@smolfire.local\nTo: ($role_addr)\nSubject: [($task_id)] ($subject)\nDate: ($ts)\nMessage-ID: <($task_id).coord@smolfire.local>\nX-Project: smolfire\nContent-Type: text/toml; charset=utf-8\n\n($body)\n"

    if $dry_run {
        print $envelope
        return
    }

    $envelope | save --append $spool
    print $"Submitted ($task_id) -> ($role_addr)"
    print $"Spool: ($spool)"

    if $run_tick {
        print "Running coord-tick..."
        let script_dir = $env.CURRENT_FILE? | default "bin/coord-submit.nu" | path dirname
        let tick_path  = [$script_dir, "coord-tick.nu"] | path join
        ^nu --no-config-file $tick_path --spool $spool --max-ticks 10
    }
}

# ── Entry point ────────────────────────────────────────────────────────────────

export def main [
    --task-id: string = ""               # e.g. "task-0042" (auto-generated if empty)
    --role: string = "builder"           # target agent role e.g. builder, researcher, tester
    --subject: string = ""              # message subject
    --body: string = ""                 # TOML body string (or use --from-file)
    --from-file: string = ""            # path to .toml file with task body
    --spool: string = "var/mail/spool"  # path to mbox spool file
    --tick                              # run coord-tick after submitting
    --list                              # list pending tasks and exit
    --status                            # show spool summary and exit
    --dry-run                           # print envelope without writing
] {
    # ── Read-only modes ──────────────────────────────────────────────────────

    if $list {
        cmd-list $spool
        return
    }

    if $status {
        cmd-status $spool
        return
    }

    # ── Resolve body ─────────────────────────────────────────────────────────

    # Check stdin for piped body first.
    let stdin_body = if not ($in | describe | str starts-with "nothing") {
        $in | into string
    } else {
        ""
    }

    mut resolved_body = ""

    if ($from_file | str length) > 0 {
        if not ($from_file | path exists) {
            error make {msg: $"from-file not found: ($from_file)"}
        }
        $resolved_body = open --raw $from_file
    } else if ($body | str length) > 0 {
        $resolved_body = $body
    } else if ($stdin_body | str length) > 0 {
        $resolved_body = $stdin_body
    }

    # ── Validate inputs ──────────────────────────────────────────────────────

    # Subject is required unless loading from a file that may supply it.
    let eff_subject = if ($subject | str length) == 0 and ($from_file | str length) > 0 {
        # Try to extract from the TOML file.
        try {
            open --raw $from_file | from toml | get "subject"? | default ""
        } catch {
            ""
        }
    } else {
        $subject
    }

    if ($eff_subject | str length) == 0 {
        error make {msg: "subject required (--subject or toml file with subject field)"}
    }

    # ── Auto-generate task-id ────────────────────────────────────────────────

    let eff_task_id = if ($task_id | str length) == 0 {
        let next_num = (max-task-number $spool) + 1
        $"task-(($next_num | fill -a r -c '0' -w 4))"
    } else {
        $task_id
    }

    # ── Build body ────────────────────────────────────────────────────────────

    let eff_body = if ($resolved_body | str length) == 0 {
        default-body $eff_task_id $role $eff_subject
    } else {
        $resolved_body
    }

    # ── Submit ────────────────────────────────────────────────────────────────

    cmd-submit $eff_task_id $role $eff_subject $eff_body $spool $dry_run $tick
}
