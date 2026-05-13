#!/usr/bin/env nu
# tests/sd-write.nu
# Write a smolBSD raw image to an SD card with a removable-device safety check.
#
# Materialized from plans/tinyos/PHASE-2-PHYSICAL-BOOT.md §4.2
# Authoring chain: planner@smolbsd.local <task-0023.coord@smolbsd.local>
#
# Usage:
#   nu tests/sd-write.nu --image smolbsd-aarch64-pi5.raw --device /dev/rdisk4
#   nu tests/sd-write.nu --image smolbsd-aarch64-rk3588.raw --device /dev/rdisk4 --bs 4m
#
# Safety rules:
#   - Refuses to write to any device that is not detected as removable
#   - On macOS: checks `diskutil info` for "Removable Media: Yes" or "Protocol: USB"
#   - On FreeBSD: checks /dev/diskN via camcontrol or geom for removable flag
#   - Requires explicit --yes flag to skip the final confirmation prompt
#   - Never writes to a device path that does not begin with /dev/
#
# Requirements: dd (BSD dd, supports bs= and status=progress or similar)
#               diskutil (macOS) or camcontrol/geom (FreeBSD)
#
# Exit codes: 0 = success, 1 = safety check failed or write error

def main [
    --image: string,        # Path to raw image file (required)
    --device: string,       # Target device node, e.g. /dev/rdisk4 or /dev/rdisk4 (required)
    --bs: string = "4m",    # dd block size (default: 4m)
    --yes,                  # Skip confirmation prompt (use in CI only)
] {
    # --- Validate inputs ---

    if ($image | is-empty) {
        error make { msg: "--image is required (path to raw image file)" }
    }
    if ($device | is-empty) {
        error make { msg: "--device is required (e.g. /dev/rdisk4)" }
    }

    # Enforce /dev/ prefix as a basic sanity guard
    if not ($device | str starts-with "/dev/") {
        error make { msg: $"SAFETY: device must be a /dev/ path, got: ($device)" }
    }

    # Verify image file exists and is non-empty
    if not ($image | path exists) {
        error make { msg: $"Image file not found: ($image)" }
    }
    let image_size = (ls $image | get size | first)
    if $image_size == 0 {
        error make { msg: $"Image file is empty: ($image)" }
    }

    # Verify device node exists
    if not ($device | path exists) {
        error make { msg: $"Device not found: ($device) — is the SD card inserted?" }
    }

    print $"IMAGE:  ($image) (($image_size))"
    print $"DEVICE: ($device)"
    print $"BS:     ($bs)"

    # --- Removable-device safety check ---

    let platform = $nu.os-info.name
    let is_removable = (check_removable $device $platform)

    if not $is_removable {
        error make {
            msg: $"SAFETY ABORT: ($device) does not appear to be a removable device.\nVerify the device with `diskutil list` (macOS) or `geom disk list` (FreeBSD) and pass the correct --device."
        }
    }

    print "SAFETY CHECK: device is removable — OK"

    # --- Confirmation prompt ---

    if not $yes {
        print ""
        print $"WARNING: About to write ($image_size) to ($device)."
        print "This will ERASE ALL DATA on the target device."
        print ""
        let answer = (input "Type YES to continue, anything else to abort: ")
        if $answer != "YES" {
            print "Aborted."
            exit 0
        }
    }

    # --- Unmount device before writing (macOS) ---

    if $platform == "macos" {
        # Strip leading 'r' from rdiskN to get diskN for diskutil
        let disk_node = ($device | str replace --regex "^/dev/r" "/dev/")
        print $"Unmounting ($disk_node) ..."
        let um_result = (^diskutil unmountDisk $disk_node | complete)
        if $um_result.exit_code != 0 {
            # Non-fatal: some partitions may already be unmounted
            print $"Note: diskutil unmountDisk returned ($um_result.exit_code) — ($um_result.stderr)"
        }
    }

    # --- Write image with dd ---

    print ""
    print $"Writing ($image) -> ($device) ..."
    print "(this may take several minutes)"

    # dd flags:
    #   if=   input file (image)
    #   of=   output file (raw device)
    #   bs=   block size (default 4m — efficient for SD writes)
    # macOS dd does not support status=progress; use BSD dd conv=sync,noerror
    # FreeBSD dd supports status=progress
    if $platform == "macos" {
        let result = (^dd if=$image of=$device bs=$bs conv=sync,noerror | complete)
        if $result.exit_code != 0 {
            error make { msg: $"dd failed with exit ($result.exit_code):\n($result.stderr)" }
        }
    } else {
        # FreeBSD / Linux
        let result = (^dd if=$image of=$device bs=$bs conv=sync,noerror status=progress | complete)
        if $result.exit_code != 0 {
            error make { msg: $"dd failed with exit ($result.exit_code):\n($result.stderr)" }
        }
    }

    # Flush write buffers
    ^sync

    print ""
    print "WRITE COMPLETE"
    print $"Image ($image) written to ($device)."
    print "Remove the SD card safely before inserting into the board."
}

# Check whether a device is removable.
# Returns true if removable, false if not (or if check is inconclusive — conservative = false).
def check_removable [device: string, platform: string] {
    if $platform == "macos" {
        check_removable_macos $device
    } else if $platform == "linux" or $platform == "freebsd" {
        check_removable_bsd $device
    } else {
        # Unknown platform — refuse to write
        print $"WARNING: unknown platform '($platform)' — cannot verify removability"
        false
    }
}

# macOS removable check using diskutil info
def check_removable_macos [device: string] {
    # Strip leading 'r' for diskutil (rdisk4 -> disk4)
    let disk_node = ($device | str replace --regex "^/dev/r" "/dev/")
    let result = (^diskutil info $disk_node | complete)
    if $result.exit_code != 0 {
        print $"WARNING: diskutil info failed for ($disk_node)"
        return false
    }
    let info = $result.stdout

    # Accept as removable if any of these markers are present:
    #   "Removable Media: Yes" — classic removable flag
    #   "Protocol: USB"        — USB mass storage (SD card readers)
    #   "Protocol: SD"         — built-in SD slot (e.g. MacBook SD reader)
    let removable = (
        ($info | str contains "Removable Media: Yes") or
        ($info | str contains "Protocol:        USB") or
        ($info | str contains "Protocol:        SD") or
        ($info | str contains "Protocol: USB") or
        ($info | str contains "Protocol: SD")
    )
    $removable
}

# FreeBSD / Linux removable check
def check_removable_bsd [device: string] {
    # Derive base device name (strip /dev/ prefix and 'r' prefix for raw nodes)
    let base = ($device | str replace --regex "^/dev/r?" "" | str replace --regex "[sp][0-9]+$" "")

    let platform = $nu.os-info.name

    if $platform == "freebsd" {
        # Try geom disk list first — shows "descr" with USB/SD info
        let geom_result = (^geom disk list $base | complete)
        if $geom_result.exit_code == 0 {
            let info = $geom_result.stdout
            # FreeBSD geom shows "Removable: Yes" for SD/USB
            if ($info | str contains "Removable: Yes") {
                return true
            }
            # If geom shows USB bus, treat as removable
            if ($info | str contains "USB") {
                return true
            }
        }
        # Fallback: camcontrol devlist
        let cam_result = (^camcontrol devlist | complete)
        if $cam_result.exit_code == 0 {
            if ($cam_result.stdout | str contains $base) {
                # Conservative: if the device appears in camcontrol it might be a
                # SCSI/USB device — still require explicit removable marker
                # Return false to stay safe; user must use --yes after manual verify
            }
        }
        false
    } else {
        # Linux: check /sys/block/<dev>/removable
        let sys_path = $"/sys/block/($base)/removable"
        if ($sys_path | path exists) {
            let val = (open --raw $sys_path | str trim)
            $val == "1"
        } else {
            false
        }
    }
}
