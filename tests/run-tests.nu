#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/run-tests.nu — smolBSD test suite runner
#
# Usage:
#   nu tests/run-tests.nu                    # run all tests
#   nu tests/run-tests.nu --suite unit       # unit tests only
#   nu tests/run-tests.nu --suite e2e        # e2e (QEMU boot) tests only
#   nu tests/run-tests.nu --arch aarch64     # e2e for aarch64 only

use ../bin/mbox-parse.nu [parse-mbox, extract-toml, msg-id]
use coord-fsm-tests.nu [run-coord-fsm-tests]

# Minimal two-message mbox fixture used by unit tests.
const FIXTURE_MBOX = "From agent1 Mon May  4 10:00:00 2026
From: agent1@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-unit-1] fixture message one
Date: Mon, 4 May 2026 10:00:00 -0000
Message-ID: <unit-1.agent1@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"unit-1\"
verdict  = \"pass\"

[meta]
detail = \"first fixture message\"

From agent2 Mon May  4 10:00:01 2026
From: agent2@smolbsd.local
To: coordinator@smolbsd.local
Subject: [task-unit-2] fixture message two
Date: Mon, 4 May 2026 10:00:01 -0000
Message-ID: <unit-2.agent2@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"unit-2\"
verdict  = \"pass\"

[meta]
detail = \"second fixture message\"
"

# Run all unit tests against bin/mbox-parse.nu.
# Returns a list of {name, status, detail} records.
def run-unit-tests [] {
    mut results = []

    # --- Test 1: parse-mbox returns exactly 2 records ---
    let t1 = try {
        let msgs = parse-mbox $FIXTURE_MBOX
        let count = $msgs | length
        if $count == 2 {
            {name: "parse-mbox: message count", status: "pass", detail: $"got ($count) messages"}
        } else {
            {name: "parse-mbox: message count", status: "fail", detail: $"expected 2, got ($count)"}
        }
    } catch {|err|
        {name: "parse-mbox: message count", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t1

    # --- Test 2: msg-id extracts correct Message-ID from first message ---
    let t2 = try {
        let msgs = parse-mbox $FIXTURE_MBOX
        let first = $msgs | first
        let id = msg-id $first
        if $id == "<unit-1.agent1@smolbsd.local>" {
            {name: "msg-id: first message", status: "pass", detail: $"got ($id)"}
        } else {
            {name: "msg-id: first message", status: "fail", detail: $"expected <unit-1.agent1@smolbsd.local>, got ($id)"}
        }
    } catch {|err|
        {name: "msg-id: first message", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t2

    # --- Test 3: msg-id extracts correct Message-ID from second message ---
    let t3 = try {
        let msgs = parse-mbox $FIXTURE_MBOX
        let second = $msgs | last
        let id = msg-id $second
        if $id == "<unit-2.agent2@smolbsd.local>" {
            {name: "msg-id: second message", status: "pass", detail: $"got ($id)"}
        } else {
            {name: "msg-id: second message", status: "fail", detail: $"expected <unit-2.agent2@smolbsd.local>, got ($id)"}
        }
    } catch {|err|
        {name: "msg-id: second message", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t3

    # --- Test 4: extract-toml parses TOML body from first message ---
    let t4 = try {
        let msgs = parse-mbox $FIXTURE_MBOX
        let first = $msgs | first
        let parsed = extract-toml $first
        let ok = (
            ($parsed | get task_id? | default "") == "unit-1" and
            ($parsed | get verdict? | default "") == "pass" and
            ($parsed | get _parse_error? | default null | is-empty)
        )
        if $ok {
            {name: "extract-toml: first message body", status: "pass", detail: $"task_id=($parsed.task_id) verdict=($parsed.verdict)"}
        } else {
            {name: "extract-toml: first message body", status: "fail", detail: $"parsed: ($parsed | to nuon)"}
        }
    } catch {|err|
        {name: "extract-toml: first message body", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t4

    # --- Test 5: extract-toml nested table accessible ---
    let t5 = try {
        let msgs = parse-mbox $FIXTURE_MBOX
        let second = $msgs | last
        let parsed = extract-toml $second
        let detail_val = $parsed | get meta? | default {} | get detail? | default ""
        if $detail_val == "second fixture message" {
            {name: "extract-toml: nested TOML table", status: "pass", detail: $"meta.detail=($detail_val)"}
        } else {
            {name: "extract-toml: nested TOML table", status: "fail", detail: $"expected 'second fixture message', got '($detail_val)'"}
        }
    } catch {|err|
        {name: "extract-toml: nested TOML table", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t5

    # --- Test 6: extract-toml returns _parse_error on empty body ---
    let t6 = try {
        let fake_msg = {from_line: "From x Mon May 4 10:00:00 2026", headers: {}, body: ""}
        let parsed = extract-toml $fake_msg
        let has_err = ($parsed | get _parse_error? | default null | is-not-empty)
        if $has_err {
            {name: "extract-toml: empty body error", status: "pass", detail: $"_parse_error=($parsed._parse_error)"}
        } else {
            {name: "extract-toml: empty body error", status: "fail", detail: $"expected _parse_error key, got ($parsed | to nuon)"}
        }
    } catch {|err|
        {name: "extract-toml: empty body error", status: "fail", detail: $"exception: ($err.msg)"}
    }
    $results = $results | append $t6

    $results
}

# Run a single e2e test via expect(1).
# Returns a {name, status, detail} record.
def run-e2e-test [arch: string, script: string, qcow2: string] {
    let name = $"e2e-($arch)"

    if not ($qcow2 | path exists) {
        return {name: $name, status: "skip", detail: $"qcow2 not present: ($qcow2)"}
    }

    # Run the expect script; capture combined output.
    let result = try {
        ^expect $script | complete
    } catch {|err|
        return {name: $name, status: "fail", detail: $"failed to run expect: ($err.msg)"}
    }

    let output = $result.stdout
    let exit_code = $result.exit_code

    if $exit_code != 0 {
        let last_line = $output | lines | last | default "no output"
        return {name: $name, status: "fail", detail: $"expect exited ($exit_code): ($last_line)"}
    }

    # Parse TIME_TO_LOGIN=Ns from output.
    let match = $output | parse --regex "TIME_TO_LOGIN=(\\d+)s" | first | default null
    if $match == null {
        return {name: $name, status: "fail", detail: $"TIME_TO_LOGIN not found in output"}
    }

    let secs = $match.capture0 | into int
    if $secs <= 30 {
        {name: $name, status: "pass", detail: $"TIME_TO_LOGIN=($secs)s — gate: <=30s PASS"}
    } else {
        {name: $name, status: "fail", detail: $"TIME_TO_LOGIN=($secs)s — gate: <=30s FAIL"}
    }
}

def main [
    --suite: string = "all"   # all | unit | e2e
    --arch: string = "all"    # all | amd64 | aarch64
] {
    mut results = []

    # Unit tests
    if $suite == "all" or $suite == "unit" {
        $results = $results | append (run-unit-tests)
        $results = $results | append (run-coord-fsm-tests)
    }

    # E2E tests (require real qcow2 images)
    if $suite == "all" or $suite == "e2e" {
        if $arch == "all" or $arch == "amd64" {
            $results = $results | append (run-e2e-test "amd64" "tests/time-to-ready.exp" "build/FreeBSD-15-amd64-smolbsd.qcow2")
        }
        if $arch == "all" or $arch == "aarch64" {
            $results = $results | append (run-e2e-test "aarch64" "tests/time-to-ready-arm64.exp" "build/FreeBSD-15-aarch64-smolbsd.qcow2")
        }
    }

    # Summary
    let passed  = $results | where status == "pass" | length
    let failed  = $results | where status == "fail" | length
    let skipped = $results | where status == "skip" | length

    print $"\n=== Test Results: ($passed) pass / ($failed) fail / ($skipped) skip ==="
    $results | each {|r|
        let s = $r.status
        print $"  [($s)] ($r.name): ($r.detail)"
    }

    if $failed > 0 { exit 1 }
}
