#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# run-all-vm-tests.nu — orchestrate the "3 consecutive clean runs" CI gate.
#
# Implements the policy from task-0027 audit: physical board testing is
# unlocked only after bin/ci-gate.nu reports gate=open, which requires
# --required-passes consecutive "pass" results in --results-dir.
#
# Loop bound: (required-passes + 2) iterations max.  This allows up to 2
# failures before the gate would have opened, without looping forever.
#
# Usage:
#   nu tests/run-all-vm-tests.nu --image smolbsd-amd64.raw
#   nu tests/run-all-vm-tests.nu --image smolbsd-amd64.raw --tpm
#   nu tests/run-all-vm-tests.nu --image smolbsd-amd64.raw \
#       --results-dir /tmp/ci --required-passes 3 --gap-seconds 30
#   nu tests/run-all-vm-tests.nu --image smolbsd-amd64.raw \
#       --remote <aarch64-builder>.example.com --tpm
#
# Exit codes:
#   0  GATE OPEN  — >= required-passes consecutive passes achieved
#   2  GATE CLOSED — loop exhausted without enough consecutive passes
#   1  unexpected error (missing image, SSH failure, etc.)
#
# --remote: SSH to the target host and run the full script there.
#   The script must be reachable at the same relative path on the remote.
#   Prerequisites (run-vm-tests.nu, ci-gate.nu, etc.) must also be present.

# ── helpers ───────────────────────────────────────────────────────────────────

# Timestamp string suitable for filenames (ISO-8601, no colons).
def ts-filename [] {
    date now | format date "%Y%m%dT%H%M%SZ"
}

# Read the `overall` field from a TOML result file.
# Returns "pass", "fail", or "unknown" if the field is absent or file unreadable.
def read-overall [path: string] {
    if not ($path | path exists) { return "unknown" }
    let parsed = open --raw $path | from toml
    if "overall" in ($parsed | columns) { $parsed | get overall } else { "unknown" }
}

# Count consecutive trailing passes from the results-dir (most-recent-first).
def count-consecutive-passes [results_dir: string] {
    let files = glob $"($results_dir)/*.toml" | sort --reverse
    mut count = 0
    for f in $files {
        if (read-overall $f) == "pass" { $count = $count + 1 } else { break }
    }
    $count
}

# Ask ci-gate.nu whether the gate is open. Returns true/false.
def gate-open [results_dir: string, required: int] {
    let r = (^nu --no-config-file bin/ci-gate.nu --results-dir $results_dir --required $required | complete)
    $r.exit_code == 0
}

# Print a one-line run summary to stdout.
def print-run-summary [n: int, overall: string, duration_s: int] {
    let icon = if $overall == "pass" { "✓" } else { "✗" }
    print $"Run ($n): ($icon) ($overall) (($duration_s)s)"
}

# ── remote dispatch ────────────────────────────────────────────────────────────

# Re-invoke this script on a remote host via SSH.  The remote must have nu and
# the smolBSD repo checked out at the same path, or at least the bin/ and
# tests/ tree reachable from the working directory.
def run-remote [
    host: string,
    image: string,
    arch: string,
    tpm: bool,
    results_dir: string,
    required_passes: int,
    gap_seconds: int,
] {
    let tpm_flag = if $tpm { "--tpm" } else { "" }
    # Build the remote command; remote shell will expand it
    let remote_cmd = (
        $"nu --no-config-file tests/run-all-vm-tests.nu"
        + $" --image ($image)"
        + $" --arch ($arch)"
        + (if $tpm { " --tpm" } else { "" })
        + $" --results-dir ($results_dir)"
        + $" --required-passes ($required_passes)"
        + $" --gap-seconds ($gap_seconds)"
    )
    print $"run-all-vm-tests: delegating to remote ($host)"
    print $"  command: ($remote_cmd)"
    let r = ^ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 $host $remote_cmd | complete
    if $r.exit_code == 0 {
        exit 0
    } else if $r.exit_code == 2 {
        exit 2
    } else {
        error make {msg: $"Remote run failed (exit ($r.exit_code)): ($r.stderr | str trim)"}
    }
}

# ── main ──────────────────────────────────────────────────────────────────────

def main [
    --image: string,                          # path to smolBSD raw image on the bhyve host
    --arch: string = "amd64",                 # target arch (informational; passed to run-vm-tests if supported)
    --tpm,                                    # attach swtpm to bhyve guest
    --results-dir: string = "/tmp/smolbsd-results",  # where TOML result files accumulate
    --required-passes: int = 3,               # consecutive passes required to open the gate
    --remote: string = "",                    # if set, SSH to this host and run the loop there
    --gap-seconds: int = 30,                  # pause between runs (lets bhyve fully release resources)
] {
    # ── 0. remote delegation ──────────────────────────────────────────────────
    if ($remote | str length) > 0 {
        run-remote $remote $image $arch $tpm $results_dir $required_passes $gap_seconds
        return   # unreachable; run-remote calls exit
    }

    # ── 1. validate ───────────────────────────────────────────────────────────
    if ($image | str length) == 0 {
        error make {msg: "--image is required (path to smolBSD raw image)"}
    }
    if not ($image | path exists) {
        error make {msg: $"Image not found: ($image)"}
    }

    # ── 2. create results dir ─────────────────────────────────────────────────
    if not ($results_dir | path exists) {
        mkdir $results_dir
    }

    let max_runs = $required_passes + 2
    print $"run-all-vm-tests: image=($image) arch=($arch) tpm=($tpm)"
    print $"  results-dir=($results_dir) required-passes=($required_passes) max-runs=($max_runs)"
    print ""

    # ── 3. run loop ───────────────────────────────────────────────────────────
    mut run_n = 0
    loop {
        $run_n = $run_n + 1
        if $run_n > $max_runs {
            break
        }

        print $"── Run ($run_n) / ($max_runs) ──────────────────────────────────"

        # Timestamp-named result file so lexicographic sort = chronological.
        let ts        = ts-filename
        let out_file  = $"($results_dir)/run-($ts).toml"
        let run_start = date now

        # Build arg list for run-vm-tests.nu.
        # --arch is not yet a flag in run-vm-tests.nu but included for forward compat.
        let run_args = (
            ["--image" $image "--results-file" $out_file]
            | append (if $tpm { ["--tpm"] } else { [] })
        )

        # Invoke run-vm-tests.nu.  Exit 1 from it means tests failed (not an
        # orchestration error) — we tolerate it and parse the written TOML.
        let r = ^nu --no-config-file bin/run-vm-tests.nu ...$run_args | complete

        let run_end      = date now
        let duration_s   = (($run_end - $run_start) / 1sec) | into int
        let overall      = read-overall $out_file

        print-run-summary $run_n $overall $duration_s

        # ── 3a. check gate after every run ────────────────────────────────────
        let gate_is_open = gate-open $results_dir $required_passes
        let consec       = count-consecutive-passes $results_dir

        if $gate_is_open {
            print ""
            print $"GATE OPEN after ($consec) consecutive passes — physical board testing unlocked"
            exit 0
        }

        # Build status string separately: Nu 0.111 can't nest (($a)/($b)) in $"..."
        let gate_status = $"($consec)/($required_passes) consecutive passes"
        print $"  gate: closed (($gate_status))"

        # ── 3b. gap between runs (skip after final iteration) ─────────────────
        if $run_n < $max_runs {
            print $"  sleeping ($gap_seconds)s before next run..."
            ^sleep ($gap_seconds | into string)
        }
    }

    # ── 4. loop exhausted without gate opening ─────────────────────────────────
    let consec_final = count-consecutive-passes $results_dir
    print ""
    print $"GATE CLOSED — ($consec_final) of ($required_passes) consecutive passes after ($max_runs) runs"
    exit 2
}
