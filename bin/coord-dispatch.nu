#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/coord-dispatch.nu — launch a subagent via the claude CLI
#
# The coordinator writes a task brief to the spool (already implemented).
# This module actually spawns the subagent process that will read that brief
# and write a reply back to the spool.

# Find the claude CLI binary.
def find-claude [] {
    let candidates = [
        "/opt/homebrew/bin/claude"
        "/usr/local/bin/claude"
        ($env.HOME | path join ".local/bin/claude")
    ]
    let found = $candidates | where { |p| $p | path exists }
    if ($found | is-empty) { null } else { $found | first }
}

# Dispatch a subagent for a task.
# Returns a record with {launched: bool, pid: int, log_path: string}
export def dispatch-subagent [
    task_id:   string   # e.g. "task-0007"
    role:      string   # e.g. "builder" — determines the prompt prefix
    brief:     string   # the full task brief (TOML body from the spool message)
    spool:     string   # path to the spool file (so agent can append reply)
    log_dir:   string = "var/run/dispatch-logs"  # where to write agent stdout
] {
    let claude = find-claude
    if $claude == null {
        return {launched: false, pid: 0, log_path: "", error: "claude CLI not found"}
    }

    # Build the prompt: instruct the agent to read the spool for its task
    # and append a reply using the mbox+TOML protocol.
    let prompt = $"You are a smolBSD subagent with role '($role)'.

Your task brief \(task_id: ($task_id)\) is in the spool at ($spool).
Find the message with Message-ID containing '($task_id).coord@smolbsd.local', read the TOML body for your instructions, do the work, then append a properly-formatted mbox+TOML reply to ($spool).

Brief summary:
($brief | str substring ..500)

Reply format: standard smolBSD mbox+TOML envelope with X-Verdict: pass|fail and [[claims]] blocks."

    # Ensure log dir exists
    if not ($log_dir | path exists) { mkdir $log_dir }
    let log_path = [$log_dir, $"($task_id)-($role).log"] | path join
    let ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"

    # Spawn claude as a background job.
    # job spawn returns the job ID (int); we store it as "pid" for tracking.
    # --print: non-interactive, just run the prompt
    # --model: use sonnet (cost-conscious per project preference)
    # Note: Nushell closures capture variables by value, so we bind locals explicitly.
    let result = try {
        let claude_bin = $claude
        let job_id = job spawn {
            ^$claude_bin --print --model claude-sonnet-4-6 $prompt o> $log_path e>> $log_path
        }
        {launched: true, pid: $job_id, log_path: $log_path, started_at: $ts}
    } catch {|err|
        {launched: false, pid: 0, log_path: $log_path, error: ($err | get msg? | default "spawn failed"), started_at: $ts}
    }

    $result
}

# Check if a dispatched subagent job is still running.
# pid here is a Nushell job ID (returned by job spawn), not an OS PID.
export def agent-running? [pid: int] {
    if $pid == 0 { return false }
    let jobs = job list
    ($jobs | where id == $pid | length) > 0
}
