#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# board-probe.nu — detect physical board and emit a structured record.
#
# Usage (module):
#   use bin/board-probe.nu [probe-board]
#   let info = probe-board
#
# Usage (CLI):
#   nu bin/board-probe.nu              # prints TOML
#   nu bin/board-probe.nu --json       # prints JSON
#
# Detection order:
#   1. /etc/smolfire/board.conf  (written at image-build time by release/tools/*.conf)
#   2. /proc/device-tree/model  (Linux FDT — useful during cross-validation)
#   3. sysctl hw.model + kenv smbios.bios.vendor  (FreeBSD fallback)
#
# Output record shape:
#   {
#     board:   "pi5" | "rk3588" | "unknown"
#     soc:     string   # e.g. "bcm2712", "rk3588", ""
#     uart:    string   # e.g. "uart0", "uart,io,0xff1a0000", ""
#     storage: string   # e.g. "mmcsd0", "mmcsd0|nvd0", ""
#     tier:    int      # FreeBSD support tier: 2=community, 3=ports/wiki, 0=unknown
#   }
#
# See: plans/tinyos/PHASE-2-PHYSICAL-BOOT.md §3
#      release/tools/smolfire-pi5.conf
#      release/tools/smolfire-rk3588.conf

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Parse a shell-style KEY="VALUE" or KEY=VALUE config file into a record.
# Ignores comment lines (# ...) and blank lines.
def parse-shell-conf [path: string]: nothing -> record {
    let text = open --raw $path
    let pairs = (
        $text
        | lines
        | where {|l| ($l | str trim | str length) > 0 }
        | where {|l| not ($l | str trim | str starts-with "#") }
        | each {|l|
            let eq = $l | str index-of "="
            if $eq <= 0 { null } else {
                let key = $l | str substring ..$eq | str trim
                # Strip surrounding quotes from the value
                let raw_val = $l | str substring ($eq + 1).. | str trim
                let rlen = $raw_val | str length
                let val = (
                    if $rlen >= 2 and ($raw_val | str starts-with '"') and ($raw_val | str ends-with '"') {
                        $raw_val | str substring 1..($rlen - 2)
                    } else if $rlen >= 2 and ($raw_val | str starts-with "'") and ($raw_val | str ends-with "'") {
                        $raw_val | str substring 1..($rlen - 2)
                    } else {
                        $raw_val
                    }
                )
                {key: $key, val: $val}
            }
        }
        | where {|e| $e != null }
    )
    $pairs | reduce --fold {} {|pair, acc| $acc | insert $pair.key $pair.val }
}

# Map a known SOC/board string to a canonical result record.
def classify-board [soc: string, board_hint: string]: nothing -> record {
    let soc_lower  = $soc        | str downcase
    let hint_lower = $board_hint | str downcase

    # BCM2712 — Raspberry Pi 5
    if (
        ($soc_lower  | str contains "bcm2712") or
        ($hint_lower | str contains "pi 5") or
        ($hint_lower | str contains "pi5") or
        ($hint_lower | str contains "raspberry pi 5")
    ) {
        return {
            board:   "pi5"
            soc:     "bcm2712"
            uart:    "uart0"
            storage: "mmcsd0"
            tier:    2
        }
    }

    # RK3588 — ROCK 5B, Orange Pi 5 Plus, Khadas Edge2, etc.
    if (
        ($soc_lower  | str contains "rk3588") or
        ($hint_lower | str contains "rock 5b") or
        ($hint_lower | str contains "rock5b") or
        ($hint_lower | str contains "orange pi 5") or
        ($hint_lower | str contains "khadas edge2") or
        ($hint_lower | str contains "rk3588")
    ) {
        return {
            board:   "rk3588"
            soc:     "rk3588"
            uart:    "uart,io,0xff1a0000"
            storage: "mmcsd0|nvd0"
            tier:    3
        }
    }

    # Unknown / unrecognised
    {
        board:   "unknown"
        soc:     $soc_lower
        uart:    ""
        storage: ""
        tier:    0
    }
}

# Return the fallback unknown record.
def unknown-record []: nothing -> record {
    { board: "unknown", soc: "", uart: "", storage: "", tier: 0 }
}

# ---------------------------------------------------------------------------
# Path 1: /etc/smolfire/board.conf  (written by release/tools/*.conf)
# ---------------------------------------------------------------------------

# Probe from /etc/smolfire/board.conf; returns null if not present.
def probe-from-board-conf []: nothing -> any {
    let path = "/etc/smolfire/board.conf"
    if not ($path | path exists) { return null }

    let conf = parse-shell-conf $path
    let soc     = $conf | get SMOLFIRE_SOC?    | default ""
    let board   = $conf | get SMOLFIRE_BOARD?  | default ""
    let uart_io = $conf | get SMOLFIRE_UART_IO? | default ""

    # Determine canonical board from SOC field.
    let known_board = match ($soc | str downcase) {
        "bcm2712" => "pi5"
        "rk3588"  => "rk3588"
        _         => null
    }

    if $known_board == null {
        classify-board $soc $board
    } else {
        let base = classify-board $soc $board
        # Allow board.conf to override the UART IO address (RK3588 only).
        if ($uart_io | str length) > 0 and $known_board == "rk3588" {
            $base | update uart $"uart,io,($uart_io)"
        } else {
            $base
        }
    }
}

# ---------------------------------------------------------------------------
# Path 2: /proc/device-tree/model  (Linux DT — cross-platform validation)
# ---------------------------------------------------------------------------

# Probe from Linux FDT model string; returns null if not present.
def probe-from-dt-model []: nothing -> any {
    let path = "/proc/device-tree/model"
    if not ($path | path exists) { return null }

    # The model file may contain a NUL terminator — strip it.
    let model = open --raw $path | str trim | str replace --all "\u{0000}" ""
    classify-board "" $model
}

# ---------------------------------------------------------------------------
# Path 3: FreeBSD sysctl + kenv  (bare-metal FreeBSD without board.conf)
# ---------------------------------------------------------------------------

# Probe via FreeBSD sysctl and kenv; always returns a record (may be unknown).
def probe-from-freebsd-sysctl []: nothing -> record {
    # hw.model exposes the CPU/SoC string.
    # kenv smbios.bios.vendor / .version expose RPi UEFI or edk2-rk35xx strings.
    # External commands are wrapped in try/catch so missing tools return "".
    let hw_model = (
        try { ^sysctl -n hw.model | complete | get stdout | str trim } catch { "" }
    )
    let bios_vendor = (
        try { ^kenv smbios.bios.vendor | complete | get stdout | str trim } catch { "" }
    )
    let chassis_asset = (
        try { ^kenv smbios.chassis.asset | complete | get stdout | str trim } catch { "" }
    )
    let bios_version = (
        try { ^kenv smbios.bios.version | complete | get stdout | str trim } catch { "" }
    )

    # Aggregate all probe strings for classify-board.
    # RPi UEFI advertises "RPi" or "Raspberry" in bios.vendor / bios.version.
    # edk2-rk35xx advertises "Rockchip" or "RK3588" in bios.version.
    let probe_str = $"($hw_model) ($bios_vendor) ($chassis_asset) ($bios_version)"
    let result = classify-board $hw_model $probe_str

    if $result.board != "unknown" {
        return $result
    }

    # Last resort: FreeBSD exposes FDT strings via sysctl on arm64.
    let fdt_compat = (
        try { ^sysctl -n hw.fdt.compatible | complete | get stdout | str trim } catch { "" }
    )
    let fdt_model = (
        try { ^sysctl -n hw.fdt.model | complete | get stdout | str trim } catch { "" }
    )
    classify-board $fdt_compat $fdt_model
}

# ---------------------------------------------------------------------------
# Public export: probe-board
# ---------------------------------------------------------------------------

# Detect the physical board and return a structured record.
# Detection order: board.conf > /proc/device-tree/model > FreeBSD sysctl.
# Never throws; returns {board:"unknown", ...} when nothing matches.
export def probe-board []: nothing -> record {
    let from_conf = probe-from-board-conf
    if $from_conf != null { return $from_conf }

    let from_dt = probe-from-dt-model
    if $from_dt != null { return $from_dt }

    probe-from-freebsd-sysctl
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

# Detect the physical board and print the result.
# Default output is TOML; use --json for JSON.
def main [
    --json  # Emit JSON instead of TOML
] {
    let info = probe-board
    if $json {
        print ($info | to json)
    } else {
        print ($info | to toml)
    }
}
