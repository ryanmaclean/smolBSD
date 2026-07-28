#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/sizereport-test.nu — unit tests for bin/sizereport.nu
#
# Runs the parser against tests/fixtures/sizereport-sample.log and checks
# ranking, section extraction, and both failure modes (absent log, log
# without SIZEREPORT lines). Run from the repo root: nu tests/sizereport-test.nu

def fail [msg: string] {
    print $"sizereport-test: FAIL — ($msg)"
    exit 1
}

# Happy path: fixture parses, sections land in the right order and rank.
let res = (^$nu.current-exe bin/sizereport.nu tests/fixtures/sizereport-sample.log | complete)
if $res.exit_code != 0 { fail $"parser exited ($res.exit_code): ($res.stderr)" }
if not ($res.stdout =~ 'rootfs total: 402 MiB') { fail "rootfs total missing or wrong" }
if not ($res.stdout =~ 'FreeBSD-utilities') { fail "package table missing FreeBSD-utilities" }
# 50331648 bytes = 48.0 MiB — \b keeps the raw byte count (…648, which
# ends in "48") from satisfying the check if the conversion is dropped.
if not ($res.stdout =~ '\b48\b') { fail "package size not converted to MiB" }
if ($res.stdout =~ '50331648') { fail "package size printed in raw bytes" }
if not ($res.stdout =~ 'boot/kernel/kernel') { fail "largest-files table missing kernel" }
# Ranking: the 210 MiB usr row must precede the 88 MiB boot row. Assert on
# the unique size tokens — path prefixes ('/mnt/vm-root/usr') also match
# their subdirectory rows, which made a position check on them vacuous.
if not ($res.stdout =~ '(?s)\b210\b.*\b88\b') { fail "directory table not sorted largest-first" }

# --top limits rows: with --top 1 the 55 MiB usr/bin row must not appear.
let top1 = (^$nu.current-exe bin/sizereport.nu tests/fixtures/sizereport-sample.log --top 1 | complete)
if $top1.exit_code != 0 { fail $"--top 1 exited ($top1.exit_code)" }
if ($top1.stdout =~ 'usr/bin') { fail "--top 1 did not limit directory rows" }

# Absent log: SKIP, exit 0 (build logs are optional artifacts).
let absent = (^$nu.current-exe bin/sizereport.nu /nonexistent-build.log | complete)
if $absent.exit_code != 0 { fail "absent log should exit 0 with SKIP" }
if not ($absent.stdout =~ 'SKIP') { fail "absent log did not print SKIP" }

# Log without SIZEREPORT lines: exit 1 (build predates instrumentation).
let plain = (^$nu.current-exe bin/sizereport.nu tests/fixtures/spool-clean.mbox | complete)
if $plain.exit_code != 1 { fail $"uninstrumented log should exit 1, got ($plain.exit_code)" }

print "sizereport-test: ok"
