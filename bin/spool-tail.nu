#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# spool-tail.nu — mbox spool viewer with TOML pretty-printing
#
# Displays the last N messages from the spool in a human-readable format,
# with TOML bodies pretty-printed as Nushell tables.
#
# Usage:
#   nu bin/spool-tail.nu                        # last 10 messages
#   nu bin/spool-tail.nu --last 0               # all messages
#   nu bin/spool-tail.nu --filter t42           # only messages for task t42
#   nu bin/spool-tail.nu --raw                  # raw mbox output, no formatting

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def main [
    --spool:  string = "var/mail/spool"
    --root:   string = "."
    --last:   int    = 10     # 0 = all
    --filter: string = ""     # substring match on task_id in body
    --raw                     # print raw mbox text, no formatting
] {
    use ./mbox-parse.nu [parse-mbox, extract-toml, msg-id]

    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join

    if not ($abs_spool | path exists) {
        print "spool is empty (file absent)"
        return
    }

    let content  = open --raw $abs_spool
    let messages = parse-mbox $content | compact

    # Filter by task_id substring
    let filtered = if $filter != "" {
        $messages | where {|m|
            let payload = extract-toml $m
            let task_id = $payload | get "task_id"? | default ""
            $task_id | str contains $filter
        }
    } else {
        $messages
    }

    let total = $filtered | length

    # Apply --last limit
    let shown = if $last > 0 and $last < $total {
        $filtered | last $last
    } else {
        $filtered
    }

    let shown_count = $shown | length

    # Print each message
    mut idx = if $last > 0 and $last < $total { $total - $last + 1 } else { 1 }
    for msg in $shown {
        let from_h    = $msg.headers | get "From"?       | default "?"
        let to_h      = $msg.headers | get "To"?         | default "?"
        let subj      = $msg.headers | get "Subject"?    | default ""
        let id        = msg-id $msg
        let irt       = $msg.headers | get "In-Reply-To"? | default ""

        print $"── [($idx)/($total)] ──────────────────────────────────────────"
        print $"  From:    ($from_h)"
        print $"  To:      ($to_h)"
        if $subj != "" { print $"  Subject: ($subj)" }
        print $"  MsgID:   ($id)"
        if $irt != "" { print $"  IRT:     ($irt)" }

        if $raw {
            print ""
            print $msg.body
        } else {
            let payload = extract-toml $msg
            if "_parse_error" in ($payload | columns) {
                print $"  Body:    (raw — ($payload._parse_error))"
                print $msg.body
            } else {
                print ""
                $payload | table | print
            }
        }
        print ""
        $idx = $idx + 1
    }

    let n_shown = $shown | length
    print $"Total: ($total) messages, showing ($n_shown)"
}
