#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# smolbsd-test-report.nu — formatted summary of all TOML result files in a results dir.
#
# Reads every *.toml file written by bin/run-vm-tests.nu from --results-dir,
# then prints:
#   1. A per-run summary table  (run#, timestamp, overall, pass/fail counts, duration)
#   2. A per-step breakdown table for each run (name, result, duration_ms, detail)
#
# Usage:
#   nu tests/smolbsd-test-report.nu
#   nu tests/smolbsd-test-report.nu --results-dir /tmp/smolbsd-results
#   nu tests/smolbsd-test-report.nu --results-dir /tmp/r --summary-only
#   nu tests/smolbsd-test-report.nu --results-dir /tmp/r --run 3   # single run detail
#   nu tests/smolbsd-test-report.nu --results-dir /tmp/r --json    # machine-readable output
#
# Exit codes:
#   0  at least one result file found and parsed
#   1  no result files found or results-dir does not exist

const COL_STEP    = 20
const COL_RESULT  = 7
const COL_DETAIL  = 52

# ── TOML loading ──────────────────────────────────────────────────────────────

# Load and validate a single result file. Returns a record or null on error.
def load-result [path: string] {
    let raw = open --raw $path
    let parsed = $raw | from toml
    let cols = $parsed | columns
    # Require the fields we rely on; skip files that look like coord dispatches etc.
    if not ("overall" in $cols) or not ("tests" in $cols) {
        return null
    }
    $parsed
}

# Compute total wall-clock duration across all steps (sum of duration_ms).
def total-duration-ms [tests: list<any>] {
    $tests | each { get duration_ms } | math sum
}

# Summarise a tests list as {pass, fail, skip, error} counts.
def step-counts [tests: list<any>] {
    {
        pass:  ($tests | where result == "pass"  | length)
        fail:  ($tests | where result == "fail"  | length)
        skip:  ($tests | where result == "skip"  | length)
        error: ($tests | where result == "error" | length)
    }
}

# ── Formatters ────────────────────────────────────────────────────────────────

# Pad / truncate a string to exactly `w` chars.
def pad [w: int] {
    let s = $in | into string
    if ($s | str length) >= $w {
        $s | str substring 0..($w - 1)
    } else {
        $s | fill -w $w -a l
    }
}

# Right-pad an integer to `w` chars.
def pad-int [w: int] {
    $in | into string | fill -w $w -a r
}

# Emoji badge for a result string.
def badge [result: string] {
    match $result {
        "pass"  => "✓ pass "
        "fail"  => "✗ fail "
        "skip"  => "- skip "
        "error" => "! error"
        _       => "? unk  "
    }
}

# Overall badge (wider).
def overall-badge [overall: string] {
    match $overall {
        "pass" => "PASS ✓"
        "fail" => "FAIL ✗"
        _      => "?    "
    }
}

# ── Printers ──────────────────────────────────────────────────────────────────

# Print the per-run summary table header.
def print-summary-header [] {
    print $"#    Timestamp             Overall   Pass Fail Skip  Duration"
    print $"─────────────────────────────────────────────────────────────"
}

# Print one row of the summary table.
def print-summary-row [n: int, r: record] {
    let counts  = step-counts $r.tests
    let dur_s   = (total-duration-ms $r.tests) / 1000
    let ts      = $r.timestamp? | default "unknown"
    let overall = overall-badge ($r.overall? | default "?")
    print (
        $"($n | pad-int 4) ($ts | pad 22) ($overall | pad 10)"
        + $" ($counts.pass | pad-int 4) ($counts.fail | pad-int 4) ($counts.skip | pad-int 4)"
        + $"  ($dur_s | math round --precision 1)s"
    )
}

# Print the step breakdown for one run.
def print-step-table [n: int, r: record] {
    let ts      = $r.timestamp? | default "unknown"
    let overall = overall-badge ($r.overall? | default "?")
    print ""
    print $"── Run ($n) — ($ts) — ($overall) ─────────────────────────────────────────"
    print $"  image:   ($r.image? | default 'unknown')"
    print $"  vm_name: ($r.vm_name? | default 'unknown')"
    print ""
    let sep_step   = "" | fill -w $COL_STEP   -c "─"
    let sep_result = "" | fill -w $COL_RESULT -c "─"
    let sep_detail = "" | fill -w 40          -c "─"
    print $"  ($'Step' | pad $COL_STEP) ($'Result' | pad $COL_RESULT)  ms      Detail"
    print $"  ($sep_step) ($sep_result)  ──────  ($sep_detail)"
    for step in $r.tests {
        let name   = $step.name?       | default "?" | pad $COL_STEP
        let res    = badge ($step.result? | default "?")
        let dur    = $step.duration_ms? | default 0  | pad-int 6
        let detail = $step.detail?     | default ""  | str replace --all "\n" " " | pad $COL_DETAIL
        print $"  ($name) ($res)  ($dur)  ($detail)"
    }
}

# ── main ──────────────────────────────────────────────────────────────────────

def main [
    --results-dir: string = "/tmp/smolbsd-results",  # directory containing *.toml result files
    --summary-only,                                   # print only the summary table, no step detail
    --run: int = 0,                                   # print detail for run N only (0 = all)
    --json,                                           # emit JSON instead of formatted text
] {
    # ── Collect and sort result files (oldest first for run numbering) ────────
    if not ($results_dir | path exists) {
        print $"No results directory: ($results_dir)"
        exit 1
    }

    let files = glob $"($results_dir)/*.toml" | sort
    if ($files | length) == 0 {
        print $"No *.toml result files found in ($results_dir)"
        exit 1
    }

    # ── Load results ──────────────────────────────────────────────────────────
    let loaded = $files | enumerate | each { |entry|
        let r = load-result $entry.item
        if $r == null { null } else {
            $r | insert _run_n ($entry.index + 1) | insert _file $entry.item
        }
    } | compact  # drop nulls (non-result TOML files)

    if ($loaded | length) == 0 {
        print "No valid run-vm-tests result files found (missing 'overall' or 'tests' keys)"
        exit 1
    }

    # ── JSON output ───────────────────────────────────────────────────────────
    if $json {
        $loaded | to json | print
        return
    }

    # ── Summary table ─────────────────────────────────────────────────────────
    let total      = $loaded | length
    let pass_runs  = $loaded | where overall == "pass" | length
    let fail_runs  = $loaded | where overall == "fail" | length

    print $"smolBSD VM Test Report — ($results_dir)"
    print $"($total) runs - ($pass_runs) passed - ($fail_runs) failed"
    print ""
    print-summary-header
    for r in $loaded {
        print-summary-row $r._run_n $r
    }
    print ""

    # ── Consecutive-pass tail (CI gate status) ────────────────────────────────
    let verdicts = $loaded | get overall
    mut consec = 0
    for v in ($verdicts | reverse) {
        if $v == "pass" { $consec = $consec + 1 } else { break }
    }
    let gate_symbol = if $consec >= 3 { "OPEN  ✓" } else { "CLOSED ✗" }
    let gate_line = "CI gate [>=3 consecutive passes]: " + $gate_symbol + "  [" + ($consec | into string) + " trailing passes]"
    print $gate_line

    # ── Per-run step detail ───────────────────────────────────────────────────
    if not $summary_only {
        let to_detail = if $run > 0 {
            $loaded | where _run_n == $run
        } else {
            $loaded
        }
        if ($to_detail | length) == 0 and $run > 0 {
            print $"\nRun ($run) not found — only ($total) runs in results dir"
        } else {
            for r in $to_detail {
                print-step-table $r._run_n $r
            }
        }
        print ""
    }
}
