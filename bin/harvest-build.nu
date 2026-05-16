#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# harvest-build.nu — poll fbuild for smolBSD build completion and harvest
# the resulting qcow2 artifact to minim4-24.
#
# Usage:
#   nu bin/harvest-build.nu                          # poll until done (default 2 h)
#   nu bin/harvest-build.nu --check-now              # single poll and exit
#   nu bin/harvest-build.nu --dry-run                # print SSH commands only
#   nu bin/harvest-build.nu --poll-interval 60       # check every 60 s
#
# The build is launched by bin/smolbuild-amd64.sh inside a screen session on
# fbuild (fb-vm-24, reached via ssh -J minim4-24 -p 2222 builder@localhost).
# This script monitors that session, waits for the artifact, then SCPs it to
# minim4-24:~/smolbsd-artifacts/ and appends a task-0038 result to
# var/mail/spool.
#
# Artifact search order (both paths checked each poll):
#   1. /tmp/smolbsd-amd64-out/*.qcow2                    (copied there by build script on finish)
#   2. /usr/obj/amd64.amd64/usr/src/release/**/*.qcow2   (make release OBJDIR output)
#
# See: bin/smolbuild-amd64.sh (build script on fbuild)
#      var/mail/spool task-0037 (build launch record)

# ── Logging ────────────────────────────────────────────────────────────────────

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── SSH helper ─────────────────────────────────────────────────────────────────

# Run a command on fbuild via ssh -J <jump> -p <port> <target>.
# Returns {exit_code, stdout, stderr}.
def ssh-fbuild [
    jump:    string
    port:    int
    target:  string
    cmd:     string
    dry_run: bool
] {
    if $dry_run {
        print $"[dry-run] ssh -J ($jump) -p ($port) ($target) \"($cmd)\""
        return {exit_code: 0, stdout: "", stderr: ""}
    }
    let port_s = $port | into string
    (^ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -J $jump -p $port_s $target $cmd | complete)
}

# ── Poll helpers ───────────────────────────────────────────────────────────────

# Check whether the screen session is still alive.
# Returns "running" | "dead" | "unknown".
def check-screen [
    jump: string, port: int, target: string,
    session: string, dry_run: bool
] {
    let r = ssh-fbuild $jump $port $target $"screen -ls | grep ($session)" $dry_run
    if $dry_run { return "unknown" }
    if $r.exit_code == 0 and ($r.stdout | str length) > 0 { "running" } else { "dead" }
}

# Fetch the last N lines of the build log.
def tail-log [
    jump: string, port: int, target: string,
    log_file: string, lines: int, dry_run: bool
] {
    let r = ssh-fbuild $jump $port $target $"tail -($lines) ($log_file) 2>/dev/null || echo 'log-not-found'" $dry_run
    if $dry_run { return "" }
    $r.stdout | str trim
}

# Check whether a build artifact (qcow2) is present on fbuild.
# Returns the remote path if found, or "" if not yet present.
def find-artifact [
    jump: string, port: int, target: string, dry_run: bool
] {
    # Search both the build script's copy dir and make release output paths.
    # FreeBSD MAKEOBJDIRPREFIX layout: /usr/obj/<target>.<arch>/usr/src/release/
    # For amd64: /usr/obj/amd64.amd64/usr/src/release/
    # vm-image subdir: /usr/obj/amd64.amd64/usr/src/release/vm/
    # Use a single semicolon-separated sh -c string to avoid Nushell escape issues.
    let search_cmd = "sh -c 'f=$(ls /tmp/smolbsd-amd64-out/*.qcow2 2>/dev/null | head -1); [ -n \"$f\" ] && echo \"$f\" && exit 0; f=$(find /usr/obj/amd64.amd64/usr/src/release -name *.qcow2 2>/dev/null | head -1); [ -n \"$f\" ] && echo \"$f\" && exit 0; echo'"
    let r = ssh-fbuild $jump $port $target $search_cmd $dry_run
    if $dry_run { return "" }
    $r.stdout | str trim
}

# Infer build success from the log file tail.
# Looks for the sentinel "=== artifacts ready ===" or "=== build complete" lines.
# Returns "pass" | "fail" | "running" | "unknown".
def infer-build-status [log_tail: string] {
    if ($log_tail | str contains "=== artifacts ready ===") { return "pass" }
    if ($log_tail | str contains "=== build complete") { return "pass" }
    if ($log_tail | str contains "Error") or ($log_tail | str contains "Stop.") { return "fail" }
    if ($log_tail | str contains "*** Error") { return "fail" }
    "running"
}

# ── Harvest ────────────────────────────────────────────────────────────────────

# SCP artifact from fbuild to minim4-24 dest_dir.
# Returns {exit_code, local_path}.
def harvest-artifact [
    jump:         string
    port:         int
    target:       string
    remote_path:  string
    dest_dir:     string
    dry_run:      bool
] {
    let filename  = $remote_path | path basename
    let local_dir = $dest_dir | str replace "~" $env.HOME
    let local_path = [$local_dir $filename] | path join

    if $dry_run {
        print $"[dry-run] mkdir -p ($local_dir)"
        print $"[dry-run] scp -J ($jump) -P ($port) ($target):($remote_path) ($local_path)"
        return {exit_code: 0, local_path: $local_path}
    }

    ^mkdir -p $local_dir

    # SCP via the jump host.
    let port_s   = $port | into string
    let src_spec = $"($target):($remote_path)"
    ^scp -o StrictHostKeyChecking=no -J $jump -P $port_s $src_spec $local_path
    let rc = $env.LAST_EXIT_CODE
    {exit_code: $rc, local_path: $local_path}
}

# Get qemu-img info on the harvested file.
def qemu-info [local_path: string] {
    let r = (^qemu-img info $local_path | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { "qemu-img info unavailable" }
}

# ── Spool entry ────────────────────────────────────────────────────────────────

# Append a task-0038 result message to var/mail/spool.
def append-spool [
    verdict:      string   # "pass" | "fail" | "timeout" | "in-progress"
    remote_path:  string
    local_path:   string
    build_status: string
    log_tail:     string
    artifact_info: string
    polls_done:   int
    elapsed_min:  int
] {
    let spool = "var/mail/spool"
    let ts    = date now | format date "%a %b %d %H:%M:%S %Y"
    let ts_iso = date now | format date "%Y-%m-%dT%H:%M:%SZ"

    let body = $"From smolbsd-runner ($ts)
From: runner@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-0038] smolBSD amd64 SMOLBSD-kernel build harvest — ($verdict)
Date: ($ts_iso)
Message-ID: <task-0038.runner@smolbsd.local>
In-Reply-To: <task-0037.runner@smolbsd.local>
X-Project: smolbsd
X-Phase: tinyos/phase-iii
X-Verdict: ($verdict)
X-Attempt: 1
Content-Type: text/toml; charset=utf-8

task_id       = \"task-0038\"
verdict       = \"($verdict)\"
run_date      = \"($ts_iso)\"
runner        = \"claude-sonnet-4-6 / blissful-shockley worktree\"
polls_done    = ($polls_done)
elapsed_min   = ($elapsed_min)
build_status  = \"($build_status)\"

[artifact]
remote_path   = \"($remote_path)\"
local_path    = \"($local_path)\"
info          = \"\"\"
($artifact_info)
\"\"\"

[log_tail]
lines = \"\"\"
($log_tail)
\"\"\"
"
    $body | save --append $spool
}

# ── Single-poll logic ─────────────────────────────────────────────────────────

# Run one complete poll cycle.  Returns a record describing the current state.
# {done: bool, artifact: string, screen: string, build_status: string, log_tail: string}
def do-poll [
    jump: string, port: int, target: string,
    session: string, log_file: string, dry_run: bool
] {
    let screen_state  = check-screen  $jump $port $target $session $dry_run
    let log_tail      = tail-log      $jump $port $target $log_file 5 $dry_run
    let artifact_path = find-artifact $jump $port $target $dry_run
    let build_status  = infer-build-status $log_tail

    let done = (
        ($artifact_path | str length) > 0
    ) or (
        $screen_state == "dead" and $build_status != "running"
    )

    {
        done:         $done
        artifact:     $artifact_path
        screen:       $screen_state
        build_status: $build_status
        log_tail:     $log_tail
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Poll fbuild for smolBSD amd64 build completion and harvest the artifact.
#
# --screen-session  Screen session name to monitor (default: smolbuild-amd64)
# --log-file        Build log path on fbuild (default: /tmp/smolbuild-amd64.log)
# --poll-interval   Seconds between polls (default: 120)
# --max-polls       Maximum number of polls before giving up (default: 60 = 2 h)
# --dest-dir        Local destination for harvested artifact (default: ~/smolbsd-artifacts)
# --ssh-target      SSH login for fbuild (default: builder@localhost)
# --ssh-jump        SSH jump host (default: minim4-24)
# --ssh-port        SSH port for fbuild (default: 2222)
# --dry-run         Print SSH/SCP commands without executing
# --check-now       Do a single poll and exit immediately (no waiting)
def main [
    --screen-session: string = "smolbuild-amd64"
    --log-file:       string = "/tmp/smolbuild-amd64.log"
    --poll-interval:  int    = 120
    --max-polls:      int    = 60
    --dest-dir:       string = "~/smolbsd-artifacts"
    --ssh-target:     string = "builder@localhost"
    --ssh-jump:       string = "minim4-24"
    --ssh-port:       int    = 2222
    --dry-run
    --check-now
] {
    log-step "harvest-build" "starting" {
        session:  $screen_session
        log:      $log_file
        target:   $ssh_target
        jump:     $ssh_jump
        port:     $ssh_port
        dest_dir: $dest_dir
        dry_run:  $dry_run
        check_now: $check_now
    }

    let t0 = date now

    # ── --check-now: single poll, report, exit ──────────────────────────────
    if $check_now {
        log-step "poll" "single poll (--check-now)" {poll: 1}
        let state = do-poll $ssh_jump $ssh_port $ssh_target $screen_session $log_file $dry_run

        log-step "poll-result" "poll result" {
            screen:       $state.screen
            build_status: $state.build_status
            artifact:     $state.artifact
            done:         $state.done
        }
        print ""
        print $"screen session: ($state.screen)"
        print $"build status:   ($state.build_status)"
        print $"artifact found: (if ($state.artifact | str length) > 0 { $state.artifact } else { 'not yet' })"
        print ""
        print "--- log tail ---"
        print $state.log_tail
        return
    }

    # ── polling loop ─────────────────────────────────────────────────────────
    mut poll_num     = 0
    mut final_state  = {done: false, artifact: "", screen: "unknown", build_status: "unknown", log_tail: ""}

    loop {
        $poll_num = $poll_num + 1

        let elapsed_sec = ((date now) - $t0) / 1sec | into int
        let elapsed_min = ($elapsed_sec / 60 | into int)

        log-step "poll" $"poll ($poll_num)/($max_polls)" {
            elapsed_min: $elapsed_min
            interval_sec: $poll_interval
        }

        let state = do-poll $ssh_jump $ssh_port $ssh_target $screen_session $log_file $dry_run
        $final_state = $state

        log-step "poll-result" "poll result" {
            poll:         $poll_num
            screen:       $state.screen
            build_status: $state.build_status
            artifact:     (if ($state.artifact | str length) > 0 { $state.artifact } else { "pending" })
            done:         $state.done
        }

        # Print log tail for human readers
        let poll_label = $poll_num
        print ""
        print $"--- log tail (poll ($poll_label)) ---"
        print $state.log_tail
        print ""

        # ── artifact found or session ended ──────────────────────────────────
        if $state.done or $poll_num >= $max_polls {
            let verdict = if $poll_num >= $max_polls and not $state.done {
                "timeout"
            } else if $state.build_status == "fail" {
                "fail"
            } else if ($state.artifact | str length) > 0 {
                "pass"
            } else {
                "unknown"
            }

            log-step "harvest" $"build ($verdict)" {
                poll_num:     $poll_num
                artifact:     $state.artifact
                build_status: $state.build_status
            }

            # ── harvest artifact if present ───────────────────────────────────
            mut local_path   = ""
            mut artifact_info = ""

            if ($state.artifact | str length) > 0 {
                log-step "harvest-scp" $"copying artifact to ($dest_dir)"
                let scp_result = harvest-artifact $ssh_jump $ssh_port $ssh_target $state.artifact $dest_dir $dry_run
                $local_path = $scp_result.local_path

                if $scp_result.exit_code == 0 {
                    log-step "harvest-scp" "SCP succeeded" {local: $local_path}
                    if not $dry_run and ($local_path | path exists) {
                        $artifact_info = qemu-info $local_path
                        log-step "artifact-info" "qemu-img info" {info: $artifact_info}
                    }
                } else {
                    log-step "harvest-scp" "SCP FAILED" {exit_code: $scp_result.exit_code}
                }
            }

            # ── append spool entry ────────────────────────────────────────────
            let elapsed_min_final = (((date now) - $t0) / 1sec | into int) / 60 | into int
            if not $dry_run {
                log-step "spool" "appending task-0038 to var/mail/spool" {}
                append-spool $verdict $state.artifact $local_path $state.build_status $state.log_tail $artifact_info $poll_num $elapsed_min_final
            }

            # ── final summary ─────────────────────────────────────────────────
            print ""
            print $"=== HARVEST ($verdict | str upcase) ==="
            print $"polls:       ($poll_num)"
            print $"elapsed:     ($elapsed_min_final) min"
            print $"artifact:    (if ($state.artifact | str length) > 0 { $state.artifact } else { 'not found' })"
            print $"local:       (if ($local_path | str length) > 0 { $local_path } else { 'not copied' })"
            if ($artifact_info | str length) > 0 {
                print ""
                print $artifact_info
            }
            print ""

            if $verdict == "pass" { exit 0 } else { exit 1 }
        }

        # ── sleep until next poll ─────────────────────────────────────────────
        if not $dry_run {
            log-step "sleep" $"waiting ($poll_interval)s until next poll" {}
            ^sleep ($poll_interval | into string)
        } else {
            # dry-run: one iteration is enough to show the command list
            log-step "dry-run" "dry-run mode: stopping after one iteration" {}
            exit 0
        }
    }
}
