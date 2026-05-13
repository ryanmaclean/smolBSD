#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# ci-gate.nu — enforce the "3 consecutive clean runs" policy from task-0027.
#
# Reads *.toml result files written by bin/run-vm-tests.nu from --results-dir,
# counts consecutive trailing passes (most-recent-first by filename sort), and
# reports whether the Phase-III physical-board gate is open or closed.
#
# Usage:
#   nu bin/ci-gate.nu
#   nu bin/ci-gate.nu --results-dir /tmp/smolbsd-results
#   nu bin/ci-gate.nu --results-dir /tmp/smolbsd-results --required 3
#   nu bin/ci-gate.nu --run --image smolbsd-amd64.raw --tpm
#   nu bin/ci-gate.nu --run --image smolbsd-amd64.raw --results-dir /tmp/r
#
# Exit codes:
#   0  gate=open  (>= required consecutive passes)
#   1  unexpected error
#   2  gate=closed (< required consecutive passes)
#
# Result file format (produced by bin/run-vm-tests.nu):
#   overall = "pass" | "fail"   (top-level TOML key; other keys ignored)
#
# Files are sorted lexicographically by filename (run-vm-tests.nu names them
# with ISO-8601 timestamps so lexicographic = chronological).

const REQUIRED_DEFAULT = 3

# ── helpers ───────────────────────────────────────────────────────────────────

# Read a single result file and return its overall field ("pass"|"fail"|"unknown").
def read-overall [path: string] {
    let raw = open --raw $path
    let parsed = $raw | from toml
    if "overall" in ($parsed | columns) {
        $parsed | get overall
    } else {
        "unknown"
    }
}

# Collect all *.toml paths from results-dir, sorted descending (newest first).
def collect-results [results_dir: string] {
    if not ($results_dir | path exists) {
        return []
    }
    # Use glob then ls to handle the path expansion correctly in Nushell
    let toml_files = glob $"($results_dir)/*.toml"
    if ($toml_files | length) == 0 {
        return []
    }
    $toml_files | sort --reverse
}

# Count consecutive leading "pass" entries in a list (most-recent-first).
def count-consecutive-passes [verdicts: list<string>] {
    mut count = 0
    for v in $verdicts {
        if $v == "pass" {
            $count = $count + 1
        } else {
            break
        }
    }
    $count
}

# Evaluate the gate and print the result record. Returns the gate record.
def evaluate-gate [results_dir: string, required: int] {
    let paths    = collect-results $results_dir
    let verdicts = $paths | each { |p| read-overall $p }
    let consec   = count-consecutive-passes $verdicts
    let gate     = if $consec >= $required { "open" } else { "closed" }

    let result = {
        consecutive_passes: $consec
        required:           $required
        gate:               $gate
        files_checked:      ($paths | length)
    }
    $result | to nuon | print
    $result
}

# ── main ──────────────────────────────────────────────────────────────────────

def main [
    --results-dir: string = "/tmp/smolbsd-results",  # dir holding *.toml result files
    --required: int = 3,                              # consecutive passes needed for gate=open
    --run,                                            # invoke run-vm-tests.nu first, then re-evaluate
    # pass-through flags for run-vm-tests.nu (only used with --run):
    --image: string = "",       # --image path forwarded to run-vm-tests.nu
    --tpm,                      # --tpm flag forwarded to run-vm-tests.nu
    --skip: list<string> = [],  # --skip list forwarded to run-vm-tests.nu
] {
    # ── Optional: run the test suite first ────────────────────────────────────
    if $run {
        if ($image | str length) == 0 {
            error make {msg: "--run requires --image <path>"}
        }

        # Ensure results dir exists
        if not ($results_dir | path exists) {
            mkdir $results_dir
        }

        # Timestamp-named output file (lexicographic = chronological)
        let ts_file = $"($results_dir)/run-(date now | format date '%Y%m%dT%H%M%SZ').toml"

        # Build arg list for run-vm-tests.nu
        let run_args = (
            ["--image" $image "--results-file" $ts_file]
            | append (if $tpm { ["--tpm"] } else { [] })
            | append (if ($skip | length) > 0 { ["--skip" ($skip | to nuon)] } else { [] })
        )

        print $"ci-gate: invoking run-vm-tests.nu -> ($ts_file)"
        let r = ^nu --no-config-file bin/run-vm-tests.nu ...$run_args | complete
        if $r.exit_code != 0 {
            # run-vm-tests exits 1 on test failure — that is expected and not a
            # gate error; only propagate non-zero if the TOML file wasn't written.
            if not ($ts_file | path exists) {
                error make {msg: $"run-vm-tests.nu failed to produce ($ts_file): ($r.stderr | str trim)"}
            }
        }
        print $"ci-gate: run complete — result written to ($ts_file)"
    }

    # ── Evaluate gate ─────────────────────────────────────────────────────────
    let result = evaluate-gate $results_dir $required

    if $result.gate == "open" {
        exit 0
    } else {
        exit 2
    }
}
