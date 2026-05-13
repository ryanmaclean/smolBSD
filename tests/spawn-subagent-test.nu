# SPDX-License-Identifier: Apache-2.0
# spawn-subagent-test.nu — verifies that bin/coord-tick.nu auto-spawns the
# `claude` CLI on a dispatch transition. A stub `claude` script on PATH
# captures invocation args to a file so the test can assert on them.

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool] {
    if not $cond { error make {msg: "assert failed"} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

def make-msg [from_addr: string, to_addr: string, message_id: string, body: string] {
    ([
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}

print "test: dispatch tick auto-spawns the claude CLI"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Build a stub `claude` on PATH that records argv to a marker file.
    let stub_dir   = [$tmp, "stub-bin"] | path join
    let marker     = [$tmp, "claude-invoked.txt"] | path join
    mkdir $stub_dir
    let stub_path = [$stub_dir, "claude"] | path join
    let stub_body = $"#!/bin/sh
echo \"INVOKED $#\" >> ($marker)
for a in \"$@\"; do echo \"ARG: $a\" >> ($marker); done
exit 0
"
    $stub_body | save --force $stub_path
    ^chmod +x $stub_path

    # Seed an outbound request — this triggers idle → harvesting → dispatching.
    # Recipient local-part `builder` so derived agent_type = "builder".
    let body = "task_id = \"t-spawn\"\ncommand = \"echo hello\""
    let msg = make-msg "coordinator@smolbsd.local" "builder@smolbsd.local" "<req.spawn.001@host>" $body
    write-spool $spool_abs $msg

    # Run tick with the stub dir prepended to PATH.
    with-env { PATH: ($env.PATH | prepend $stub_dir) } {
        ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp | ignore
    }

    # Poll up to 5s for the marker file (replaces fixed sleep 500ms).
    let deadline = 10  # 10 × 500ms = 5s
    mut found = false
    for _ in 1..$deadline {
        if ($marker | path exists) { $found = true; break }
        sleep 500ms
    }
    assert $found  # marker file not created within 5s

    # Assertions.
    assert ($marker | path exists)
    let recorded = open --raw $marker
    # Stub must have been invoked.
    assert ($recorded | str contains "INVOKED ")
    # The model flag and `-p` flag must have been passed.
    assert ($recorded | str contains "--model")
    assert ($recorded | str contains "claude-sonnet-4-6")
    assert ($recorded | str contains "-p")
    # Prompt content must reference the task_id.
    assert ($recorded | str contains "t-spawn")

    # Spawn artifacts must have been written.
    let prompt_file = [$tmp, "var", "run", "spawned", "t-spawn.prompt.txt"] | path join
    assert ($prompt_file | path exists)
    let prompt_text = open --raw $prompt_file
    assert ($prompt_text | str contains "builder")
    assert ($prompt_text | str contains "t-spawn")

    ^rm -rf $tmp
}

print "test: missing claude CLI logs subagent_spawn_skipped, does not fail"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # PATH must keep `nu` reachable (for the spawned coord-tick.nu interpreter)
    # but must NOT contain `claude`. Build it by filtering claude out of the
    # current PATH and prepending an empty stub dir so we can be sure.
    let empty_dir = [$tmp, "no-claude-bin"] | path join
    mkdir $empty_dir
    let filtered = (
        $env.PATH
        | where {|p| not ($p | str contains "claude")}
    )
    let safe_path = ($filtered | prepend $empty_dir)

    let body = "task_id = \"t-no-claude\""
    let msg = make-msg "coordinator@smolbsd.local" "builder@smolbsd.local" "<req.no-claude.001@host>" $body
    write-spool $spool_abs $msg

    # Confirm precondition: claude is NOT on the safe_path. If it is, skip this test.
    let claude_present_on_safe_path = (
        $safe_path | any {|d| ([$d, "claude"] | path join | path exists) }
    )
    if $claude_present_on_safe_path {
        print "  (skipped: claude binary still present after filtering)"
        ^rm -rf $tmp
        return
    }

    let log_file = [$tmp, "tick.log"] | path join
    let exit_code = try {
        with-env { PATH: $safe_path } {
            ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp out> $log_file
        }
        0
    } catch { 1 }

    assert equal $exit_code 0
    let log_text = open --raw $log_file
    assert ($log_text | str contains "subagent_spawn_skipped")
    assert ($log_text | str contains "claude CLI not installed")

    ^rm -rf $tmp
}

print "all tests passed"
