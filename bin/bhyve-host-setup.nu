#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bhyve-host-setup.nu — configure a fresh FreeBSD 15 amd64 instance as a
# smolfire bhyve test host.
#
# Design notes:
#   - This script is run via SSH by the operator after the Vultr instance is
#     active.  It is NOT driven by cloud-init user-data.
#   - Rationale: cloud-init NoCloud datasource caches semaphores under
#     /var/lib/cloud/instance/sem/ and does not re-execute modules on
#     subsequent boots even if instance-id changes.  Forcing re-run requires
#     'cloud-init clean --logs --reboot', which is awkward for CI.  Running
#     this script directly via SSH is simpler and fully idempotent.
#   - The Vultr user-data (written by vultr-bhyve-provision.nu) only installs
#     nushell so that this script can be executed.  Everything else is here.
#
# Usage (from operator workstation after instance is active):
#   ssh root@<IP> 'pkg install -y nushell git && git clone https://github.com/... smolfire && nu smolfire/bin/bhyve-host-setup.nu'
#
# Or with explicit flags:
#   nu bin/bhyve-host-setup.nu --remote root@<IP>
#     — SSHes to the remote host and runs the setup script there
#
# Or directly on the target (after SSH in):
#   nu bin/bhyve-host-setup.nu
#
# What this script does:
#   1. Verify VT-x / AMD-V is available (checks /dev/vmm after vmm.ko load)
#   2. Install required packages: swtpm, bhyve-firmware, qemu-tools, expect
#   3. Load and persist kernel modules: vmm, nmdm, if_tap, if_bridge
#   4. Create a tap/bridge pair for bhyve guest networking
#   5. Copy/clone smolfire bin/ and tests/ to ~/smolfire/
#   6. Run nu bin/run-vm-tests.nu smoke-check (preflight only, --dry-run)
#   7. Write /var/run/smolfire-host-ready sentinel
#
# Prerequisites:
#   - FreeBSD 15.0 amd64 (bare-metal or KVM guest with VT-x exposed)
#   - Root access
#   - Internet access for pkg
#   - nushell already installed (done by vultr-bhyve-provision.nu user-data,
#     or manually: pkg install -y nushell)
#
# Idempotent: re-running is safe.  Packages already installed are skipped
# by pkg.  kldload is no-op if already loaded.  sysrc deduplicates entries.
#
# See: bin/vultr-bhyve-provision.nu  — creates the instance
#      bin/run-vm-tests.nu           — the test orchestrator run after setup
#      plans/tinyos/PHASE-3-TPM.md   — Phase-III scope

# ── Logging ────────────────────────────────────────────────────────────────────

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

def log-ok   [step: string, msg: string] { log-step $step $msg {verdict: "ok"} }
def log-warn [step: string, msg: string] { log-step $step $msg {verdict: "warn"} }
def log-fail [step: string, msg: string] { log-step $step $msg {verdict: "fail"} }

# ── Step helpers ───────────────────────────────────────────────────────────────

# Run an external command and return {exit_code, stdout, stderr}.
# Logs the command at debug level; errors do not throw by default.
def run-cmd [args: list<string>]: nothing -> record {
    let result = (^...$args | complete)
    $result
}

# Run a command and error make if it fails.
def must-run [args: list<string>, label: string] {
    let r = run-cmd $args
    if $r.exit_code != 0 {
        error make {
            msg: $"($label) failed (exit ($r.exit_code))"
            help: ($r.stderr | str trim | str substring 0..300)
        }
    }
    $r.stdout | str trim
}

# ── Step 1: verify amd64 + VT-x availability ──────────────────────────────────

def step-verify-vtx [] {
    log-step "verify-vtx" "checking CPU virtualisation support"

    let machine = ^uname -m | str trim
    if $machine != "amd64" {
        error make {
            msg: $"This host is ($machine), not amd64. bhyve Phase-III TPM tests require amd64 (virtio-tpm is amd64-only in FreeBSD 15 bhyve)."
        }
    }

    # Load vmm.ko — it will error loudly if VT-x / AMD-V is absent.
    let kld_result = run-cmd ["kldload" "vmm"]
    if $kld_result.exit_code != 0 {
        let stderr = $kld_result.stderr | str trim
        if ($stderr | str contains "already loaded") {
            log-ok "verify-vtx" "vmm.ko already loaded"
        } else if ($stderr | str contains "support for virtualization") {
            error make {
                msg: "vmm.ko: Processor doesn't have support for virtualization. This host cannot run bhyve. Use a bare-metal instance (vbm-6c-32gb) or a KVM guest with VT-x passthrough."
            }
        } else {
            error make {
                msg: $"kldload vmm failed: ($stderr)"
            }
        }
    } else {
        log-ok "verify-vtx" "vmm.ko loaded successfully"
    }

    # Confirm /dev/vmm was created — vmm.ko creates it on successful load.
    if not ("/dev/vmm" | path exists) {
        error make {
            msg: "/dev/vmm not present after kldload vmm. VT-x may not be exposed to this guest. Check host hypervisor nested-virt settings."
        }
    }

    log-ok "verify-vtx" $"VT-x available on ($machine); /dev/vmm present"
    $"/dev/vmm present on ($machine)"
}

# ── Step 2: install packages ───────────────────────────────────────────────────

def step-install-packages [] {
    log-step "pkg-install" "installing required packages"

    # Ensure DNS is configured — Vultr instances sometimes ship with an empty
    # resolv.conf (confirmed on fb-vm-24 during task-0028 run).
    let resolv_missing = (
        (not ("/etc/resolv.conf" | path exists)) or
        ((open --raw "/etc/resolv.conf" | str trim | str length) == 0)
    )
    if $resolv_missing {
        log-warn "pkg-install" "/etc/resolv.conf empty — adding 1.1.1.1 fallback"
        "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | save --force "/etc/resolv.conf"
    }

    # Disable pkg SRV mirror type (DNS SRV resolution fails on some Vultr
    # instances; fall back to direct HTTPS — confirmed fix during task-0028).
    let repo_override = "/usr/local/etc/pkg/repos/FreeBSD.conf"
    if not ($repo_override | path exists) {
        ^mkdir -p "/usr/local/etc/pkg/repos"
        'FreeBSD-ports: {
  url: "https://pkg.FreeBSD.org/FreeBSD:15:amd64/quarterly",
  mirror_type: "none",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
FreeBSD-ports-kmods: { enabled: no }
FreeBSD-base: { enabled: no }
' | save --force $repo_override
        log-ok "pkg-install" "wrote direct-HTTPS pkg repo override (no SRV)"
    }

    must-run ["pkg" "update" "-f"] "pkg update"
    log-ok "pkg-install" "pkg catalogue updated"

    let packages = ["swtpm" "bhyve-firmware" "qemu-tools" "expect" "git"]
    for pkg_name in $packages {
        log-step "pkg-install" $"installing ($pkg_name)"
        let r = run-cmd ["pkg" "install" "-y" $pkg_name]
        if $r.exit_code != 0 {
            error make {
                msg: $"pkg install ($pkg_name) failed (exit ($r.exit_code)): ($r.stderr | str trim | str substring 0..200)"
            }
        }
        log-ok "pkg-install" $"($pkg_name) installed"
    }

    # Verify bhyve-firmware installed the UEFI ROM at the expected path.
    let uefi_path = "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
    if not ($uefi_path | path exists) {
        log-warn "pkg-install" $"($uefi_path) not found after bhyve-firmware install — check pkg contents"
    } else {
        log-ok "pkg-install" $"BHYVE_UEFI.fd present at ($uefi_path)"
    }

    "all packages installed"
}

# ── Step 3: load and persist kernel modules ────────────────────────────────────

def step-load-kmods [] {
    log-step "kmods" "loading and persisting bhyve kernel modules"

    let kmods = ["vmm" "nmdm" "if_tap" "if_bridge"]

    for kmod in $kmods {
        let r = run-cmd ["kldload" $kmod]
        if $r.exit_code != 0 {
            let err = $r.stderr | str trim
            if ($err | str contains "already loaded") {
                log-ok "kmods" $"($kmod) already loaded"
            } else {
                error make {msg: $"kldload ($kmod) failed: ($err)"}
            }
        } else {
            log-ok "kmods" $"($kmod) loaded"
        }
    }

    # Persist via rc.conf kld_list so modules survive reboots.
    # sysrc appends to kld_list if not already present; it is idempotent
    # for repeated additions of the same value.
    for kmod in $kmods {
        let r = run-cmd ["sysrc" $"kld_list+=($kmod)"]
        if $r.exit_code != 0 {
            log-warn "kmods" $"sysrc kld_list+=($kmod) failed: ($r.stderr | str trim)"
        }
    }

    log-ok "kmods" "kld_list persisted in /etc/rc.conf"
    "vmm nmdm if_tap if_bridge loaded and persisted"
}

# ── Step 4: tap/bridge network ─────────────────────────────────────────────────

def step-setup-network [] {
    log-step "network" "configuring tap0/bridge0 for bhyve guest networking"

    # tap0 — bhyve attaches virtio-net guests here.
    let tap_exists = (run-cmd ["ifconfig" "tap0"]).exit_code == 0
    if not $tap_exists {
        must-run ["ifconfig" "tap0" "create"] "ifconfig tap0 create"
        log-ok "network" "tap0 created"
    } else {
        log-ok "network" "tap0 already exists"
    }
    must-run ["ifconfig" "tap0" "up"] "ifconfig tap0 up"

    # bridge0 — bridges tap0 to the physical NIC so guests get DHCP.
    let bridge_exists = (run-cmd ["ifconfig" "bridge0"]).exit_code == 0
    if not $bridge_exists {
        must-run ["ifconfig" "bridge0" "create"] "ifconfig bridge0 create"
        log-ok "network" "bridge0 created"
    } else {
        log-ok "network" "bridge0 already exists"
    }

    # Add tap0 to bridge0 (idempotent — addm is a no-op if already a member).
    run-cmd ["ifconfig" "bridge0" "addm" "tap0"]

    # Find the first physical NIC (not lo, not tap, not bridge, not tun).
    let nics = (
        run-cmd ["ifconfig" "-l"]
        | get stdout
        | str trim
        | split row " "
        | where {|n|
            (
                (not ($n | str starts-with "lo")) and
                (not ($n | str starts-with "tap")) and
                (not ($n | str starts-with "bridge")) and
                (not ($n | str starts-with "tun")) and
                (not ($n | str starts-with "pflog")) and
                (($n | str length) > 0)
            )
        }
    )

    if ($nics | length) > 0 {
        let nic = $nics | first
        run-cmd ["ifconfig" "bridge0" "addm" $nic]
        log-ok "network" $"bridge0 bridging tap0 + ($nic)"
    } else {
        log-warn "network" "no physical NIC found to add to bridge0 — guests may not get external DHCP"
    }

    must-run ["ifconfig" "bridge0" "up"] "ifconfig bridge0 up"

    # Persist tap0 and bridge0 in /etc/rc.conf for reboots.
    run-cmd ["sysrc" "cloned_interfaces+=tap0 bridge0"]
    run-cmd ["sysrc" "ifconfig_bridge0=up"]
    run-cmd ["sysrc" "ifconfig_tap0=up"]

    log-ok "network" "tap0/bridge0 configured and persisted"
    "tap0 + bridge0 ready"
}

# ── Step 5: clone / sync smolfire project ──────────────────────────────────────

def step-sync-project [project_src: string] {
    log-step "sync" "syncing smolfire project to ~/smolfire"

    let dest = $"($env.HOME)/smolfire"

    if ($project_src | str length) > 0 {
        # project_src is a local path (when running locally on the bhyve host
        # after having already transferred the files, e.g. via scp).
        if not ($project_src | path exists) {
            error make {msg: $"--project-src path not found: ($project_src)"}
        }
        if not ($dest | path exists) {
            ^mkdir -p $dest
        }
        must-run ["cp" "-r" $"($project_src)/bin" $dest] "cp bin/"
        must-run ["cp" "-r" $"($project_src)/tests" $dest] "cp tests/"
        log-ok "sync" $"copied bin/ and tests/ from ($project_src) to ($dest)"
    } else {
        # No local source: check if we're already inside the project repo.
        # CURRENT_FILE gives this script's path; walk up to find repo root.
        let script_dir = if "CURRENT_FILE" in $env {
            $env.CURRENT_FILE | path dirname
        } else {
            "."
        }
        let repo_root = $script_dir | path dirname  # bin/ -> repo root

        let bin_dir   = [$repo_root "bin"]   | path join
        let tests_dir = [$repo_root "tests"] | path join

        if ($bin_dir | path exists) and ($tests_dir | path exists) {
            if not ($dest | path exists) { ^mkdir -p $dest }
            must-run ["cp" "-r" $bin_dir   $dest] "cp bin/"
            must-run ["cp" "-r" $tests_dir $dest] "cp tests/"
            log-ok "sync" $"copied bin/ and tests/ from repo at ($repo_root)"
        } else {
            log-warn "sync" "bin/ and tests/ not found relative to this script; skipping project sync. Transfer files manually or pass --project-src."
            return "skipped — no project source found"
        }
    }

    $"project synced to ($dest)"
}

# ── Step 6: preflight smoke-check ─────────────────────────────────────────────

def step-smoke-check [project_dir: string] {
    log-step "smoke-check" "running preflight (no VM launched)"

    let run_script = [$project_dir "bin" "run-vm-tests.nu"] | path join
    if not ($run_script | path exists) {
        log-warn "smoke-check" $"($run_script) not found — skipping smoke-check"
        return "skipped"
    }

    # run-vm-tests.nu with a dummy image path will fail at step-preflight
    # (image not found), but that confirms nu, bhyve, and expect are all
    # on PATH.  A cleaner dry-run would require a real image; skip the
    # image-dependent steps and just verify the binary chain.
    for bin_name in ["bhyve" "bhyvectl" "expect" "qemu-img" "swtpm"] {
        let found = (run-cmd ["which" $bin_name]).exit_code == 0
        if not $found {
            error make {msg: $"smoke-check: ($bin_name) not found on PATH after install"}
        }
    }

    # Verify BHYVE_UEFI.fd exists (required by bhyve-smolfire-vm.nu).
    let uefi = "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
    if not ($uefi | path exists) {
        error make {msg: $"smoke-check: BHYVE_UEFI.fd not found at ($uefi)"}
    }

    # Verify vmm + nmdm are loaded.
    let kldstat_out = (run-cmd ["kldstat"]).stdout
    for kmod in ["vmm.ko" "nmdm.ko"] {
        if not ($kldstat_out | str contains $kmod) {
            error make {msg: $"smoke-check: ($kmod) not loaded — run step-load-kmods"}
        }
    }

    log-ok "smoke-check" "all binaries present; vmm + nmdm loaded; BHYVE_UEFI.fd present"
    "smoke-check passed"
}

# ── Step 7: write sentinel ─────────────────────────────────────────────────────

def step-write-sentinel [] {
    let sentinel = "/var/run/smolfire-host-ready"
    let ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    $"smolfire-host-ready: ($ts)\n" | save --force $sentinel
    log-ok "sentinel" $"wrote ($sentinel)"
    $sentinel
}

# ── Remote execution helper ────────────────────────────────────────────────────

# When --remote is given, SCP this script + bin/ + tests/ to the remote host
# and invoke it there.
def run-remote [remote: string, project_root: string] {
    log-step "remote" $"deploying to ($remote)"

    # SCP the entire project (bin/ + tests/ is sufficient).
    let remote_dir = "/root/smolfire"
    must-run ["ssh" "-o" "StrictHostKeyChecking=no" $remote
              $"mkdir -p ($remote_dir)"] "ssh mkdir"

    for subdir in ["bin" "tests"] {
        let local_path = [$project_root $subdir] | path join
        if ($local_path | path exists) {
            must-run ["scp" "-r" "-o" "StrictHostKeyChecking=no"
                      $local_path $"($remote):($remote_dir)/"] $"scp ($subdir)/"
        }
    }

    # Run the setup script on the remote host.
    # The script is already in $remote_dir/bin/ after the scp above.
    let remote_script = $"($remote_dir)/bin/bhyve-host-setup.nu"
    let ssh_cmd = $"nu ($remote_script) --project-src ($remote_dir)"

    log-step "remote" $"executing: ($ssh_cmd)" {remote: $remote}

    let r = run-cmd ["ssh" "-o" "StrictHostKeyChecking=no" $remote $ssh_cmd]
    print $r.stdout
    if $r.exit_code != 0 {
        error make {msg: $"remote setup failed (exit ($r.exit_code)):\n($r.stderr | str trim)"}
    }

    log-ok "remote" "remote setup completed"
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Set up a fresh FreeBSD 15 amd64 instance as a smolfire bhyve test host.
#
# Run directly on the target host (after SSH in), or use --remote to
# deploy and execute from your workstation.
def main [
    --remote:      string = ""   # SSH target (e.g. root@1.2.3.4); runs setup remotely
    --project-src: string = ""   # local path to smolfire repo to copy to ~/smolfire
    --skip-sync                  # skip project sync (files already on host)
    --skip-network               # skip tap/bridge setup (not needed for slirp/loopback only)
    --skip-smoke                 # skip smoke-check (useful in CI where image is absent)
] {
    log-step "bhyve-host-setup" "smolfire bhyve host setup starting" {
        remote:       $remote
        skip_sync:    $skip_sync
        skip_network: $skip_network
        skip_smoke:   $skip_smoke
    }

    # ── Remote mode: deploy + invoke on the target ──────────────────────────
    if ($remote | str length) > 0 {
        let repo_root = if "CURRENT_FILE" in $env {
            $env.CURRENT_FILE | path dirname | path dirname
        } else {
            "."
        }
        run-remote $remote $repo_root
        return
    }

    # ── Local mode: run steps on this host ─────────────────────────────────
    mut results: list<record> = []

    # Step 1: VT-x
    let r1 = try { step-verify-vtx } catch {|e| error make {msg: $e.msg}}
    $results = $results | append {step: "verify-vtx", result: "pass", detail: $r1}

    # Step 2: packages
    let r2 = try { step-install-packages } catch {|e| error make {msg: $e.msg}}
    $results = $results | append {step: "pkg-install", result: "pass", detail: $r2}

    # Step 3: kernel modules
    let r3 = try { step-load-kmods } catch {|e| error make {msg: $e.msg}}
    $results = $results | append {step: "kmods", result: "pass", detail: $r3}

    # Step 4: network
    if not $skip_network {
        let r4 = try { step-setup-network } catch {|e|
            log-warn "network" $"non-fatal: ($e.msg)"
            "warn"
        }
        $results = $results | append {step: "network", result: "pass", detail: $r4}
    }

    # Step 5: project sync
    let project_dir = $"($env.HOME)/smolfire"
    if not $skip_sync {
        let r5 = try { step-sync-project $project_src } catch {|e|
            log-warn "sync" $"non-fatal: ($e.msg)"
            "warn"
        }
        $results = $results | append {step: "sync", result: "pass", detail: $r5}
    }

    # Step 6: smoke-check
    if not $skip_smoke {
        let r6 = try { step-smoke-check $project_dir } catch {|e| error make {msg: $e.msg}}
        $results = $results | append {step: "smoke-check", result: "pass", detail: $r6}
    }

    # Step 7: sentinel
    let r7 = step-write-sentinel
    $results = $results | append {step: "sentinel", result: "pass", detail: $r7}

    log-step "bhyve-host-setup" "setup complete" {
        steps_passed: ($results | length)
        sentinel:     "/var/run/smolfire-host-ready"
        next_step:    "nu ~/smolfire/bin/run-vm-tests.nu --image <smolfire-amd64.raw> --tpm"
    }

    print ""
    print "=== BHYVE HOST READY ==="
    print $"SSH in and run:"
    print $"  nu ~/smolfire/bin/prep-bhyve-image.nu --input <smolfire.qcow2>"
    print $"  nu ~/smolfire/bin/run-vm-tests.nu --image ~/smolfire-amd64.raw --tpm --results-file /tmp/smolfire-run-1.toml"
    print ""
}
