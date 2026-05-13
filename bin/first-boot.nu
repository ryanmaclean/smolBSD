#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# first-boot.nu — smolBSD first-boot initialisation script.
#
# Invoked once on first boot by rc.local or an rc.d service.
# Idempotent: exits 0 immediately if /etc/smolbsd/.first-boot-done exists.
#
# Actions performed (in order):
#   1. Probe board identity via board-probe.nu (sibling script)
#   2. Set hostname: <board>-<last4MAC>  (e.g. "pi5-a3f2", "rk3588-09bc")
#   3. Expand SSH host keys if any are missing (ssh-keygen -A)
#   4. Touch /etc/smolbsd/.first-boot-done sentinel
#
# Deployment: install both first-boot.nu and board-probe.nu to the same
# directory (default: /usr/local/smolbsd/bin/).  Set SMOLBSD_BIN_DIR in
# the environment if the install path differs.
#
# See: plans/tinyos/PHASE-2-PHYSICAL-BOOT.md
#      release/tools/smolbsd-pi5.conf
#      release/tools/smolbsd-rk3588.conf
#      bin/board-probe.nu

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const SENTINEL     = "/etc/smolbsd/.first-boot-done"
const SENTINEL_DIR = "/etc/smolbsd"
const LOG_TAG      = "smolbsd-first-boot"

# ---------------------------------------------------------------------------
# Locate sibling scripts
# ---------------------------------------------------------------------------

# Resolve the directory that contains this script so sibling scripts
# (board-probe.nu) can be found regardless of cwd.
# Falls back to SMOLBSD_BIN_DIR env var, then /usr/local/smolbsd/bin.
def script-bin-dir []: nothing -> string {
    # SMOLBSD_BIN_DIR override (set by rc.d service or tests)
    if "SMOLBSD_BIN_DIR" in $env {
        return $env.SMOLBSD_BIN_DIR
    }
    # $env.CURRENT_FILE is set by Nushell when running a script file.
    if "CURRENT_FILE" in $env {
        return ($env.CURRENT_FILE | path dirname)
    }
    # Hardcoded install-time fallback.
    "/usr/local/smolbsd/bin"
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# Write a tagged line to stderr (visible on serial console) and syslog
# if logger(1) is available.
def log [level: string, msg: string] {
    let line = $"[($LOG_TAG)] ($level): ($msg)"
    print --stderr $line
    # logger(8) is in FreeBSD base; silently skip if missing.
    try { ^logger -t $LOG_TAG -p $"user.($level)" $msg } catch {}
}

def log-info  [msg: string] { log "info" $msg }
def log-warn  [msg: string] { log "warn" $msg }
def log-error [msg: string] { log "err"  $msg }

# ---------------------------------------------------------------------------
# Step 1: board probe
# ---------------------------------------------------------------------------

# Run board-probe.nu as a subprocess and parse its JSON output.
# Returns an unknown record if board-probe is unavailable or fails.
def get-board-info []: nothing -> record {
    log-info "probing board identity..."

    let probe_script = (script-bin-dir | path join "board-probe.nu")

    let info = if ($probe_script | path exists) {
        try {
            let raw = ^nu --no-config-file $probe_script --json | complete
            if $raw.exit_code == 0 {
                $raw.stdout | from json
            } else {
                log-warn $"board-probe exited ($raw.exit_code): ($raw.stderr | str trim)"
                { board: "unknown", soc: "", uart: "", storage: "", tier: 0 }
            }
        } catch {|e|
            log-warn $"board-probe failed: ($e.msg)"
            { board: "unknown", soc: "", uart: "", storage: "", tier: 0 }
        }
    } else {
        log-warn $"board-probe.nu not found at ($probe_script); using unknown board"
        { board: "unknown", soc: "", uart: "", storage: "", tier: 0 }
    }

    log-info $"board=($info.board) soc=($info.soc) uart=($info.uart) tier=($info.tier)"
    $info
}

# ---------------------------------------------------------------------------
# Step 2: hostname derivation
# ---------------------------------------------------------------------------

# Return the last 4 hex digits of the first non-loopback MAC address.
# Tries FreeBSD ifconfig first, then Linux /sys/class/net.
# Returns "0000" if no MAC can be determined.
def get-mac-suffix []: nothing -> string {
    # FreeBSD: ifconfig -a lists all interfaces with "ether XX:XX:XX:XX:XX:XX"
    let fbsd_mac = (
        try {
            let out = ^ifconfig -a | complete
            if $out.exit_code != 0 { "" } else {
                $out.stdout
                | lines
                | where {|l| $l | str contains "ether "}
                | first
                | str trim
                | split row " "
                | get 1?
                | default ""
            }
        } catch { "" }
    )

    if ($fbsd_mac | str length) >= 4 {
        let hex = $fbsd_mac | str replace --all ":" ""
        return ($hex | str substring (($hex | str length) - 4)..)
    }

    # Linux: /sys/class/net/<iface>/address contains the MAC.
    let linux_mac = (
        try {
            let ifaces = ls /sys/class/net/ | get name
            let non_lo = $ifaces | where {|n| not ($n | str ends-with "/lo") }
            if ($non_lo | length) == 0 { "" } else {
                open --raw ($non_lo | first | path join "address") | str trim
            }
        } catch { "" }
    )

    if ($linux_mac | str length) >= 4 {
        let hex = $linux_mac | str replace --all ":" ""
        return ($hex | str substring (($hex | str length) - 4)..)
    }

    "0000"
}

# Compute and apply the hostname.
# Writes the new hostname to /etc/rc.conf and activates it immediately
# via hostname(1).
def set-hostname [board: string] {
    let suffix   = get-mac-suffix
    let new_host = $"($board)-($suffix)"
    log-info $"setting hostname to ($new_host)"

    let rc_conf = "/etc/rc.conf"
    if ($rc_conf | path exists) {
        let existing = open --raw $rc_conf
        # Check for an existing hostname= line (simple prefix match).
        let has_hostname = ($existing | lines | any {|l| $l | str starts-with "hostname="})
        if $has_hostname {
            # Rewrite rc.conf removing the old hostname= line, then append new one.
            let filtered = (
                $existing
                | lines
                | where {|l| not ($l | str starts-with "hostname=") }
                | str join "\n"
            )
            $"($filtered)\nhostname=\"($new_host)\"\n" | save --force $rc_conf
        } else {
            $"\nhostname=\"($new_host)\"\n" | save --append $rc_conf
        }
    } else {
        log-warn "/etc/rc.conf not found; writing minimal version"
        $"hostname=\"($new_host)\"\n" | save --force $rc_conf
    }

    # Activate immediately — non-fatal (may fail in early-boot chroot env).
    try {
        ^hostname $new_host
    } catch {
        log-warn "hostname(1) failed; hostname will take effect on next boot"
    }

    log-info $"hostname set: ($new_host)"
}

# ---------------------------------------------------------------------------
# Step 3: SSH host key expansion
# ---------------------------------------------------------------------------

# Generate any missing SSH host keys via ssh-keygen -A.
# ssh-keygen -A generates all key types configured in sshd_config that
# are not yet present on disk — safe to call when some keys already exist.
# Skips silently if /etc/ssh is absent or ssh-keygen is not installed.
def ensure-ssh-host-keys [] {
    if not ("/etc/ssh" | path exists) {
        log-warn "/etc/ssh not found; skipping SSH key generation"
        return
    }

    let ed25519_key = "/etc/ssh/ssh_host_ed25519_key"
    let rsa_key     = "/etc/ssh/ssh_host_rsa_key"
    let keys_present = (
        ($ed25519_key | path exists) or ($rsa_key | path exists)
    )

    if $keys_present {
        log-info "SSH host keys already present; skipping generation"
        return
    }

    log-info "generating SSH host keys (ssh-keygen -A)..."
    let result = try {
        ^ssh-keygen -A | complete
    } catch {|e|
        log-warn $"ssh-keygen failed: ($e.msg)"
        return
    }

    if $result.exit_code == 0 {
        log-info "SSH host keys generated successfully"
    } else {
        log-warn $"ssh-keygen exited ($result.exit_code): ($result.stderr | str trim)"
    }
}

# ---------------------------------------------------------------------------
# Step 4: sentinel
# ---------------------------------------------------------------------------

def write-sentinel [] {
    if not ($SENTINEL_DIR | path exists) {
        try { ^mkdir -p $SENTINEL_DIR } catch {
            log-warn $"could not create ($SENTINEL_DIR)"
        }
    }

    let ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    $"first-boot-done: ($ts)\n" | save --force $SENTINEL
    log-info $"sentinel written: ($SENTINEL)"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main [] {
    # Idempotency guard.
    if ($SENTINEL | path exists) {
        log-info "first-boot already completed (sentinel present); exiting"
        exit 0
    }

    log-info "=== smolBSD first-boot initialisation starting ==="

    # 1. Board probe
    let board_info = get-board-info

    # 2. Hostname: use board type, fall back to "smolbsd" for unknown.
    let board_label = if $board_info.board == "unknown" { "smolbsd" } else { $board_info.board }
    set-hostname $board_label

    # 3. SSH host keys
    ensure-ssh-host-keys

    # 4. Sentinel
    write-sentinel

    log-info "=== smolBSD first-boot initialisation complete ==="
    exit 0
}
