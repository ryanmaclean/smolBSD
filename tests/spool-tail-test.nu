#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/spool-tail-test.nu — unit tests for bin/spool-tail.nu
#
# Run from repo root:
#   nu tests/spool-tail-test.nu
#
# This file matches the *-test.nu naming convention and is auto-discovered
# by tests/run-all.sh.  It exits 0 on all-pass, non-zero on any failure.

# ── Inline assert helpers ─────────────────────────────────────────────────────

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}

def assert [cond: bool, msg?: string] {
    if not $cond {
        error make {msg: ($msg | default "assert failed")}
    }
}

# ── Two-message fixture mbox ──────────────────────────────────────────────────

# Message A: outbound coordinator → architect, no verdict in TOML
const MSG_A = "From coordinator@smolbsd.local Mon May  4 10:00:00 2026
From: coordinator@smolbsd.local
To: architect@smolbsd.local
Subject: [task-st-1] Design the widget
Date: Mon, 4 May 2026 10:00:00 -0000
Message-ID: <task-st-1.coord@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-st-1\"
title   = \"Design the widget\"
"

# Message B: inbound architect → coordinator reply, verdict = pass
const MSG_B = "From architect@smolbsd.local Mon May  4 11:30:00 2026
From: architect@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-st-1] Design the widget
Date: Mon, 4 May 2026 11:30:00 -0000
Message-ID: <task-st-1.architect@smolbsd.local>
In-Reply-To: <task-st-1.coord@smolbsd.local>
Content-Type: text/toml; charset=utf-8

task_id = \"task-st-1\"
verdict = \"pass\"
"

# Write a fixture spool to a temp file and return the path.
def make-fixture-spool [] {
    let tmp = ^mktemp | str trim
    ($MSG_A + $MSG_B) | save --force $tmp
    $tmp
}

# ── Test: summary table (no flags) ───────────────────────────────────────────

print "test: summary table lists both messages"
do {
    let spool = make-fixture-spool

    let out = ^nu bin/spool-tail.nu --spool $spool | complete
    assert equal $out.exit_code 0

    # Summary output must mention addresses from both messages
    assert ($out.stdout | str contains "coordinator@smolbsd.local")
    assert ($out.stdout | str contains "architect@smolbsd.local")
    # Summary must include both row indices (0 and 1)
    assert ($out.stdout | str contains "0")
    assert ($out.stdout | str contains "1")

    rm $spool
}

# ── Test: --last 1 shows only the second message ─────────────────────────────

print "test: --last 1 shows last message only"
do {
    let spool = make-fixture-spool

    let out = ^nu bin/spool-tail.nu --spool $spool --last 1 | complete
    assert equal $out.exit_code 0

    # Must include msg B's Message-ID and from address
    assert ($out.stdout | str contains "task-st-1.architect@smolbsd.local")
    assert ($out.stdout | str contains "architect@smolbsd.local")
    # Must show only one message separator (only msg B, not msg A)
    let separators = $out.stdout | lines | where {|l| $l | str starts-with "━━━ Message #"}
    assert equal ($separators | length) 1
    # TOML body should be pretty-printed
    assert ($out.stdout | str contains "TOML body")

    rm $spool
}

# ── Test: --id substring match ────────────────────────────────────────────────

print "test: --id shows matched message by substring"
do {
    let spool = make-fixture-spool

    # Match msg A by a substring of its Message-ID
    let out = ^nu bin/spool-tail.nu --spool $spool --id "task-st-1.coord" | complete
    assert equal $out.exit_code 0

    # Must show msg A — its from_line and Message-ID
    assert ($out.stdout | str contains "coordinator@smolbsd.local")
    # Must show only one message separator (only msg A)
    let seps_id = $out.stdout | lines | where {|l| $l | str starts-with "━━━ Message #"}
    assert equal ($seps_id | length) 1

    rm $spool
}

# ── Test: --id no match ───────────────────────────────────────────────────────

print "test: --id no match prints informative message"
do {
    let spool = make-fixture-spool

    let out = ^nu bin/spool-tail.nu --spool $spool --id "nonexistent-xyz" | complete
    assert equal $out.exit_code 0
    assert ($out.stdout | str contains "no message found")

    rm $spool
}

# ── Test: --task filter ───────────────────────────────────────────────────────

print "test: --task filters by TOML task_id"
do {
    let spool = make-fixture-spool

    let out = ^nu bin/spool-tail.nu --spool $spool --task "task-st-1" | complete
    assert equal $out.exit_code 0

    # Both messages carry task_id = "task-st-1", so both should appear
    assert ($out.stdout | str contains "task-st-1.coord@smolbsd.local")
    assert ($out.stdout | str contains "task-st-1.architect@smolbsd.local")

    rm $spool
}

# ── Test: --task no match ─────────────────────────────────────────────────────

print "test: --task no match prints informative message"
do {
    let spool = make-fixture-spool

    let out = ^nu bin/spool-tail.nu --spool $spool --task "task-nonexistent" | complete
    assert equal $out.exit_code 0
    assert ($out.stdout | str contains "no messages found")

    rm $spool
}

# ── Test: empty spool ─────────────────────────────────────────────────────────

print "test: empty spool prints informative message"
do {
    let tmp = ^mktemp | str trim
    "" | save --force $tmp

    let out = ^nu bin/spool-tail.nu --spool $tmp | complete
    assert equal $out.exit_code 0
    assert ($out.stdout | str contains "empty")

    rm $tmp
}

# ── Test: malformed TOML body does not crash ──────────────────────────────────

print "test: malformed TOML body is handled gracefully"
do {
    let bad_msg = "From agent@smolbsd.local Mon May  4 10:00:00 2026
From: agent@smolbsd.local
To: coordinator@smolbsd.local
Subject: malformed
Date: Mon, 4 May 2026 10:00:00 -0000
Message-ID: <bad-toml@smolbsd.local>
Content-Type: text/toml; charset=utf-8

NOT VALID TOML @@@@ ===
"
    let tmp = ^mktemp | str trim
    $bad_msg | save --force $tmp

    # Summary mode should work (verdict column shows "(malformed)")
    let out_summary = ^nu bin/spool-tail.nu --spool $tmp | complete
    assert equal $out_summary.exit_code 0
    assert ($out_summary.stdout | str contains "(malformed)")

    # --last 1 should show raw body + parse error annotation
    let out_full = ^nu bin/spool-tail.nu --spool $tmp --last 1 | complete
    assert equal $out_full.exit_code 0
    assert ($out_full.stdout | str contains "TOML parse error")

    rm $tmp
}

print "\nall spool-tail tests passed"
