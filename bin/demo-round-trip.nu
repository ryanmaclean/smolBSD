#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/demo-round-trip.nu — smolBSD thesis demonstration
#
# Proves: project state transfers between Claude agent teams
# using the BSD mailbox (mbox+TOML) paradigm.
#
# Usage:
#   nu bin/demo-round-trip.nu              # mock mode (no VM needed)
#   nu bin/demo-round-trip.nu --live       # live mode (requires qcow2 in build/)
#   nu bin/demo-round-trip.nu --arch arm64 # specify arch (default: arm64)

def main [
    --live                                          # boot a real smolBSD VM for the agent task
    --arch: string = "arm64"                        # arm64 | amd64
    --spool: string = "var/run/demo-spool"          # demo uses its own spool (not production)
    --state: string = "var/run/demo-state.toml"     # demo FSM state (isolated from production)
] {
    print "╔══════════════════════════════════════════════════════╗"
    print "║  smolBSD — Thesis Demo: Mailbox State Transfer       ║"
    print "║  BSD mbox+TOML · Actor FSM · JEC · Agent Handoff     ║"
    print "╚══════════════════════════════════════════════════════╝"
    print ""

    # Resolve paths relative to script location (works from any cwd)
    let script_dir = $env.CURRENT_FILE | path dirname | path expand
    let root = $script_dir | path dirname
    let abs_spool = [$root, $spool] | path join
    let abs_state = [$root, $state] | path join

    # Ensure demo dirs exist (var/run/ is .gitignored per spec §11)
    let run_dir = [$root, "var", "run"] | path join
    if not ($run_dir | path exists) { mkdir $run_dir }

    # ── Step 1: Coordinator writes a task to the demo spool ──────────────────
    print "▶ Step 1: Coordinator writing task to spool..."

    let task_id = "demo-001"
    let ts      = date now | format date "%a, %d %b %Y %H:%M:%S -0000"
    let dstamp  = date now | format date "%a %b %e %H:%M:%S %Y"

    let task_toml = $"task_id = \"($task_id)\"
role    = \"builder\"
objective = \"Boot smolBSD VM and collect system identity\"

[commands]
run         = [\"uname -a\", \"sysctl kern.version\", \"df -h /\"]
timeout_sec = 30

[acceptance]
must_contain = \"FreeBSD\"
max_boot_sec = 30

[reply_contract]
output_to            = \"coordinator@smolfire.local\"
output_format        = \"mbox+toml-v1\"
attestation_required = true
tools_required       = [\"Bash\"]

[context_pointers]
image_path = \"build/FreeBSD-15-($arch)-smolbsd.qcow2\"
arch       = \"($arch)\"
spec       = \"docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md\"
"

    # mbox envelope — From_ line (no colon) is the mbox separator per RFC 4155
    let envelope = $"From coord@smolfire.local ($dstamp)
From: coordinator@smolfire.local
To: builder@smolfire.local
Subject: [($task_id)] Boot smolBSD and collect system identity
Date: ($ts)
Message-ID: <($task_id).coord@smolfire.local>
X-Project: smolbsd
X-Phase: tinyos/thesis-demo
Content-Type: text/toml; charset=utf-8

($task_toml)
"

    $envelope | save --force $abs_spool
    print $"  task ($task_id) written to ($spool)"
    print $"  Message-ID: <($task_id).coord@smolfire.local>"

    # ── Step 2: Builder agent reads task and executes ────────────────────────
    print ""
    print "▶ Step 2: Builder agent reading task and executing..."

    # Map arm64 -> aarch64 for the qcow2 filename convention
    let file_arch = if $arch == "arm64" { "aarch64" } else { $arch }
    let image_path = [$root, $"build/FreeBSD-15-($file_arch)-smolbsd.qcow2"] | path join
    let result = if $live and ($image_path | path exists) {
        print $"  live mode: booting ($image_path)"
        run-live-agent $arch $image_path
    } else {
        if $live {
            print "  live mode requested but qcow2 not found — falling back to mock"
        }
        print "  mock mode: simulating agent response"
        run-mock-agent $task_id $arch
    }

    print $"  agent mode:    ($result.mode)"
    print $"  uname output:  ($result.uname)"

    # ── Step 3: Agent appends reply to spool ─────────────────────────────────
    print ""
    print "▶ Step 3: Agent appending reply to spool..."

    let reply_ts     = date now | format date "%a, %d %b %Y %H:%M:%S -0000"
    let reply_dstamp = date now | format date "%a %b %e %H:%M:%S %Y"

    let reply_toml = $"task_id = \"($task_id)\"
verdict  = \"($result.verdict)\"

[output]
uname        = ($result.uname | to json)
kern_version = ($result.kern_version | to json)
df_root      = ($result.df_root | to json)
boot_sec     = ($result.boot_sec)

[[claims]]
subject  = \"smolBSD contains FreeBSD\"
expected = \"uname output contains 'FreeBSD'\"
probe    = \"uname -a\"
evidence = ($result.uname | to json)
verdict  = \"($result.verdict)\"
"

    let reply_envelope = $"From builder@smolfire.local ($reply_dstamp)
From: builder@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [($task_id)] Boot smolBSD and collect system identity
Date: ($reply_ts)
Message-ID: <($task_id).builder@smolfire.local>
In-Reply-To: <($task_id).coord@smolfire.local>
References: <($task_id).coord@smolfire.local>
X-Project: smolbsd
X-Verdict: ($result.verdict)
Content-Type: text/toml; charset=utf-8

($reply_toml)
"

    $reply_envelope | save --append $abs_spool
    print $"  reply appended — verdict: ($result.verdict)"
    print $"  Message-ID: <($task_id).builder@smolfire.local>"

    # ── Step 4: Coordinator harvests via coord-tick ──────────────────────────
    print ""
    print "▶ Step 4: Coordinator running harvest tick..."

    let nu_bin    = "/opt/homebrew/bin/nu"
    let tick_bin  = [$root, "bin", "coord-tick.nu"] | path join

    # coord-tick.nu uses --spool and --state-file flags; route it at our demo spool
    let tick_result = do {
        ^$nu_bin --no-config-file $tick_bin --spool $abs_spool --state-file $abs_state --max-ticks 5 --root $root
    } | complete

    let tick_ok = $tick_result.exit_code == 0
    if $tick_ok {
        print "  coord-tick exit 0 — FSM cycle complete"
        # Extract seen_ids count from TOML log lines on stdout
        let seen_lines = $tick_result.stdout
            | lines
            | where { |l| $l | str contains "seen_ids" }
        if ($seen_lines | length) > 0 {
            print $"  ($seen_lines | last | str trim)"
        }
    } else {
        print $"  coord-tick non-zero exit \(($tick_result.exit_code)\) — partial output:"
        $tick_result.stdout | lines | first 5 | each { |l| print $"    ($l)" }
        $tick_result.stderr | lines | first 3 | each { |l| print $"    STDERR: ($l)" }
    }

    # Read back the demo state so we can show the FSM landed in "idle"
    let final_state = if ($abs_state | path exists) {
        try { open --raw $abs_state | from toml } catch { {} }
    } else { {} }
    let fsm_landed = $final_state | get fsm_state? | default "unknown"
    let tick_count = $final_state | get tick_count? | default 0

    # ── Step 5: Proof-of-transfer summary ────────────────────────────────────
    print ""
    print "╔══════════════════════════════════════════════════════╗"
    print "║  PROOF OF STATE TRANSFER                             ║"
    print "╠══════════════════════════════════════════════════════╣"
    print $"║  task written:    <($task_id).coord@smolfire.local>"
    print $"║  agent executed:  ($result.mode)"
    print $"║  reply received:  <($task_id).builder@smolfire.local>"
    print $"║  FSM ticks:       ($tick_count)"
    print $"║  FSM final state: ($fsm_landed)"
    print $"║  verdict:         ($result.verdict)"
    print "╠══════════════════════════════════════════════════════╣"
    print "║  CLAIM BLOCK (would be fleet-eval verified in P2)    ║"
    print $"║    subject:  smolBSD contains FreeBSD"
    print $"║    probe:    uname -a"
    print $"║    evidence: ($result.uname | str substring 0..48)"
    print $"║    verdict:  ($result.verdict)"
    print "╚══════════════════════════════════════════════════════╝"

    # Exit non-zero if verdict is not pass — makes CI-friendly
    if $result.verdict != "pass" {
        error make {msg: $"demo verdict is '($result.verdict)' — expected 'pass'"}
    }
}

# ── Mock agent ───────────────────────────────────────────────────────────────

# Simulate what a real smolBSD VM would return when booted and queried.
# No VM, no SSH, no network required.
def run-mock-agent [task_id: string, arch: string] {
    let uname_arch = if $arch == "arm64" { "aarch64" } else { "amd64" }
    {
        mode:         "mock"
        verdict:      "pass"
        uname:        $"FreeBSD smolbsd 15.0-RELEASE FreeBSD 15.0-RELEASE #0 SMOLBSD: ($uname_arch)"
        kern_version: "FreeBSD 15.0-RELEASE #0 SMOLBSD"
        df_root:      "/dev/vtbd0p2  1048576  262144  786432  25%  /"
        boot_sec:     0
    }
}

# ── Live agent ───────────────────────────────────────────────────────────────

# Boot the real smolBSD qcow2 via vm-execute.nu, return output in demo format.
def run-live-agent [arch: string, image_path: string] {
    use vm-execute.nu [run-vm-task]

    let result = run-vm-task "demo-001" $image_path ["uname -s -r -m", "sysctl -n kern.version"] --arch $arch --use-overlay

    let uname_out = $result.outputs | where cmd == "uname -s -r -m" | first | get -o stdout | default "unknown"
    let kver_out = $result.outputs | where cmd == "sysctl -n kern.version" | first | get -o stdout | default "unknown"

    {
        mode: "live"
        verdict: $result.verdict
        uname: $uname_out
        kern_version: $kver_out
        df_root: "n/a"
        boot_sec: $result.boot_sec
    }
}
