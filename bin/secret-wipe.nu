#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# secret-wipe.nu — D1 secret envelope destroyer for smolfire coordinator
#
# Securely removes all secret envelopes for a given task from
# var/run/secrets/<task-id>/.  Called by coord-tick after harvesting a reply,
# regardless of verdict (per D1: envelopes are ephemeral).
#
# Uses `rm -P` (secure overwrite) on macOS/FreeBSD when available.
#
# Usage:
#   nu bin/secret-wipe.nu --task-id t42
#   nu bin/secret-wipe.nu --task-id t42 --root /path/to/project

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def main [
    --task-id: string       # task whose secrets to wipe (required)
    --root:    string = "." # project root
] {
    if $task_id == null or $task_id == "" {
        error make {msg: "--task-id is required"}
    }

    let abs_root     = $root | path expand
    let envelope_dir = [$abs_root, "var", "run", "secrets", $task_id] | path join

    if not ($envelope_dir | path exists) {
        log-step "secret-wipe" "nothing to wipe — directory absent" {task_id: $task_id}
        return
    }

    # Count files before deletion
    let files = try { ls $envelope_dir | where type == "file" } catch { [] }
    let file_count = $files | length

    # Attempt secure delete: `rm -P` overwrites before unlinking (macOS/FreeBSD).
    # If rm -P is unavailable (Linux), fall back to plain rm -rf.
    let rm_result = ^rm -Prf $envelope_dir | complete
    if $rm_result.exit_code != 0 {
        # rm -P flag not supported (GNU rm on Linux) — fall back
        ^rm -rf $envelope_dir
    }

    log-step "secret-wipe" "secrets wiped" {
        task_id:     $task_id
        files_wiped: $file_count
        directory:   $envelope_dir
    }
}
