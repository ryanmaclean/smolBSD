#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# smolbsd.nu — top-level CLI entry point for the smolBSD toolchain.
#
# Dispatches to all other bin/ scripts.  All flags after the subcommand
# are passed through verbatim to the delegate script.
#
# Usage:
#   nu bin/smolbsd.nu <subcommand> [flags...]
#   nu bin/smolbsd.nu help
#
# Subcommands:
#   build        nu bin/prep-bhyve-image.nu   — convert qcow2 → raw, verify image
#   test         nu bin/run-vm-tests.nu        — run full VM acceptance test suite
#   convert      nu bin/qcow2-to-physical.nu   — convert qcow2 → physical board raw+GPT
#   ci-gate      nu bin/ci-gate.nu             — check / enforce 3-consecutive-pass gate
#   board-probe  nu bin/board-probe.nu         — detect connected physical boards
#   swtpm        nu bin/swtpm-setup.nu         — manage swtpm daemon lifecycle
#   bhyve        nu bin/bhyve-smolbsd.nu       — launch smolBSD bhyve guest
#   coord        nu bin/coord-tick.nu          — run coordinator FSM tick
#   first-boot   nu bin/first-boot.nu          — run first-boot provisioning in guest
#   mbox-parse   nu bin/mbox-parse.nu          — parse var/mail/spool into records
#   tpm-verify   nu tests/bhyve-tpm-pcr-verify.nu — run T1-T6 TPM verification
#   help         print this table and exit
#
# Examples:
#   nu bin/smolbsd.nu build --input FreeBSD-15.0-RELEASE-amd64-SMOLBSD.qcow2
#   nu bin/smolbsd.nu test --image smolbsd-amd64.raw --tpm
#   nu bin/smolbsd.nu convert --input foo.qcow2 --board pi5 --output foo-pi5.raw
#   nu bin/smolbsd.nu ci-gate --results-dir /tmp/results
#   nu bin/smolbsd.nu ci-gate --run --image smolbsd-amd64.raw --tpm
#   nu bin/smolbsd.nu board-probe
#   nu bin/smolbsd.nu swtpm --action start
#   nu bin/smolbsd.nu bhyve --image smolbsd-amd64.raw --tpm
#   nu bin/smolbsd.nu coord --dispatch-phase-ii
#   nu bin/smolbsd.nu tpm-verify --host 127.0.0.1 --port 2240
#   nu bin/smolbsd.nu tpm-verify --dry-run

# ── subcommand table (used by `help`) ─────────────────────────────────────────

def subcommand-table [] {
    [
        {subcommand: "build",       script: "bin/prep-bhyve-image.nu",          description: "Convert qcow2 -> raw bhyve image; verify size and integrity"},
        {subcommand: "test",        script: "bin/run-vm-tests.nu",               description: "Run the full smolBSD VM acceptance test suite in bhyve"},
        {subcommand: "convert",     script: "bin/qcow2-to-physical.nu",          description: "Convert qcow2 -> physical board raw+GPT (Pi 5 / RK3588)"},
        {subcommand: "ci-gate",     script: "bin/ci-gate.nu",                    description: "Check 3-consecutive-pass CI gate; optionally run tests first"},
        {subcommand: "board-probe", script: "bin/board-probe.nu",                description: "Detect and profile connected physical boards via serial/SSH"},
        {subcommand: "swtpm",       script: "bin/swtpm-setup.nu",                description: "Manage swtpm daemon: start | stop | status | reset"},
        {subcommand: "bhyve",       script: "bin/bhyve-smolbsd.nu",              description: "Launch smolBSD bhyve guest with optional swtpm TPM"},
        {subcommand: "coord",       script: "bin/coord-tick.nu",                 description: "Run one coordinator FSM tick (or --dispatch-phase-ii)"},
        {subcommand: "first-boot",  script: "bin/first-boot.nu",                 description: "Run first-boot provisioning inside a booted smolBSD guest"},
        {subcommand: "mbox-parse",  script: "bin/mbox-parse.nu",                 description: "Parse var/mail/spool into structured TOML records"},
        {subcommand: "tpm-verify",  script: "tests/bhyve-tpm-pcr-verify.nu",    description: "Run T1-T6 TPM verification against a live bhyve+swtpm guest"},
        {subcommand: "help",        script: "(built-in)",                         description: "Print this subcommand table and exit"},
    ]
}

# ── help printer ──────────────────────────────────────────────────────────────

def print-help [] {
    print "smolbsd — smolBSD toolchain CLI"
    print ""
    print "Usage: nu bin/smolbsd.nu <subcommand> [flags...]"
    print ""
    subcommand-table | select subcommand script description | print
    print ""
    print "All flags after the subcommand are forwarded verbatim to the delegate script."
    print "Run `nu <script> --help` for per-subcommand flag documentation."
}

# ── main ──────────────────────────────────────────────────────────────────────

def main [
    subcommand?: string,   # subcommand to dispatch (omit to print help)
    ...args: string,       # remaining flags/args forwarded to delegate script
] {
    let sub = $subcommand | default "help"

    match $sub {
        "help" => {
            print-help
        }

        "build" => {
            ^nu --no-config-file bin/prep-bhyve-image.nu ...$args
        }

        "test" => {
            ^nu --no-config-file bin/run-vm-tests.nu ...$args
        }

        "convert" => {
            ^nu --no-config-file bin/qcow2-to-physical.nu ...$args
        }

        "ci-gate" => {
            ^nu --no-config-file bin/ci-gate.nu ...$args
        }

        "board-probe" => {
            ^nu --no-config-file bin/board-probe.nu ...$args
        }

        "swtpm" => {
            ^nu --no-config-file bin/swtpm-setup.nu ...$args
        }

        "bhyve" => {
            ^nu --no-config-file bin/bhyve-smolbsd.nu ...$args
        }

        "coord" => {
            ^nu --no-config-file bin/coord-tick.nu ...$args
        }

        "first-boot" => {
            ^nu --no-config-file bin/first-boot.nu ...$args
        }

        "mbox-parse" => {
            ^nu --no-config-file bin/mbox-parse.nu ...$args
        }

        "tpm-verify" => {
            ^nu --no-config-file tests/bhyve-tpm-pcr-verify.nu ...$args
        }

        _ => {
            print $"error: unknown subcommand '($sub)'"
            print ""
            print-help
            exit 1
        }
    }
}
