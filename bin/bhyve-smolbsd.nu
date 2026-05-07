#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bhyve-smolbsd.nu — launch smolBSD inside bhyve with optional swtpm
#
# Boots a smolBSD qcow2 or raw image in bhyve on a FreeBSD 15 host.
# With --tpm, starts an swtpm socket daemon and passes it to bhyve as a
# CRB TPM device; the guest sees /dev/tpm0 and can read PCR0 via tpm2-tools.
#
# Prerequisites (on FreeBSD bhyve host):
#   - bhyve(8), bhyvectl(8)  (base system)
#   - swtpm                  (security/swtpm port, BSD-3-Clause)
#   - /usr/local/share/uefi-firmware/BHYVE_UEFI.fd  (sysutils/bhyve-firmware)
#   - tap0 already created and bridged (ifconfig tap0 create; ifconfig bridge0 addm tap0)
#
# Usage:
#   nu bin/bhyve-smolbsd.nu --image FreeBSD-15.0-RELEASE-amd64-SMOLBSD.raw
#   nu bin/bhyve-smolbsd.nu --image smolbsd.raw --tpm --dry-run
#
# See: plans/tinyos/PHASE-2-PHYSICAL-BOOT.md

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped step log line to stdout.
# Structured as TOML for pipeline-friendly output (same convention as qcow2-to-physical.nu).
def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── swtpm helpers ──────────────────────────────────────────────────────────────

# Start an swtpm socket daemon.  Returns the socket path.
def start-swtpm [state_dir: string]: nothing -> string {
    let sock = $"($state_dir)/swtpm.sock"

    log-step "swtpm-start" "creating swtpm state directory" {dir: $state_dir}
    ^mkdir -p $state_dir

    log-step "swtpm-start" "launching swtpm daemon" {sock: $sock, state: $state_dir}
    let tpmstate_arg = $"dir=($state_dir)"
    let ctrl_arg = $"type=unixio,path=($sock)"
    ^swtpm socket --tpmstate $tpmstate_arg --tpm2 --ctrl $ctrl_arg --daemon

    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: $"swtpm failed to start (exit ($env.LAST_EXIT_CODE))"}
    }

    log-step "swtpm-start" "swtpm daemon started" {sock: $sock}
    $sock
}

# Stop swtpm by sending SIGTERM to any process holding the control socket.
def stop-swtpm [state_dir: string] {
    let sock = $"($state_dir)/swtpm.sock"
    log-step "swtpm-stop" "stopping swtpm" {sock: $sock}

    # swtpm writes its PID into <state_dir>/swtpm.pid when --daemon is used
    # with recent swtpm versions; fall back to pkill if the file is absent.
    let pid_file = $"($state_dir)/swtpm.pid"
    if ($pid_file | path exists) {
        let pid = open --raw $pid_file | str trim
        ^kill $pid
    } else {
        # Best-effort: kill any swtpm owning the unix socket
        ^pkill -f $"swtpm.*($sock)" o> /dev/null e> /dev/null
    }

    # Remove stale socket so a subsequent run does not see a leftover file
    if ($sock | path exists) {
        ^rm -f $sock
    }

    log-step "swtpm-stop" "swtpm stopped"
}

# ── Main ───────────────────────────────────────────────────────────────────────

def main [
    --image: string                         # path to smolBSD qcow2 or raw image
    --arch: string = "amd64"               # amd64 | aarch64
    --mem: string = "512M"
    --cpus: int = 2
    --tpm                                   # attach swtpm socket as CRB TPM device
    --tpm-state: string = "/var/run/smolbsd-tpm"  # swtpm state directory
    --hostfwd-ssh: int = 2240              # host port forwarded to guest :22
    --console: string = "/dev/nmdm0A"     # bhyve null modem device (com1)
    --name: string = "smolbsd"
    --dry-run                              # print commands without running
] {
    # ── Validate inputs ─────────────────────────────────────────────────────
    if $image == null or $image == "" {
        error make {msg: "--image is required (path to smolBSD raw or qcow2 image)"}
    }

    if not ($image | path exists) {
        error make {msg: $"image not found: ($image)"}
    }

    let uefi_rom = "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
    if not ($uefi_rom | path exists) {
        log-step "preflight" "WARNING: UEFI ROM not found — install sysutils/bhyve-firmware" {path: $uefi_rom}
    }

    log-step "preflight" "bhyve-smolbsd starting" {
        image:   $image
        arch:    $arch
        mem:     $mem
        cpus:    $cpus
        tpm:     $tpm
        console: $console
        name:    $name
        dry_run: $dry_run
    }

    # ── Start swtpm if requested ─────────────────────────────────────────────
    mut sock_path = ""
    if $tpm {
        if $dry_run {
            log-step "swtpm-dry" "would start swtpm" {
                state_dir: $tpm_state
                sock:      $"($tpm_state)/swtpm.sock"
            }
            print $"swtpm socket --tpmstate dir=($tpm_state) --tpm2 --ctrl type=unixio,path=($tpm_state)/swtpm.sock --daemon"
            $sock_path = $"($tpm_state)/swtpm.sock"
        } else {
            $sock_path = start-swtpm $tpm_state
        }
    }

    # ── Build bhyve command line ─────────────────────────────────────────────
    mut slots = [
        "-s" "0,hostbridge"
        "-s" "1,lpc"
        "-s" $"2,virtio-blk,($image)"
        "-s" "3,virtio-net,tap0"
        "-s" "4,ahci-cd,/dev/null"
    ]

    if $tpm {
        $slots = ($slots | append ["-s" $"5,tpm,type=swtpm,path=($sock_path)"])
    }

    let bhyve_cmd = (
        ["bhyve"
            "-H" "-P"
            ...$slots
            "-l" $"com1,($console)"
            "-l" $"bootrom,($uefi_rom)"
            "-m" $mem
            "-c" ($cpus | into string)
            $name
        ]
    )

    log-step "bhyve-cmd" "constructed bhyve command line" {cmd: ($bhyve_cmd | str join " ")}

    # ── Dry-run: print and exit ──────────────────────────────────────────────
    if $dry_run {
        log-step "dry-run" "dry-run mode — printing commands and exiting"
        print ""
        print "# bhyve launch command:"
        print ($bhyve_cmd | str join " ")
        print ""
        print $"# To read PCR0 after boot:"
        print $"#   tpm2_pcrread sha256:0"
        return
    }

    # ── Destroy stale VM if it already exists ────────────────────────────────
    log-step "bhyve-pre" "destroying stale VM (if any)" {name: $name}
    ^bhyvectl --destroy --vm=$name o> /dev/null e> /dev/null

    # ── Launch bhyve ────────────────────────────────────────────────────────
    log-step "bhyve-run" "launching bhyve" {name: $name, console: $console}
    print $"# Attach to console:  cu -l ($console | str replace 'A' 'B')"
    print $"# or: minicom -D ($console | str replace 'A' 'B')"
    print ""

    ^...$bhyve_cmd
    let bhyve_exit = $env.LAST_EXIT_CODE

    log-step "bhyve-exit" "bhyve exited" {exit_code: $bhyve_exit, name: $name}

    # ── Cleanup ─────────────────────────────────────────────────────────────
    log-step "cleanup" "destroying bhyve VM" {name: $name}
    ^bhyvectl --destroy --vm=$name o> /dev/null e> /dev/null

    if $tpm {
        stop-swtpm $tpm_state
    }

    log-step "done" "bhyve-smolbsd finished" {exit_code: $bhyve_exit}

    if $bhyve_exit != 0 {
        exit $bhyve_exit
    }
}
