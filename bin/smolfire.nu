#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# smolfire.nu — top-level CLI entry point for the smolfire toolchain (formerly smolbsd.nu).
#
# Dispatches to all other bin/ scripts.  All flags after the subcommand
# are passed through verbatim to the delegate script.
#
# Usage:
#   nu bin/smolfire.nu <subcommand> [flags...]
#   nu bin/smolfire.nu help
#
# Subcommands:
#   build             nu bin/prep-bhyve-image.nu          — convert qcow2 → raw, verify image
#   test              nu bin/run-vm-tests.nu               — run full VM acceptance test suite (qemu|bhyve)
#   convert           nu bin/qcow2-to-physical.nu          — convert qcow2 → physical board raw+GPT
#   ci-gate           nu bin/ci-gate.nu                    — check / enforce 3-consecutive-pass gate
#   board-probe       nu bin/board-probe.nu                — detect connected physical boards
#   swtpm             nu bin/swtpm-setup.nu                — manage swtpm daemon lifecycle
#   bhyve             nu bin/bhyve-smolbsd.nu              — launch smolBSD bhyve guest
#   qemu              nu bin/qemu-smolbsd.nu               — launch smolBSD qemu guest (HVF on Apple Silicon)
#   provision vultr   nu bin/vultr-bhyve-provision.nu      — provision Vultr amd64 bhyve host
#   provision hetzner nu bin/hetzner-bhyve-provision.nu    — provision Hetzner amd64 bhyve host
#   coord             nu bin/coord-tick.nu                 — run coordinator FSM tick
#   first-boot        nu bin/first-boot.nu                 — run first-boot provisioning in guest
#   mbox-parse        nu bin/mbox-parse.nu                 — parse var/mail/spool into records
#   tpm-verify        nu tests/bhyve-tpm-pcr-verify.nu     — run T1-T6 TPM verification
#   help              print this table and exit
#
# Examples:
#   nu bin/smolfire.nu build --input FreeBSD-15.0-RELEASE-amd64-SMOLBSD.qcow2
#   nu bin/smolfire.nu test --image smolbsd.qcow2                           # qemu, default
#   nu bin/smolfire.nu test --image smolbsd.qcow2 --tpm                     # qemu + swtpm
#   nu bin/smolfire.nu test --image smolbsd.qcow2 --arch arm64              # qemu arm64
#   nu bin/smolfire.nu test --image smolbsd.raw --backend bhyve             # bhyve amd64
#   nu bin/smolfire.nu test --image smolbsd.raw --backend bhyve --tpm       # bhyve + swtpm
#   nu bin/smolfire.nu convert --input foo.qcow2 --board pi5 --output foo-pi5.raw
#   nu bin/smolfire.nu ci-gate --results-dir /tmp/results
#   nu bin/smolfire.nu ci-gate --run --image smolbsd-amd64.raw --tpm
#   nu bin/smolfire.nu board-probe
#   nu bin/smolfire.nu swtpm --action start
#   nu bin/smolfire.nu bhyve --image smolbsd-amd64.raw --tpm
#   nu bin/smolfire.nu qemu --image smolbsd.qcow2 --arch arm64
#   nu bin/smolfire.nu provision vultr --dry-run
#   nu bin/smolfire.nu provision hetzner --dry-run
#   nu bin/smolfire.nu provision hetzner --type robot --dry-run
#   nu bin/smolfire.nu coord --dispatch-phase-ii
#   nu bin/smolfire.nu tpm-verify --host 127.0.0.1 --port 2240
#   nu bin/smolfire.nu tpm-verify --dry-run

# ── subcommand table (used by `help`) ─────────────────────────────────────────

def subcommand-table [] {
    [
        {subcommand: "build",              script: "bin/prep-bhyve-image.nu",         description: "Convert qcow2 -> raw bhyve image; verify size and integrity"},
        {subcommand: "test",               script: "bin/run-vm-tests.nu",              description: "Run the full smolBSD VM acceptance test suite (--backend qemu|bhyve)"},
        {subcommand: "convert",            script: "bin/qcow2-to-physical.nu",         description: "Convert qcow2 -> physical board raw+GPT (Pi 5 / RK3588)"},
        {subcommand: "ci-gate",            script: "bin/ci-gate.nu",                   description: "Check 3-consecutive-pass CI gate; optionally run tests first"},
        {subcommand: "board-probe",        script: "bin/board-probe.nu",               description: "Detect and profile connected physical boards via serial/SSH"},
        {subcommand: "swtpm",              script: "bin/swtpm-setup.nu",               description: "Manage swtpm daemon: start | stop | status | reset"},
        {subcommand: "bhyve",              script: "bin/bhyve-smolbsd.nu",             description: "Launch smolBSD bhyve guest with optional swtpm TPM"},
        {subcommand: "qemu",               script: "bin/qemu-smolbsd.nu",              description: "Launch smolBSD qemu guest (HVF on Apple Silicon / KVM on Linux)"},
        {subcommand: "provision vultr",    script: "bin/vultr-bhyve-provision.nu",     description: "Provision Vultr amd64 bhyve host (bare-metal or KVM cloud)"},
        {subcommand: "provision hetzner",  script: "bin/hetzner-bhyve-provision.nu",   description: "Provision Hetzner amd64 bhyve host (hcloud ccx or Robot AX41)"},
        {subcommand: "coord",              script: "bin/coord-tick.nu",                description: "Run one coordinator FSM tick (or --dispatch-phase-ii)"},
        {subcommand: "first-boot",         script: "bin/first-boot.nu",                description: "Run first-boot provisioning inside a booted smolBSD guest"},
        {subcommand: "mbox-parse",         script: "bin/mbox-parse.nu",                description: "Parse var/mail/spool into structured TOML records"},
        {subcommand: "tpm-verify",         script: "tests/bhyve-tpm-pcr-verify.nu",   description: "Run T1-T6 TPM verification against a live bhyve+swtpm guest"},
        {subcommand: "help",               script: "(built-in)",                        description: "Print this subcommand table and exit"},
    ]
}

# ── help printer ──────────────────────────────────────────────────────────────

def print-help [] {
    print "smolbsd — smolBSD toolchain CLI"
    print ""
    print "Usage: nu bin/smolfire.nu <subcommand> [flags...]"
    print ""
    subcommand-table | select subcommand script description | print
    print ""
    print "All flags after the subcommand are forwarded verbatim to the delegate script."
    print "Run `nu <script> --help` for per-subcommand flag documentation."
}

# ── main ──────────────────────────────────────────────────────────────────────

def --wrapped main [
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

        "qemu" => {
            ^nu --no-config-file bin/qemu-smolbsd.nu ...$args
        }

        # provision <provider> [flags...]
        # First element of $args is the provider name; remaining args forwarded.
        "provision" => {
            let provider = if ($args | length) > 0 { $args | first } else { "" }
            let rest     = if ($args | length) > 1 { $args | skip 1 } else { [] }
            match $provider {
                "vultr" => {
                    ^nu --no-config-file bin/vultr-bhyve-provision.nu ...$rest
                }
                "hetzner" => {
                    ^nu --no-config-file bin/hetzner-bhyve-provision.nu ...$rest
                }
                _ => {
                    print $"error: unknown provision provider '($provider)'"
                    print "  usage: nu bin/smolfire.nu provision <vultr|hetzner> [flags...]"
                    print "  example: nu bin/smolfire.nu provision hetzner --dry-run"
                    print "  example: nu bin/smolfire.nu provision vultr --dry-run"
                    exit 1
                }
            }
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
