#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/spool-tail.nu — mailx-style spool viewer with TOML pretty-printing
#
# Usage:
#   nu bin/spool-tail.nu                        # summary table of all messages
#   nu bin/spool-tail.nu --last N               # last N messages, full envelope + TOML body
#   nu bin/spool-tail.nu --id <message-id>      # one message by Message-ID (substring match)
#   nu bin/spool-tail.nu --task <task-id>       # messages whose TOML body has task_id = "<task-id>"
#   nu bin/spool-tail.nu --spool PATH           # override default spool path
#
# Default spool: var/mail/spool (relative to cwd).

use mbox-parse.nu [parse-mbox, extract-toml, msg-id]

# ── Internal helpers ───────────────────────────────────────────────────────────

# Extract a named header value from a parsed message, returning "" if absent.
def get-header [msg: record, key: string] {
    $msg.headers | get -o $key | default ""
}

# Extract verdict from a parsed TOML body record, or "" if absent/parse error.
def get-verdict [toml: record] {
    if ($toml | get -o "_parse_error" | is-not-empty) {
        "(malformed)"
    } else {
        $toml | get -o "verdict" | default ""
    }
}

# Extract task_id from a parsed TOML body record, or "" if absent/parse error.
def get-task-id [toml: record] {
    if ($toml | get -o "_parse_error" | is-not-empty) {
        ""
    } else {
        $toml | get -o "task_id" | default ""
    }
}

# Build a summary row record from a parsed message and its index.
def build-summary-row [msg: record, idx: int] {
    let toml = extract-toml $msg
    {
        idx:        $idx
        date:       (get-header $msg "Date")
        from:       (get-header $msg "From")
        to:         (get-header $msg "To")
        subject:    (get-header $msg "Subject" | default "(no subject)")
        "msg-id":   (msg-id $msg)
        verdict:    (get-verdict $toml)
    }
}

# Print a single message in full: envelope headers + pretty TOML body.
def print-message [msg: record, idx: int] {
    print $"\n━━━ Message #($idx) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print $"from_line : ($msg.from_line)"

    # Print headers in sorted order for consistency
    let hdrs = $msg.headers
    $hdrs | columns | sort | each {|k|
        print $"($k): ($hdrs | get $k)"
    }

    print ""  # blank line separating headers from body
    let body = $msg.body | str trim
    if ($body | str length) == 0 {
        print "(empty body)"
    } else {
        let toml = extract-toml $msg
        if ($toml | get -o "_parse_error" | is-not-empty) {
            print $"[TOML parse error: ($toml._parse_error)]"
            print "--- raw body ---"
            print $body
        } else {
            # Pretty-print by converting through nuon for structured display
            print "--- TOML body ---"
            print ($toml | table --expand)
        }
    }
}

# ── Entry point ────────────────────────────────────────────────────────────────

# View messages in the smolfire coordinator mbox spool.
def main [
    --spool: string = "var/mail/spool"   # path to the mbox spool file
    --last: int = 0                       # show last N messages in full (0 = summary table)
    --id: string = ""                     # show one message by Message-ID substring
    --task: string = ""                   # filter messages by TOML task_id
] {
    # Resolve spool path (support both relative-to-cwd and absolute paths)
    let spool_path = if ($spool | path type) == "file" {
        $spool
    } else if ($spool | path exists) {
        $spool
    } else {
        $spool
    }

    if not ($spool_path | path exists) {
        error make {msg: $"spool not found: ($spool_path)"}
    }

    let content = open --raw $spool_path
    let messages = parse-mbox $content

    if ($messages | length) == 0 {
        print "spool is empty"
        return
    }

    # ── --id mode: single message by Message-ID substring ─────────────────────
    if ($id | str length) > 0 {
        let matched = $messages | enumerate | where {|e|
            (msg-id $e.item) | str contains $id
        }
        if ($matched | length) == 0 {
            print $"no message found with Message-ID containing: ($id)"
            return
        }
        $matched | each {|e|
            print-message $e.item $e.index
        }
        return
    }

    # ── --task mode: filter by TOML task_id ───────────────────────────────────
    if ($task | str length) > 0 {
        let matched = $messages | enumerate | where {|e|
            let toml = extract-toml $e.item
            (get-task-id $toml) == $task
        }
        if ($matched | length) == 0 {
            print $"no messages found with task_id = \"($task)\""
            return
        }
        $matched | each {|e|
            print-message $e.item $e.index
        }
        return
    }

    # ── --last N mode: show last N messages in full ────────────────────────────
    if $last > 0 {
        let total = $messages | length
        let skip_n = if $last >= $total { 0 } else { $total - $last }
        let subset = $messages | enumerate | skip $skip_n
        $subset | each {|e|
            print-message $e.item $e.index
        }
        return
    }

    # ── Default: summary table of all messages ─────────────────────────────────
    let rows = $messages | enumerate | each {|e|
        build-summary-row $e.item $e.index
    }
    # Use a wide rendering so verdict column is not elided in narrow terminals
    print ($rows | table --width 300)
}
