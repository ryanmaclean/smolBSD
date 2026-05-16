# SPDX-License-Identifier: Apache-2.0
# coord-dispatch-test.nu — regression tests for read-dispatch-log and
#                           SMOLBSD_CLAUDE_MODEL env-var pattern
#
# Run from repo root:
#   nu tests/coord-dispatch-test.nu

use ../bin/coord-dispatch.nu [read-dispatch-log]

# ── Inline assert helpers ─────────────────────────────────────────────────────

def "assert equal" [left: any, right: any, label: string = ""] {
    if $left != $right {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert equal failed($ctx)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        error make {msg: $"assert failed($ctx)"}
    }
}

# ── Test 1: read-dispatch-log with valid JSON (result field) ──────────────────
print "test 1: read-dispatch-log extracts 'result' field from JSON log"

let tmp1 = ^mktemp -t dispatch-log-test.XXXXXX | str trim
'{"result": "the agent response text", "cost": 0.001}' | save -f $tmp1
let out1 = read-dispatch-log $tmp1
assert equal $out1 "the agent response text" "result field extracted"
rm $tmp1

print "  PASS"

# ── Test 2: read-dispatch-log with content field (alternate JSON shape) ───────
print "test 2: read-dispatch-log falls back to 'content' field from JSON log"

let tmp2 = ^mktemp -t dispatch-log-test.XXXXXX | str trim
'{"content": "alternate field", "model": "claude-sonnet-4-6"}' | save -f $tmp2
let out2 = read-dispatch-log $tmp2
assert equal $out2 "alternate field" "content field extracted"
rm $tmp2

print "  PASS"

# ── Test 3: read-dispatch-log with non-JSON (raw text log) ───────────────────
print "test 3: read-dispatch-log returns raw text for non-JSON log"

let tmp3 = ^mktemp -t dispatch-log-test.XXXXXX | str trim
"plain text output from old invocation" | save -f $tmp3
let out3 = read-dispatch-log $tmp3
assert equal $out3 "plain text output from old invocation" "raw text returned"
rm $tmp3

print "  PASS"

# ── Test 4: read-dispatch-log with missing file ───────────────────────────────
print "test 4: read-dispatch-log returns empty string for missing file"

let out4 = read-dispatch-log "/nonexistent/path/log.txt"
assert equal $out4 "" "empty string for missing file"

print "  PASS"

# ── Test 5: SMOLBSD_CLAUDE_MODEL env var pattern works ───────────────────────
print "test 5: SMOLBSD_CLAUDE_MODEL env var is used when set, defaulting to claude-sonnet-4-6"

with-env {SMOLBSD_CLAUDE_MODEL: "claude-opus-4-7"} {
    let model = $env | get SMOLBSD_CLAUDE_MODEL? | default "claude-sonnet-4-6"
    assert equal $model "claude-opus-4-7" "env var override respected"
}

let model_default = $env | get SMOLBSD_CLAUDE_MODEL? | default "claude-sonnet-4-6"
assert equal $model_default "claude-sonnet-4-6" "default model when env var absent"

print "  PASS"

# ── Done ──────────────────────────────────────────────────────────────────────
print ""
print "All coord-dispatch tests passed."
