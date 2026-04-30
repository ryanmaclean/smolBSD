# SPDX-License-Identifier: Apache-2.0
# mbox-parse.nu — mbox+TOML parser module for smolBSD coordinator
#
# Usage:
#   use bin/mbox-parse.nu [parse-mbox, extract-toml, msg-id]
#
# Each mbox message is delimited by a line starting with "From " (space, not
# colon).  Bodies are expected to be Content-Type: text/toml; charset=utf-8
# per the smolBSD mailbox protocol spec §4.

# Split an mbox string into a list of message records.
# Each record has: from_line, headers (record), body (string).
export def parse-mbox [content: string] {
    # Split on lines that start with "From " — the mbox separator.
    # We keep the separator line as `from_line` on each message.
    let raw_messages = (
        $content
        | split row "\nFrom "
        | enumerate
        | each {|entry|
            # The very first segment starts with "From " (intact); subsequent
            # items had the "From " prefix consumed by the split delimiter.
            let raw = if $entry.index == 0 {
                if ($entry.item | str starts-with "From ") {
                    $entry.item | str substring 5..   # strip leading "From "
                } else {
                    $entry.item
                }
            } else {
                $entry.item   # separator already consumed by split
            }
            $raw
        }
        | where {|s| ($s | str trim | str length) > 0 }
    )

    $raw_messages | each {|msg_body|
        # First line is the mbox "From " envelope line (sender + timestamp).
        let lines = $msg_body | lines
        if ($lines | length) == 0 { return null }

        let from_line = $"From ($lines | first)"

        # Headers end at the first blank line; body is everything after.
        let blank_idx_result = (
            $lines
            | enumerate
            | skip 1               # skip the from_line we already captured
            | where {|e| ($e.item | str trim) == ""}
            | first
        )

        # Guard against messages with no blank line (malformed — skip body).
        let blank_idx = $blank_idx_result | get index? | default ($lines | length)

        let header_lines = $lines | skip 1 | first ([$blank_idx - 1, 0] | math max)
        let body_lines   = if ($blank_idx + 1) < ($lines | length) {
            $lines | skip ($blank_idx + 1)
        } else {
            []
        }

        let headers = parse-headers $header_lines
        let body    = $body_lines | str join "\n"

        {from_line: $from_line, headers: $headers, body: $body}
    }
    | where {|r| $r != null }
}

# Parse RFC822 header lines into a flat record.
# Folded headers (continuation lines starting with whitespace) are unfolded.
def parse-headers [lines: list<string>] {
    # Build a list of {key, val} pairs, then collapse to a record.
    # Nushell records cannot be mutated in place, so we accumulate a list.
    mut pairs: list<record<key: string, val: string>> = []
    mut current_key = ""
    mut current_val = ""

    for line in $lines {
        if ($line | str starts-with " ") or ($line | str starts-with "\t") {
            # Folded continuation — append to current header value.
            $current_val = $"($current_val) ($line | str trim)"
        } else {
            # Flush the previous header before starting a new one.
            if $current_key != "" {
                $pairs = $pairs | append {key: $current_key, val: $current_val}
            }
            let colon_pos = $line | str index-of ":"
            if $colon_pos > 0 {
                $current_key = $line | str substring ..$colon_pos | str trim
                $current_val = $line | str substring ($colon_pos + 1).. | str trim
            } else {
                $current_key = ""
                $current_val = ""
            }
        }
    }
    # Flush the final header.
    if $current_key != "" {
        $pairs = $pairs | append {key: $current_key, val: $current_val}
    }

    # Convert list of {key,val} pairs to a record.
    # Duplicate header names: last one wins (RFC 2822 is lenient here).
    $pairs | reduce --fold {} {|pair, acc| $acc | insert $pair.key $pair.val}
}

# Parse the TOML body of a message record.
# Returns the parsed record, or {_parse_error: "<msg>"} on failure.
export def extract-toml [msg: record] {
    let body = $msg.body | str trim
    if ($body | str length) == 0 {
        return {_parse_error: "empty body"}
    }
    try {
        $body | from toml
    } catch {|err|
        {_parse_error: ($err | get msg? | default "toml parse failed")}
    }
}

# Extract the Message-ID header value from a parsed message record.
# Returns an empty string if the header is absent.
export def msg-id [msg: record] {
    $msg.headers | get "Message-ID"? | default ""
}
