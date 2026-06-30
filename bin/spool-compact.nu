# SPDX-License-Identifier: Apache-2.0
# spool-compact.nu — dedup + keep-last trimmer for the mbox spool
#
# Deduplicates and trims the mbox spool to keep it lean during long-running
# coordinator sessions.
#
# Usage:
#   nu bin/spool-compact.nu
#   nu bin/spool-compact.nu --keep-last 100
#   nu bin/spool-compact.nu --spool /path/to/spool
#   nu bin/spool-compact.nu --dry-run
#
# Operations applied in order:
#   1. Dedup — for each Message-ID seen more than once, keep only the first
#              occurrence; drop subsequent duplicates.
#   2. Trim  — if the deduped list exceeds --keep-last, drop the oldest
#              messages until only keep-last remain.
#
# Output: one JSON line to stdout — a record with:
#   original_count    int
#   duplicates_removed int
#   trimmed_count     int
#   final_count       int
#   dry_run           bool

use ./mbox-parse.nu [parse-mbox, msg-id]

# Emit a structured log line to stderr (stdout is reserved for the summary JSON).
def log-info [msg: string, payload: record] {
    let ts = date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    print --stderr $"[spool-compact] ($ts) ($msg) ($payload | to nuon)"
}

# Emit the summary record as compact JSON to stdout.
# All exit paths funnel through here.
def summarize [result: record] {
    print ($result | to json --raw)
}

# Reconstruct a single mbox message string from its parsed record.
# from_line already carries the "From " prefix.
def msg-to-mbox [msg: record] {
    let header_str = (
        $msg.headers
        | transpose key val
        | each {|pair| $"($pair.key): ($pair.val)"}
        | str join "\n"
    )
    $"($msg.from_line)\n($header_str)\n\n($msg.body)\n"
}

# Main entry point.
export def main [
    --keep-last: int    = 200    # keep the N most recent messages; drop the rest
    --spool:     string = "var/mail/spool"
    --dry-run                    # print what would change; touch no files
] {
    let abs_spool = $spool | path expand

    # ── Guard: spool must exist ───────────────────────────────────────────────
    if not ($abs_spool | path exists) {
        summarize {
            original_count:    0
            duplicates_removed: 0
            trimmed_count:     0
            final_count:       0
            dry_run:           $dry_run
        }
        log-info "spool_not_found" {path: $abs_spool}
        return
    }

    # ── Parse messages ────────────────────────────────────────────────────────
    let content  = open --raw $abs_spool
    let messages = if ($content | str trim | str length) == 0 {
        []
    } else {
        parse-mbox $content
    }
    let original_count = $messages | length

    log-info "parsed" {original_count: $original_count, spool: $abs_spool}

    # ── Step 1: Dedup — keep first occurrence of each Message-ID ─────────────
    mut seen_ids: list<string> = []
    mut deduped: list<record> = []

    for msg in $messages {
        let id = msg-id $msg
        if $id == "" {
            # No Message-ID: always keep (cannot dedup without a key)
            $deduped = $deduped | append $msg
        } else if not ($id in $seen_ids) {
            $seen_ids = $seen_ids | append $id
            $deduped = $deduped | append $msg
        }
        # else: duplicate — silently drop
    }

    let duplicates_removed = $original_count - ($deduped | length)
    log-info "dedup_done" {duplicates_removed: $duplicates_removed}

    # ── Step 2: Trim — keep only the last N (most recent) ────────────────────
    let after_dedup_count = $deduped | length
    let trimmed_count = if $after_dedup_count > $keep_last {
        $after_dedup_count - $keep_last
    } else {
        0
    }

    let kept = if $after_dedup_count > $keep_last {
        $deduped | last $keep_last
    } else {
        $deduped
    }

    let final_count = $kept | length

    log-info "trim_done" {trimmed_count: $trimmed_count, final_count: $final_count}

    # ── Dry-run short circuit ─────────────────────────────────────────────────
    if $dry_run {
        summarize {
            original_count:    $original_count
            duplicates_removed: $duplicates_removed
            trimmed_count:     $trimmed_count
            final_count:       $final_count
            dry_run:           true
        }
        return
    }

    # ── Nothing to do? ────────────────────────────────────────────────────────
    if $duplicates_removed == 0 and $trimmed_count == 0 {
        summarize {
            original_count:    $original_count
            duplicates_removed: 0
            trimmed_count:     0
            final_count:       $final_count
            dry_run:           false
        }
        log-info "no_changes_needed" {spool: $abs_spool}
        return
    }

    # ── Rewrite the spool atomically (tmp file → rename) ─────────────────────
    let tmp_path = $"($abs_spool).compact.tmp.($nu.pid)"

    # Write each kept message into the temp file
    for msg in $kept {
        (msg-to-mbox $msg) | save --append $tmp_path
    }

    mv --force $tmp_path $abs_spool

    log-info "spool_rewritten" {
        original_count:    $original_count
        duplicates_removed: $duplicates_removed
        trimmed_count:     $trimmed_count
        final_count:       $final_count
        spool:             $abs_spool
    }

    # ── Summary report ────────────────────────────────────────────────────────
    summarize {
        original_count:    $original_count
        duplicates_removed: $duplicates_removed
        trimmed_count:     $trimmed_count
        final_count:       $final_count
        dry_run:           false
    }
}
