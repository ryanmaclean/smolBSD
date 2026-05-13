# SPDX-License-Identifier: Apache-2.0
# qcow2-to-physical.nu — convert a Phase-I qcow2 artifact to a raw+GPT image
# suitable for physical board boot (Pi 5 / RK3588).
#
# Pipeline (per plans/tinyos/PHASE-2-PHYSICAL-BOOT.md §4):
#   Step 1: qemu-img convert -f qcow2 -O raw
#   Step 2: mount raw via mdconfig (FreeBSD) or attach via hdiutil (macOS fallback note)
#   Step 3: inject board DTB into the EFI/ESP partition
#   Step 4: patch /boot/loader.conf for physical UART
#   Step 5: (Pi 5 only) place RPI_EFI.fd firmware blob in ESP
#   Step 6: unmount + detach + optional size check
#
# Usage:
#   nu bin/qcow2-to-physical.nu \
#       --input  FreeBSD-15.0-RELEASE-aarch64-SMOLBSD.qcow2 \
#       --output smolbsd-aarch64-pi5.raw \
#       --board  pi5
#
# Prerequisites (must be present on FreeBSD build host):
#   qemu-img, mdconfig, mount_msdosfs, mount, umount, cp, truncate
#
# This script is designed to run on the FreeBSD fbuild VM (aarch64).
# Running on macOS is NOT supported for the mdconfig path; use a FreeBSD host.

# ── Board profiles ─────────────────────────────────────────────────────────────

# Return the DTB filename for a given board identifier.
def board-dtb [board: string] {
    match $board {
        "pi5"    => "bcm2712-rpi-5-b.dtb"
        "rk3588" => "rk3588-rock-5b.dtb"
        _        => { error make {msg: $"Unknown board '($board)'. Supported: pi5, rk3588"} }
    }
}

# Return the UART console string for loader.conf for a given board.
def board-uart-console [board: string] {
    match $board {
        "pi5"    => "uart,io,0xfe201000"   # BCM2712 PL011 UART0
        "rk3588" => "uart,io,0xff1a0000"   # RK3588 UART2 (ROCK 5B typical)
        _        => { error make {msg: $"Unknown board '($board)'. Supported: pi5, rk3588"} }
    }
}

# Return the standard DTB search path on FreeBSD (sys/contrib/device-tree).
def board-dtb-src-path [board: string] {
    let dtb = board-dtb $board
    $"/usr/share/dtb/($dtb)"
}

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped step log line to stdout.
# Structured as TOML for pipeline-friendly output (same convention as coord-tick.nu).
def log-step [step: string, msg: string, extra: record = {}] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── External command helpers ───────────────────────────────────────────────────

# Run an external command and error out with a structured message on failure.
# Returns stdout as a string.
def run-cmd [label: string, ...args: string] {
    log-step $"run/($label)" $"running: ($args | str join ' ')"
    let result = do { ^($args | first) ...($args | skip 1) } | complete
    if $result.exit_code != 0 {
        error make {
            msg: $"($label) failed (exit ($result.exit_code)): ($result.stderr | str trim)"
        }
    }
    $result.stdout
}

# ── Pipeline steps ─────────────────────────────────────────────────────────────

# Step 1: Convert qcow2 → raw using qemu-img.
def step-convert [input: string, output: string] {
    log-step "step1/convert" $"converting qcow2 to raw" {input: $input, output: $output}

    if not ($input | path exists) {
        error make {msg: $"Input file not found: ($input)"}
    }

    run-cmd "qemu-img" "qemu-img" "convert" "-f" "qcow2" "-O" "raw" $input $output

    # Pad to 512 MiB minimum so SD card write always covers a full image.
    let min_size = 536870912  # 512 MiB in bytes
    let actual_size = (ls $output | first | get size)
    if $actual_size < $min_size {
        log-step "step1/pad" $"padding raw image to 512 MiB" {
            current_bytes: $actual_size
            target_bytes:  $min_size
        }
        run-cmd "truncate" "truncate" "-s" "512m" $output
    }

    let final_size = (ls $output | first | get size)
    log-step "step1/done" "raw image ready" {output: $output, size_bytes: $final_size}
}

# Step 2: Attach raw image via mdconfig; returns the md unit number (int).
def step-mdconfig-attach [output: string] {
    log-step "step2/mdconfig" "attaching raw image via mdconfig" {image: $output}

    # mdconfig -f <file> -u 0 — we use unit 0; caller must ensure it is free.
    # On failure (unit busy) the error message from mdconfig surfaces via run-cmd.
    run-cmd "mdconfig" "mdconfig" "-f" $output "-u" "0"

    # Confirm the device node exists.
    let dev = "/dev/md0"
    if not ($dev | path exists) {
        error make {msg: $"mdconfig succeeded but ($dev) not present"}
    }

    log-step "step2/done" "md device attached" {device: $dev}
    0  # return unit number
}

# Step 3: Inject DTB into the ESP (EFI partition, typically md0s1 / FAT32).
def step-inject-dtb [board: string, md_unit: int, mnt_esp: string] {
    let dev_esp  = $"/dev/md($md_unit)s1"
    let dtb_name = board-dtb $board
    let dtb_src  = board-dtb-src-path $board

    log-step "step3/dtb" "injecting board DTB into ESP" {
        board:   $board
        dtb:     $dtb_name
        src:     $dtb_src
        esp_dev: $dev_esp
        mnt:     $mnt_esp
    }

    if not ($dtb_src | path exists) {
        error make {
            msg: $"DTB not found at ($dtb_src). Install dtb package or build from source (see §9.3 of PHASE-2-PHYSICAL-BOOT.md)."
        }
    }

    # Create mount point if absent.
    if not ($mnt_esp | path exists) {
        mkdir $mnt_esp
    }

    run-cmd "mount_msdosfs" "mount_msdosfs" $dev_esp $mnt_esp
    run-cmd "cp-dtb" "cp" $dtb_src $"($mnt_esp)/($dtb_name)"

    # Pi 5: also write config.txt boot options if not already present.
    if $board == "pi5" {
        let config_txt = $"($mnt_esp)/config.txt"
        let config_lines = "arm_64bit=1\nenable_uart=1\ndtoverlay=disable-bt\ngpu_mem=16\n"
        if not ($config_txt | path exists) {
            log-step "step3/config_txt" "writing Pi 5 config.txt" {path: $config_txt}
            $config_lines | save $config_txt
        } else {
            log-step "step3/config_txt" "config.txt already present; skipping" {path: $config_txt}
        }
    }

    log-step "step3/done" "DTB injected" {dtb: $dtb_name, mnt: $mnt_esp}
}

# Step 4: Patch /boot/loader.conf on the UFS root partition for physical UART.
def step-patch-loader-conf [board: string, md_unit: int, mnt_root: string] {
    let dev_root    = $"/dev/md($md_unit)s2"
    let uart_line   = $"console=\"(board-uart-console $board)\""
    let loader_conf = $"($mnt_root)/boot/loader.conf"

    log-step "step4/loader_conf" "patching loader.conf for physical UART" {
        board:       $board
        dev:         $dev_root
        mnt:         $mnt_root
        uart_line:   $uart_line
        loader_conf: $loader_conf
    }

    if not ($mnt_root | path exists) {
        mkdir $mnt_root
    }

    run-cmd "mount-ufs" "mount" $dev_root $mnt_root

    if not ($loader_conf | path exists) {
        error make {msg: $"loader.conf not found at ($loader_conf) — is this a valid FreeBSD root?"}
    }

    # Append only if the line is not already present (idempotent).
    let existing = open --raw $loader_conf
    if not ($existing | str contains $uart_line) {
        $"\n# Physical UART console — injected by qcow2-to-physical.nu\n($uart_line)\n"
            | save --append $loader_conf
        log-step "step4/done" "loader.conf patched" {appended: $uart_line}
    } else {
        log-step "step4/done" "loader.conf already contains UART line; skipping" {line: $uart_line}
    }
}

# Step 5 (Pi 5 only): copy RPI_EFI.fd firmware blob into ESP.
# Caller must supply --efi-blob path; if absent the step is skipped with a warning.
def step-place-efi-blob [board: string, efi_blob: string, mnt_esp: string] {
    if $board != "pi5" {
        log-step "step5/efi_blob" "skipping EFI blob step (not Pi 5)" {board: $board}
        return
    }

    if $efi_blob == "" {
        log-step "step5/efi_blob" "WARNING: --efi-blob not provided; RPI_EFI.fd not copied. Board will not boot without firmware blob." {
            note: "download from https://github.com/pftf/RPi4/releases and pass --efi-blob RPI_EFI.fd"
        }
        return
    }

    if not ($efi_blob | path exists) {
        error make {msg: $"EFI blob not found: ($efi_blob). Download from pftf/RPi4 Pi5 branch."}
    }

    log-step "step5/efi_blob" "placing RPI_EFI.fd in ESP" {src: $efi_blob, mnt: $mnt_esp}
    run-cmd "cp-efi-blob" "cp" $efi_blob $"($mnt_esp)/RPI_EFI.fd"
    log-step "step5/done" "RPI_EFI.fd placed" {dst: $"($mnt_esp)/RPI_EFI.fd"}
}

# Step 6: Unmount partitions and detach md device.
def step-teardown [md_unit: int, mnt_esp: string, mnt_root: string] {
    log-step "step6/teardown" "unmounting and detaching md device" {unit: $md_unit}

    # Best-effort unmounts — log errors but do not abort; we still want to
    # attempt mdconfig -d even if one umount fails.
    for mnt in [$mnt_esp, $mnt_root] {
        if ($mnt | path exists) and (^mount | str contains $mnt) {
            let r = do { ^umount $mnt } | complete
            if $r.exit_code != 0 {
                log-step "step6/umount_warn" $"umount ($mnt) failed — may already be unmounted" {
                    stderr: ($r.stderr | str trim)
                }
            } else {
                log-step "step6/umount" $"unmounted ($mnt)" {}
            }
        }
    }

    let r = do { ^mdconfig "-d" "-u" ($md_unit | into string) } | complete
    if $r.exit_code != 0 {
        log-step "step6/mdconfig_warn" "mdconfig -d failed" {stderr: ($r.stderr | str trim)}
    } else {
        log-step "step6/done" "md device detached" {unit: $md_unit}
    }
}

# ── Entry point ────────────────────────────────────────────────────────────────

# Convert a Phase-I qcow2 image to a raw+GPT image for physical board boot.
#
# --input     path to input qcow2 file (required)
# --output    path to output raw image (required)
# --board     target board: pi5 or rk3588 (required)
# --efi-blob  path to RPI_EFI.fd firmware blob (Pi 5 only; warns if absent)
# --mnt-esp   mount point for EFI partition  (default: /mnt/esp)
# --mnt-root  mount point for UFS root       (default: /mnt/root)
# --skip-teardown  leave partitions mounted + md attached (debug aid)
export def main [
    --input:         string             # path to input qcow2 file
    --output:        string             # path to output raw image
    --board:         string             # pi5 | rk3588
    --efi-blob:      string = ""        # Pi 5: path to RPI_EFI.fd
    --mnt-esp:       string = "/mnt/esp"
    --mnt-root:      string = "/mnt/root"
    --skip-teardown                     # leave mounts up (debug)
] {
    # ── Validate required args ──────────────────────────────────────────────
    if $input == null or $input == "" {
        error make {msg: "--input is required"}
    }
    if $output == null or $output == "" {
        error make {msg: "--output is required"}
    }
    if $board == null or $board == "" {
        error make {msg: "--board is required (pi5 or rk3588)"}
    }

    # Validate board value up front so we fail before doing any I/O.
    let _dtb_check = board-dtb $board   # errors on unknown board

    log-step "start" "qcow2-to-physical starting" {
        input:    $input
        output:   $output
        board:    $board
        efi_blob: $efi_blob
        mnt_esp:  $mnt_esp
        mnt_root: $mnt_root
    }

    # ── Check we are on FreeBSD (mdconfig is FreeBSD-only) ─────────────────
    let os = $nu.os-info.name
    if $os != "freebsd" {
        error make {
            msg: $"This script requires a FreeBSD host (mdconfig). Detected OS: ($os). Run on the fbuild VM (ssh -J minim4-24 -p 2222 builder@localhost)."
        }
    }

    # ── Step 1: convert ─────────────────────────────────────────────────────
    step-convert $input $output

    # ── Step 2: attach raw image ────────────────────────────────────────────
    let md_unit = step-mdconfig-attach $output

    # ── Steps 3–5: mount + inject (teardown runs even on error via try/catch)
    try {
        step-inject-dtb      $board $md_unit $mnt_esp
        step-patch-loader-conf $board $md_unit $mnt_root
        step-place-efi-blob  $board $efi_blob $mnt_esp
    } catch {|err|
        log-step "error" "pipeline step failed — attempting teardown" {
            error: ($err | get msg? | default "unknown error")
        }
        if not $skip_teardown {
            step-teardown $md_unit $mnt_esp $mnt_root
        }
        error make {msg: ($err | get msg? | default "pipeline failed")}
    }

    # ── Step 6: unmount + detach ────────────────────────────────────────────
    if not $skip_teardown {
        step-teardown $md_unit $mnt_esp $mnt_root
    } else {
        log-step "skip-teardown" "leaving mounts up per --skip-teardown flag" {
            mnt_esp:  $mnt_esp
            mnt_root: $mnt_root
            md_unit:  $md_unit
        }
    }

    # ── Final size check (§7.4 acceptance gate) ─────────────────────────────
    let final_size = (ls $output | first | get size)
    let max_size   = 536870912  # 512 MiB
    if $final_size > $max_size {
        log-step "size_warn" "WARNING: output exceeds 512 MiB hard cap (§7.4)" {
            size_bytes: $final_size
            cap_bytes:  $max_size
        }
    }

    log-step "done" "qcow2-to-physical complete" {
        output:     $output
        board:      $board
        size_bytes: $final_size
    }
}
