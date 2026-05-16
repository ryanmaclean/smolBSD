#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# spool-archive.nu — rotate the smolBSD mbox spool when it exceeds N messages
#
# When the spool grows beyond --max-msgs, the oldest messages are moved to a
# dated archive file (var/mail/spool.YYYY-MM-DD), keeping only --keep recent
# messages in the live spool.  Prevents unbounded growth during long campaigns.
#
# Usage:
#   nu bin/spool-archive.nu                        # archive if >500 msgs, keep 50
#   nu bin/spool-archive.nu --max-msgs 200 --keep 20
#   nu bin/spool-archive.nu --dry-run              # show what would happen

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def main [
    --spool:    string = "var/mail/spool"
    --root:     string = "."
    --max-msgs: int    = 500   # archive when spool exceeds this count
    --keep:     int    = 50    # keep this many recent messages in live spool
    --dry-run              # print plan without modifying files
] {
    use ./mbox-parse.nu [parse-mbox, msg-id]

    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join

    if not ($abs_spool | path exists) {
        log-step "archive-check" "spool absent — nothing to archive" {}
        return
    }

    let content  = open --raw $abs_spool
    let messages = parse-mbox $content | compact
    let total    = $messages | length

    if $total <= $max_msgs {
        log-step "archive-check" "no archive needed" {total: $total, max_msgs: $max_msgs}
        return
    }

    let archive_count = $total - $keep
    let date_str      = date now | date to-timezone utc | format date "%Y-%m-%d"
    let archive_path  = $"($abs_spool).($date_str)"

    log-step "archive-plan" "archiving old messages" {
        total:         $total
        to_archive:    $archive_count
        to_keep:       $keep
        archive_path:  $archive_path
        dry_run:       $dry_run
    }

    if $dry_run {
        print $"Would archive ($archive_count) messages to ($archive_path)"
        print $"Would keep ($keep) most recent messages in ($abs_spool)"
        return
    }

    # Split: oldest archive_count messages → archive, newest keep → live spool.
    # Reconstruct mbox by splitting raw content on "\nFrom " separator.
    # Each segment after split had its "From " prefix consumed; we restore it.
    let segments = (
        $content
        | split row "\nFrom "
        | enumerate
        | each {|e|
            if $e.index == 0 { $e.item } else { $"From ($e.item)" }
        }
        | where {|s| ($s | str trim | str length) > 0 }
    )

    let seg_count = $segments | length
    if $seg_count != $total {
        # Parse count and segment count diverge (edge case) — use segment split
        log-step "archive-warn" "segment count mismatch; using segment split" {
            parsed: $total, segments: $seg_count
        }
    }

    let n_archive = if $seg_count > $keep { $seg_count - $keep } else { 0 }
    let n_keep    = $seg_count - $n_archive

    let archive_segs = $segments | first $n_archive
    let live_segs    = $segments | last $n_keep

    # Append to archive (may already exist from a same-day earlier run)
    let archive_text = $archive_segs | str join "\n"
    $archive_text | save --append $archive_path

    # Overwrite live spool with kept messages
    let live_text = $live_segs | str join "\n"
    $live_text | save --force $abs_spool

    log-step "archive-done" "archive complete" {
        archived:     $n_archive
        kept:         $n_keep
        archive_path: $archive_path
        spool:        $abs_spool
    }
}
