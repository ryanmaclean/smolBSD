# SPDX-License-Identifier: Apache-2.0
# spool-archive.nu — rotate spool > N messages to var/mail/spool.YYYY-MM-DD
#
# Per design spec §15: archive the OLDEST (count - threshold) messages,
# keeping the newest <threshold> messages active in the spool.
#
# Usage:
#   nu bin/spool-archive.nu
#   nu bin/spool-archive.nu --threshold 50
#   nu bin/spool-archive.nu --spool /path/to/spool
#   nu bin/spool-archive.nu --dry-run
#
# FSM safety: never archives a message whose Message-ID is referenced by
# var/run/coord-state.toml (pending_request_id).
#
# Output: one JSON line to stdout — a record with:
#   archived_count  int
#   active_count    int
#   archive_path    string | null
#   skipped_reason  string | null

use ./mbox-parse.nu [parse-mbox, msg-id]

# Emit a structured log line to stderr (stdout is reserved for the summary JSON).
def log-info [msg: string, payload: record] {
    let ts = date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    print --stderr $"[spool-archive] ($ts) ($msg) ($payload | to nuon)"
}

# Emit the summary record as compact JSON to stdout.
# All exit paths funnel through here.
def summarize [result: record] {
    print ($result | to json --raw)
}

# Load coord-state.toml and return the list of Message-IDs that are live
# (currently pending / in-flight — must not be rotated out of the active spool).
def live-ids-from-state [state_path: string] {
    if not ($state_path | path exists) {
        return []
    }
    let state = try {
        open --raw $state_path | from toml
    } catch {
        log-info "state_load_error" {path: $state_path, reason: "parse failed"}
        return []
    }

    mut ids = []

    # pending_request_id — the coordinator is waiting for a reply to this message.
    let pending = $state | get "pending_request_id"? | default ""
    if ($pending | str trim | str length) > 0 {
        $ids = $ids | append $pending
    }

    $ids
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
    --threshold: int    = 100    # keep newest N messages; archive the rest
    --spool:     string = "var/mail/spool"
    --state:     string = "var/run/coord-state.toml"
    --dry-run                    # print what would happen; touch no files
    --root:      string = "."    # project root
] {
    let abs_root      = $root | path expand
    let abs_spool     = [$abs_root, $spool] | path join
    let abs_state     = [$abs_root, $state] | path join
    let abs_mail_dir  = $abs_spool | path dirname

    # ── Guard: spool must exist ───────────────────────────────────────────────
    if not ($abs_spool | path exists) {
        summarize {
            archived_count: 0
            active_count:   0
            archive_path:   null
            skipped_reason: $"spool not found: ($abs_spool)"
        }
        return
    }

    # ── Parse messages ────────────────────────────────────────────────────────
    let content  = open --raw $abs_spool
    let messages = parse-mbox $content
    let total    = $messages | length

    if $total <= $threshold {
        summarize {
            archived_count: 0
            active_count:   $total
            archive_path:   null
            skipped_reason: $"spool has ($total) messages <= threshold ($threshold); nothing to do"
        }
        return
    }

    let archive_count = $total - $threshold
    let to_archive    = $messages | first $archive_count
    let to_keep       = $messages | last $threshold

    # ── FSM safety check ─────────────────────────────────────────────────────
    let protected_ids = live-ids-from-state $abs_state

    # Build the set of Message-IDs we would archive.
    let archive_ids = $to_archive | each {|m| msg-id $m} | where {|id| ($id | str length) > 0}

    # Check: any protected id lands in the archive set?
    let blocked = $protected_ids | where {|id| $id in $archive_ids}

    if ($blocked | length) > 0 {
        let reason = $"archive would orphan live FSM message-ids: ($blocked | str join ', ')"
        log-info "archive_blocked" {reason: $reason, protected: ($blocked | str join ", ")}
        summarize {
            archived_count: 0
            active_count:   $total
            archive_path:   null
            skipped_reason: $reason
        }
        return
    }

    # ── Build archive path ────────────────────────────────────────────────────
    let utc_date     = date now | date to-timezone UTC | format date "%Y-%m-%d"
    let archive_path = $"($abs_spool).($utc_date)"

    # ── Dry-run short circuit ─────────────────────────────────────────────────
    if $dry_run {
        summarize {
            archived_count: $archive_count
            active_count:   $threshold
            archive_path:   $archive_path
            skipped_reason: "dry-run: no files modified"
        }
        return
    }

    # ── Append archived messages to the date-stamped archive file ────────────
    # Append (not overwrite) — multiple runs on the same UTC day accumulate.
    if not ($abs_mail_dir | path exists) {
        mkdir $abs_mail_dir
    }

    for msg in $to_archive {
        (msg-to-mbox $msg) | save --append $archive_path
    }

    log-info "archived" {count: $archive_count, path: $archive_path}

    # ── Rewrite the active spool with only the kept messages ──────────────────
    # Write to a temp file first, then rename over the original (atomic replace).
    let tmp_path = $"($abs_spool).tmp.($nu.pid)"

    for msg in $to_keep {
        (msg-to-mbox $msg) | save --append $tmp_path
    }

    mv --force $tmp_path $abs_spool

    log-info "spool_rewritten" {active_count: $threshold, spool: $abs_spool}

    # ── Summary report ────────────────────────────────────────────────────────
    summarize {
        archived_count: $archive_count
        active_count:   $threshold
        archive_path:   $archive_path
        skipped_reason: null
    }
}
