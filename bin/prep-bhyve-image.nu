#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# prep-bhyve-image.nu — convert a Phase-I qcow2 artifact to a bhyve-ready raw image.
#
# bhyve works best with raw images (or ZFS zvols). Phase-I produces qcow2.
# This script bridges the gap: validate, convert, pad, and verify.
#
# Usage:
#   nu bin/prep-bhyve-image.nu --input FreeBSD-15.0-RELEASE-amd64-SMOLBSD.qcow2
#   nu bin/prep-bhyve-image.nu --input smolbsd.qcow2 --output smolbsd.raw --force
#   nu bin/prep-bhyve-image.nu --input smolbsd.qcow2 --verify --min-size-mib 1024
#
# See: plans/tinyos/PHASE-3-TPM.md

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped TOML log-step line to stdout.
def log-step [step: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, step: $step} | merge $payload
    $row | to toml | print
    print "---"
}

# ── Host capability check ──────────────────────────────────────────────────────

# Verify that this host is ready to run bhyve guests.
# Returns {ready: bool, missing: list<string>}.
export def check-bhyve-host [] {
    mut missing = []

    # /dev/vmm — created by vmm.ko; bhyve will not start without it
    if not ("/dev/vmm" | path exists) {
        $missing = ($missing | append "/dev/vmm (load vmm.ko: kldload vmm)")
    }

    # bhyve binary — base system on FreeBSD 15, but verify
    let bhyve_bin = "/usr/sbin/bhyve"
    if not ($bhyve_bin | path exists) {
        $missing = ($missing | append $"($bhyve_bin) (bhyve not found in base system)")
    }

    # BHYVE_UEFI.fd — standard install path from sysutils/bhyve-firmware
    let uefi_paths = [
        "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
        "/usr/local/share/bhyve/BHYVE_UEFI.fd"
    ]
    let uefi_found = $uefi_paths | any { |p| $p | path exists }
    if not $uefi_found {
        $missing = ($missing | append "BHYVE_UEFI.fd (install sysutils/bhyve-firmware)")
    }

    # /dev/nmdm0A — null modem for serial console access
    if not ("/dev/nmdm0A" | path exists) {
        $missing = ($missing | append "/dev/nmdm0A (load nmdm.ko: kldload nmdm)")
    }

    let ready = ($missing | length) == 0
    {ready: $ready, missing: $missing}
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Convert a Phase-I qcow2 artifact to a bhyve-ready raw disk image.
export def main [
    --input: string           # path to .qcow2 artifact (required)
    --output: string = ""     # defaults to <input-stem>.raw
    --force                   # overwrite existing output
    --verify                  # run qemu-img check on input first
    --min-size-mib: int = 512 # pad output to at least this size in MiB
] {

    # ── Step 1: validate input ────────────────────────────────────────────────
    if ($input | str length) == 0 {
        error make {msg: "--input is required (path to .qcow2 artifact)"}
    }

    if not ($input | path exists) {
        error make {msg: $"input file not found: ($input)"}
    }

    if not ($input | str ends-with ".qcow2") {
        error make {msg: $"input must end in .qcow2, got: ($input)"}
    }

    log-step "validate_input" {
        input:        $input
        min_size_mib: $min_size_mib
        verify:       $verify
        force:        $force
    }

    # ── Step 2: optional qemu-img check ──────────────────────────────────────
    if $verify {
        log-step "verify_input" {input: $input, cmd: "qemu-img check"}

        let qemu_img = "/usr/local/bin/qemu-img"
        if not ($qemu_img | path exists) {
            error make {msg: $"qemu-img not found at ($qemu_img); install emulators/qemu-utils"}
        }

        ^$qemu_img check $input
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: $"qemu-img check failed for ($input) — image may be corrupt"}
        }
        log-step "verify_input_ok" {input: $input, verdict: "pass"}
    }

    # ── Step 3: derive output path ─────────────────────────────────────────────
    let out_path = if ($output | str length) > 0 {
        $output
    } else {
        # Replace .qcow2 extension with .raw
        let stem = $input | path parse | get stem
        let dir  = $input | path dirname
        [$dir, $"($stem).raw"] | path join
    }

    log-step "output_path" {output: $out_path}

    # ── Step 4: check for existing output ─────────────────────────────────────
    if ($out_path | path exists) {
        if not $force {
            error make {
                msg: $"output already exists: ($out_path) — use --force to overwrite"
            }
        }
        log-step "overwrite_existing" {output: $out_path, force: true}
        ^rm -f $out_path
    }

    # ── Step 5: convert qcow2 → raw ───────────────────────────────────────────
    let qemu_img = "/usr/local/bin/qemu-img"
    if not ($qemu_img | path exists) {
        error make {msg: $"qemu-img not found at ($qemu_img); install emulators/qemu-utils"}
    }

    log-step "convert_start" {
        input:  $input
        output: $out_path
        cmd:    $"qemu-img convert -f qcow2 -O raw ($input) ($out_path)"
    }

    ^$qemu_img convert -f qcow2 -O raw $input $out_path
    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: $"qemu-img convert failed (exit ($env.LAST_EXIT_CODE))"}
    }

    log-step "convert_done" {output: $out_path}

    # ── Step 6: pad to min-size-mib if needed ─────────────────────────────────
    let current_bytes = (ls $out_path | get size | first)
    let min_bytes     = $min_size_mib * 1024 * 1024

    # current_bytes is a filesize type; compare as int via into int
    let current_int = $current_bytes | into int
    if $current_int < $min_bytes {
        log-step "pad_image" {
            current_mib: ($current_int / 1024 / 1024)
            target_mib:  $min_size_mib
            output:      $out_path
        }

        let truncate_bin = "/usr/bin/truncate"
        if not ($truncate_bin | path exists) {
            error make {msg: $"truncate not found at ($truncate_bin)"}
        }

        let size_arg = $"($min_size_mib)m"
        ^$truncate_bin -s $size_arg $out_path
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: $"truncate failed (exit ($env.LAST_EXIT_CODE))"}
        }

        log-step "pad_done" {output: $out_path, padded_to_mib: $min_size_mib}
    } else {
        log-step "pad_skip" {
            current_mib: ($current_int / 1024 / 1024)
            min_size_mib: $min_size_mib
            note:         "image already meets minimum size"
        }
    }

    # ── Step 7: verify output is a valid disk image ────────────────────────────
    log-step "verify_output" {output: $out_path, cmd: "file"}

    let file_output = ^file $out_path | str downcase
    # FreeBSD file(1) on raw disk images may report any of these strings
    # depending on the partition scheme and sector content:
    #   "boot sector"            — MBR or hybrid
    #   "dos/mbr boot sector"    — GPT protective MBR (common for FreeBSD images)
    #   "gpt"                    — GPT detected by newer file(1) signatures
    #   "x86 boot sector"        — BIOS-bootable GPT with protective MBR
    #   "unix fast file system"  — UFS root starts at sector 0 (rare, diskless)
    #   "ascii text" / "data"    — zero-padded or freshly converted; warn but allow
    let is_valid = (
        ($file_output | str contains "boot sector") or
        ($file_output | str contains "dos/mbr") or
        ($file_output | str contains "gpt") or
        ($file_output | str contains "x86 boot") or
        ($file_output | str contains "unix fast file system") or
        ($file_output | str contains "hard disk")
    )

    if not $is_valid {
        log-step "verify_output_warn" {
            output:      $out_path
            file_result: $file_output
            note:        "file(1) did not find boot sector / DOS/MBR / GPT — image may be unbootable"
        }
    } else {
        log-step "verify_output_ok" {
            output:      $out_path
            file_result: $file_output
            verdict:     "pass"
        }
    }

    # ── Step 8: print final size ───────────────────────────────────────────────
    let stat = ls $out_path | first
    log-step "final_size" {
        output: $out_path
        size:   ($stat.size | into string)
    }

    # Human-readable summary to stderr so it is visible even when stdout is piped
    print -e $"prep-bhyve-image: ($out_path)"
    print -e $"  size: ($stat.size)"
    print -e $"  ready for: nu bin/bhyve-smolbsd.nu --image ($out_path)"
}
