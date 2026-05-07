# SPDX-License-Identifier: Apache-2.0
# mbox-parse-test.nu — unit tests for bin/mbox-parse.nu
#
# Run from repo root:
#   nu tests/mbox-parse-test.nu

use ../bin/mbox-parse.nu [parse-mbox, extract-toml, msg-id]

# Inline assert helpers — avoids std library version sensitivity.
def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool] {
    if not $cond { error make {msg: "assert failed"} }
}

# ---------------------------------------------------------------------------
# Test: single message — structural shape check
# ---------------------------------------------------------------------------
print "test: single message"
let single_mbox = "From a@b Mon Jan  1 00:00:00 2026
From: sender@example.com
Message-ID: <unique.id.1@host>
Content-Type: text/toml; charset=utf-8

key = \"hello\""

let msgs = parse-mbox $single_mbox
assert equal ($msgs | length) 1
let m = $msgs | first
assert (($m.from_line | str length) > 0)
assert equal ($m | get headers | describe | str starts-with "record") true
assert equal ($m.body | describe) "string"

# ---------------------------------------------------------------------------
# Test: header keys no colon — fix regression guard
# ---------------------------------------------------------------------------
print "test: header keys no colon"
let hdr_mbox = "From sender@example.com Mon Jan  1 00:00:00 2026
Message-ID: <test.id@host>
Content-Type: text/toml

body = true"

let hdr_msgs = parse-mbox $hdr_mbox
let hdr_m = $hdr_msgs | first
# The key must be exactly "Message-ID" — not "Message-ID:"
assert equal ($hdr_m.headers | get "Message-ID") "<test.id@host>"
# Verify the record does NOT contain a colon-suffixed key
let has_colon_key = ($hdr_m.headers | columns | any {|k| $k | str ends-with ":"})
assert equal $has_colon_key false

# ---------------------------------------------------------------------------
# Test: multi-message split
# ---------------------------------------------------------------------------
print "test: multi-message split"
let multi_mbox = "From a@b Mon Jan  1 00:00:00 2026
Message-ID: <msg.one@host>
Content-Type: text/toml

val = 1
From c@d Mon Jan  2 00:00:00 2026
Message-ID: <msg.two@host>
Content-Type: text/toml

val = 2"

let multi_msgs = parse-mbox $multi_mbox
assert equal ($multi_msgs | length) 2
assert equal ($multi_msgs | get 0 | msg-id) "<msg.one@host>"
assert equal ($multi_msgs | get 1 | msg-id) "<msg.two@host>"

# ---------------------------------------------------------------------------
# Test: msg-id helper
# ---------------------------------------------------------------------------
print "test: msg-id helper"
let id_mbox = "From x@y Mon Jan  1 00:00:00 2026
Message-ID: <hello.world@example.com>
Content-Type: text/toml

x = 1"

let id_msgs = parse-mbox $id_mbox
let id_m = $id_msgs | first
assert equal (msg-id $id_m) "<hello.world@example.com>"

# msg-id returns "" when absent
let no_id_mbox = "From x@y Mon Jan  1 00:00:00 2026
Content-Type: text/toml

x = 1"

let no_id_msgs = parse-mbox $no_id_mbox
let no_id_m = $no_id_msgs | first
assert equal (msg-id $no_id_m) ""

# ---------------------------------------------------------------------------
# Test: extract-toml ok
# ---------------------------------------------------------------------------
print "test: extract-toml ok"
let toml_mbox = "From x@y Mon Jan  1 00:00:00 2026
Message-ID: <toml.ok@host>
Content-Type: text/toml; charset=utf-8

key = \"value\""

let toml_msgs = parse-mbox $toml_mbox
let toml_m = $toml_msgs | first
let toml_result = extract-toml $toml_m
assert equal ($toml_result | get key) "value"

# ---------------------------------------------------------------------------
# Test: extract-toml error
# ---------------------------------------------------------------------------
print "test: extract-toml error"
let bad_toml_mbox = "From x@y Mon Jan  1 00:00:00 2026
Message-ID: <toml.bad@host>
Content-Type: text/toml

not valid toml !!! @@"

let bad_msgs = parse-mbox $bad_toml_mbox
let bad_m = $bad_msgs | first
let bad_result = extract-toml $bad_m
assert (($bad_result | get _parse_error?) != null)

# ---------------------------------------------------------------------------
# Test: folded header (continuation line)
# ---------------------------------------------------------------------------
print "test: folded header"
let folded_mbox = "From x@y Mon Jan  1 00:00:00 2026
Subject: This is a long
 subject that continues
Message-ID: <folded@host>
Content-Type: text/toml

x = 1"

let folded_msgs = parse-mbox $folded_mbox
let folded_m = $folded_msgs | first
let subject_val = $folded_m.headers | get "Subject"
# The folded continuation must be joined — no literal newline in the value
assert equal ($subject_val | str contains "\n") false
# The continuation content should be present in the joined value
assert ($subject_val | str length | $in > 0)

# ---------------------------------------------------------------------------
# Test: seen_ids guard — msg-id is stable across duplicate Message-IDs
# ---------------------------------------------------------------------------
print "test: seen_ids guard"
let dup_id_mbox = "From a@b Mon Jan  1 00:00:00 2026
Message-ID: <dup.id@host>
Content-Type: text/toml

x = 1
From c@d Mon Jan  2 00:00:00 2026
Message-ID: <dup.id@host>
Content-Type: text/toml

x = 2"

let dup_msgs = parse-mbox $dup_id_mbox
assert equal ($dup_msgs | length) 2
let id_first  = msg-id ($dup_msgs | get 0)
let id_second = msg-id ($dup_msgs | get 1)
# Both messages share the same Message-ID value — msg-id must return it stably
assert equal $id_first "<dup.id@host>"
assert equal $id_second "<dup.id@host>"
assert equal $id_first $id_second

print "all tests passed"
