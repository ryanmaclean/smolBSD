#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/build-smolbsd-image.nu — build a smolBSD amd64 qcow2 image on a Linux host
#                              using a FreeBSD QEMU VM as the build environment.
#
# Why a nested VM?  `make release` / `make vm-image` requires FreeBSD-native tools
# (newfs, mdconfig, etc.).  <kvm-host> (<kvm-host-ip>) is a Linux/KVM host, so we boot a
# stock FreeBSD VM, inject our configs, build inside it, then SCP the artifact out.
#
# Typical call:
#   nu bin/build-smolbsd-image.nu
#   nu bin/build-smolbsd-image.nu --dry-run
#   nu bin/build-smolbsd-image.nu --ssh-port 2242 --output-dir /tmp/artifacts
#
# Flags:
#   --dry-run      Print every command without executing anything
#   --ssh-port     Host port forwarded to build VM :22  (default 2242)
#   --vm-image     Base FreeBSD qcow2 image path        (default ~/smolbsd-tpm-test/FreeBSD-15.1-STABLE-amd64-ufs.qcow2)
#   --output-dir   Directory to receive the built qcow2 (default .)
#
# Prerequisites on the Linux host:
#   - qemu-system-x86_64 with KVM (/dev/kvm)
#   - sshpass (for password-based SSH automation)
#   - The base FreeBSD VM image at --vm-image path
#   - OVMF firmware at /usr/share/qemu/OVMF.fd
#
# See also:
#   bin/build-smolbsd.nu          — runs *inside* the FreeBSD VM (native path)
#   bin/copy-configs-to-freebsd.sh — copies kernel/release configs into /usr/src

# ── Logging ───────────────────────────────────────────────────────────────────

# Emit a timestamped TOML step-log block to stdout.
# Same convention as qemu-smolbsd.nu and the rest of the smolBSD toolchain.
def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Probe whether an absolute path binary exists.
def bin-exists [p: string]: nothing -> bool {
    $p | path exists
}

# Run an external command and return its completed record.
# In dry-run mode, just print the command and return a fake success record.
def run-cmd [args: list<string>, dry_run: bool]: nothing -> record {
    let cmdline = $args | str join " "
    if $dry_run {
        print $"[dry-run] ($cmdline)"
        return {exit_code: 0, stdout: "", stderr: ""}
    }
    log-step "exec" $"running: ($cmdline)" {}
    run-external ($args | first) ...($args | skip 1) | complete
}

# Run an SSH command on the build VM via sshpass.
# Returns the completed record.  Errors are NOT auto-fatal so the caller can
# decide whether a non-zero exit is fatal (build) or expected (VM shutdown).
def ssh-run [
    port:    int
    cmd:     string
    dry_run: bool
    --vm-pass: string = "smolbsd"
] {
    let ssh_opts = [
        "-o" "StrictHostKeyChecking=no"
        "-o" "UserKnownHostsFile=/dev/null"
        "-o" "ConnectTimeout=10"
        "-p" ($port | into string)
        "root@127.0.0.1"
        $cmd
    ]
    let full_args = ["sshpass" "-p" $vm_pass "ssh"] ++ $ssh_opts
    run-cmd $full_args $dry_run
}

# ── Preflight ─────────────────────────────────────────────────────────────────

def preflight [vm_image: string, dry_run: bool] {
    log-step "preflight" "checking host prerequisites" {}

    # qemu-system-x86_64 — accept absolute path or PATH lookup
    let qemu_candidates = [
        "/usr/bin/qemu-system-x86_64"
        "/usr/local/bin/qemu-system-x86_64"
    ]
    let qemu_found = $qemu_candidates | where { |p| $p | path exists } | first?
    let qemu_path = if $qemu_found != null {
        $qemu_found
    } else {
        let r = (^which qemu-system-x86_64 | complete)
        if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
    }

    if ($qemu_path | str length) == 0 {
        error make {msg: "qemu-system-x86_64 not found — install qemu on the Linux host"}
    }
    log-step "preflight" "qemu-system-x86_64 found" {path: $qemu_path}

    # sshpass
    let sshpass_candidates = ["/usr/bin/sshpass" "/usr/local/bin/sshpass"]
    let sshpass_found = $sshpass_candidates | where { |p| $p | path exists } | first?
    if $sshpass_found == null {
        let r = (^which sshpass | complete)
        if $r.exit_code != 0 {
            error make {msg: "sshpass not found — apt-get install sshpass / pkg install sshpass"}
        }
    }
    log-step "preflight" "sshpass found" {}

    # KVM device
    if not ("/dev/kvm" | path exists) {
        log-step "preflight" "WARNING: /dev/kvm not found — build will use TCG (very slow)" {}
    } else {
        log-step "preflight" "/dev/kvm present — KVM acceleration available" {}
    }

    # Base VM image
    if not ($vm_image | path exists) {
        error make {msg: $"Base FreeBSD VM image not found: ($vm_image)\nSet --vm-image to the correct path."}
    }
    log-step "preflight" "base VM image found" {path: $vm_image}

    # OVMF firmware
    let ovmf_path = "/usr/share/qemu/OVMF.fd"
    if not ($ovmf_path | path exists) {
        log-step "preflight" $"WARNING: OVMF firmware missing at ($ovmf_path) — VM may not boot" {}
    } else {
        log-step "preflight" "OVMF firmware found" {path: $ovmf_path}
    }

    log-step "preflight" "all prerequisite checks passed" {}
}

# ── VM lifecycle ──────────────────────────────────────────────────────────────

# Create a qcow2 overlay over the base image so we never modify the original.
def create-overlay [base: string, overlay: string, dry_run: bool] {
    log-step "overlay" "creating qcow2 overlay" {base: $base, overlay: $overlay}
    let args = [
        "qemu-img" "create"
        "-f" "qcow2"
        "-b" $base
        "-F" "qcow2"
        $overlay
    ]
    let r = run-cmd $args $dry_run
    if $r.exit_code != 0 {
        error make {msg: $"qemu-img create overlay failed (exit ($r.exit_code)): ($r.stderr)"}
    }
    log-step "overlay" "overlay created" {overlay: $overlay}
}

# Launch the FreeBSD build VM in the background.
# Returns the PID of the QEMU process.
def start-vm [overlay: string, scratch: string, ssh_port: int, dry_run: bool]: nothing -> int {
    let serial_log = "/tmp/smolbsd-build-serial.log"

    log-step "vm-start" "launching FreeBSD build VM" {
        overlay:    $overlay
        ssh_port:   $ssh_port
        serial_log: $serial_log
        accel:      "kvm"
    }

    let qemu_args = [
        "qemu-system-x86_64"
        "-M"      "q35"
        "-accel"  "kvm"
        "-cpu"    "host"
        "-bios"   "/usr/share/qemu/OVMF.fd"
        "-m"      "8G"
        "-smp"    "8"
        "-drive"  $"file=($overlay),format=qcow2,if=virtio"
        "-drive"  $"file=($scratch),format=qcow2,if=virtio"
        "-nic"    $"user,model=virtio-net-pci,hostfwd=tcp::($ssh_port)-:22"
        "-nographic"
        "-monitor" "none"
        "-serial"  $"file:($serial_log)"
    ]

    if $dry_run {
        print $"[dry-run] ($qemu_args | str join ' ') &"
        print "[dry-run] VM PID: 0 (simulated)"
        return 0
    }

    # Launch detached; Nushell's ^& spawns in background.
    # We use sh -c with & to get a detachable background process.
    let cmdline = $qemu_args | str join " "
    ^/usr/bin/env sh -c $"($cmdline) &\necho $!"
    let pid_str = $env.LAST_EXIT_CODE  # this won't give PID; use pgrep below
    # Give QEMU a moment to fork before we pgrep it
    ^sleep 1

    let pgrep_r = (^pgrep -n -f "qemu-system-x86_64.*($overlay)" | complete)
    let pid = if $pgrep_r.exit_code == 0 {
        $pgrep_r.stdout | str trim | into int
    } else {
        0
    }

    log-step "vm-start" "QEMU started in background" {pid: $pid, serial_log: $serial_log}
    $pid
}

# Poll port 2242 (or --ssh-port) until SSH accepts a connection, or timeout.
# Poll every 5 seconds, timeout after 180 seconds (3 minutes).
def wait-for-ssh [port: int, dry_run: bool] {
    log-step "ssh-wait" "waiting for SSH on build VM" {port: $port, timeout_s: 180}

    if $dry_run {
        print $"[dry-run] would poll 127.0.0.1:($port) every 5s, up to 180s"
        return
    }

    mut elapsed = 0
    loop {
        let nc_r = (^/usr/bin/env sh -c $"nc -z -w 3 127.0.0.1 ($port) 2>/dev/null" | complete)
        if $nc_r.exit_code == 0 {
            log-step "ssh-wait" "SSH port open" {elapsed_s: $elapsed}
            # Give sshd a couple of seconds to finish initializing
            ^sleep 2
            return
        }
        if $elapsed >= 180 {
            error make {msg: $"Timed out waiting for SSH on port ($port) after ($elapsed)s"}
        }
        ^sleep 5
        $elapsed = $elapsed + 5
        log-step "ssh-wait" $"still waiting… ($elapsed)s elapsed" {port: $port}
    }
}

# Stop the QEMU VM by PID.  Graceful SIGTERM first, SIGKILL after 10s.
def stop-vm [pid: int, dry_run: bool] {
    if $pid == 0 {
        log-step "vm-stop" "no PID recorded — skipping stop" {}
        return
    }
    log-step "vm-stop" "stopping build VM" {pid: $pid}
    if $dry_run {
        print $"[dry-run] kill ($pid)"
        return
    }
    # Attempt graceful shutdown via SSH first (fastest)
    let sh_r = (^/usr/bin/env sh -c $"sshpass -p smolbsd ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p 2242 root@127.0.0.1 'poweroff' 2>/dev/null" | complete)
    ^sleep 5
    # Kill the QEMU process if still running
    let kill_r = (^kill $pid 2>/dev/null | complete)
    log-step "vm-stop" "build VM stopped" {pid: $pid}
}

# ── In-VM build steps ─────────────────────────────────────────────────────────

# Run a single build step via SSH.  Errors are fatal unless --allow-fail is set.
def vm-step [
    label:    string
    cmd:      string
    port:     int
    dry_run:  bool
    --allow-fail
] {
    log-step $"vm-($label)" $"in-VM: ($cmd)" {}
    let r = ssh-run $port $cmd $dry_run
    if (not $allow_fail) and $r.exit_code != 0 {
        error make {msg: $"VM step '($label)' failed (exit ($r.exit_code))\ncmd: ($cmd)\nstderr: ($r.stderr)"}
    }
    $r
}

# ── Output artifact collection ────────────────────────────────────────────────

# Find the built qcow2 inside the VM and SCP it to the output directory on the host.
def collect-artifact [port: int, output_dir: string, dry_run: bool]: nothing -> string {
    log-step "collect" "locating built qcow2 inside VM" {}

    # The FreeBSD release Makefile places images under /usr/obj/.../release/vm/
    # Run a find inside the VM to locate the file.
    let find_r = ssh-run $port "find /usr/obj -name '*.qcow2' -type f 2>/dev/null | head -1" $dry_run
    let remote_path = $find_r.stdout | str trim

    if ($remote_path | str length) == 0 {
        if $dry_run {
            print "[dry-run] remote qcow2 path would be discovered here"
            let fake_path = $"($output_dir)/smolbsd-amd64.qcow2"
            print $"[dry-run] sshpass -p smolbsd scp -P ($port) -o StrictHostKeyChecking=no root@127.0.0.1:/usr/obj/.../smolbsd.qcow2 ($fake_path)"
            return $fake_path
        }
        error make {msg: "Could not find built qcow2 inside the VM — check /tmp/smolbsd-build-serial.log for build errors"}
    }

    log-step "collect" "found built artifact" {remote_path: $remote_path}

    let filename = $remote_path | path basename
    let local_path = $"($output_dir)/($filename)"

    # Ensure output dir exists
    if not $dry_run {
        ^mkdir -p $output_dir
    }

    let scp_args = [
        "sshpass" "-p" "smolbsd"
        "scp"
        "-P" ($port | into string)
        "-o" "StrictHostKeyChecking=no"
        "-o" "UserKnownHostsFile=/dev/null"
        $"root@127.0.0.1:($remote_path)"
        $local_path
    ]
    let scp_r = run-cmd $scp_args $dry_run
    if $scp_r.exit_code != 0 {
        error make {msg: $"SCP failed (exit ($scp_r.exit_code)): ($scp_r.stderr)"}
    }

    log-step "collect" "artifact copied to host" {local_path: $local_path}
    $local_path
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Build a smolBSD amd64 qcow2 image on a Linux/KVM host via a FreeBSD build VM.
#
# The script:
#   1. Checks host prerequisites (qemu, sshpass, base image, /dev/kvm)
#   2. Creates a disposable qcow2 overlay of the base VM image
#   3. Starts the FreeBSD VM with KVM acceleration and SSH on --ssh-port
#   4. Waits for SSH (polls every 5s, 3-minute timeout)
#   5. Inside the VM: installs git, clones smolBSD, copies configs, builds
#   6. SCPs the produced qcow2 back to --output-dir
#   7. Stops the VM and logs the artifact path
#
# Use --dry-run to print every command without executing anything.
def main [
    --dry-run                                                        # print commands; do not execute
    --ssh-port:   int    = 2242                                      # host port forwarded to build VM :22
    --vm-image:   string = ""                                        # base FreeBSD qcow2 (default: ~/smolbsd-tpm-test/FreeBSD-15.1-STABLE-amd64-ufs.qcow2)
    --output-dir: string = "."                                       # directory to receive the built artifact
] {
    # Resolve default vm-image using $HOME
    let resolved_vm_image = if ($vm_image | str length) > 0 {
        $vm_image
    } else {
        $"($env.HOME)/smolbsd-tpm-test/FreeBSD-15.1-STABLE-amd64-ufs.qcow2"
    }

    let overlay  = "/tmp/smolbsd-build-vm.qcow2"
    let t_start  = date now

    log-step "start" "build-smolbsd-image starting" {
        dry_run:    $dry_run
        ssh_port:   $ssh_port
        vm_image:   $resolved_vm_image
        output_dir: $output_dir
        overlay:    $overlay
    }

    # ── 1. Preflight ────────────────────────────────────────────────────────
    preflight $resolved_vm_image $dry_run

    # ── 2. Create overlay + obj scratch disk ────────────────────────────────
    # buildworld + 'make packages' write 15-40+ GB under /usr/obj; the stock
    # VM rootfs (~5 GB) cannot hold it (same fix as build-image.yml's 20 GB
    # scratch and build-image-hosted.yml's 40 GB scratch).
    create-overlay $resolved_vm_image $overlay $dry_run
    let scratch = "/tmp/smolbsd-build-scratch.qcow2"
    let scratch_r = run-cmd ["qemu-img" "create" "-f" "qcow2" $scratch "40G"] $dry_run
    if $scratch_r.exit_code != 0 {
        error make {msg: $"qemu-img create scratch failed (exit ($scratch_r.exit_code)): ($scratch_r.stderr)"}
    }

    # ── 3. Start VM ─────────────────────────────────────────────────────────
    mut vm_pid = start-vm $overlay $scratch $ssh_port $dry_run

    # ── 4. Wait for SSH ─────────────────────────────────────────────────────
    wait-for-ssh $ssh_port $dry_run

    # ── 5. In-VM build pipeline ─────────────────────────────────────────────

    # 5a0. Scratch disk -> /usr/obj (vtbd0 = rootfs overlay, vtbd1 = scratch)
    vm-step "scratch-obj" (
        "gpart create -s gpt vtbd1 && gpart add -t freebsd-ufs vtbd1 && " +
        "newfs -U /dev/vtbd1p1 && mkdir -p /usr/obj && mount /dev/vtbd1p1 /usr/obj"
    ) $ssh_port $dry_run

    # 5a. Refresh pkg metadata and install git
    vm-step "pkg-update" "env ASSUME_ALWAYS_YES=yes pkg update -q" $ssh_port $dry_run
    vm-step "pkg-git"    "env ASSUME_ALWAYS_YES=yes pkg install -y git" $ssh_port $dry_run

    # 5b. Clone smolBSD repo
    vm-step "git-clone" "git clone https://github.com/ryanmaclean/smolBSD.git /root/smolBSD" $ssh_port $dry_run

    # 5c. Copy kernel config into the FreeBSD src tree
    vm-step "copy-kernconf" "cp /root/smolBSD/sys/amd64/conf/SMOLBSD /usr/src/sys/amd64/conf/SMOLBSD" $ssh_port $dry_run

    # 5d. Copy cloudware release conf
    vm-step "copy-conf" "cp /root/smolBSD/release/tools/smolbsd-qemu.conf /usr/src/release/tools/smolbsd-qemu.conf" $ssh_port $dry_run

    # 5e. Build world + kernel (long — world ~2-3 h, kernel ~20 min on 8 vCPU KVM)
    # buildworld is REQUIRED: cloudware-release depends on pkgbase-repo, which
    # runs `make -C /usr/src packages` and stages packages from the built world.
    # (The old vm-image path skipped buildworld — but that target was a no-op
    # touch anyway; see FIX-9.)
    log-step "vm-buildworld" "starting world build (this takes ~2-3 h)" {}
    vm-step "buildworld" "make -C /usr/src buildworld -j8" $ssh_port $dry_run
    log-step "vm-buildkernel" "starting kernel build (this takes ~20 min)" {}
    vm-step "buildkernel" "make -C /usr/src buildkernel KERNCONF=SMOLBSD -j8" $ssh_port $dry_run

    # 5f. Build release VM image (long — ~30 min)
    # FIX-9: use cloudware-release with the real ${TYPE}CONF variable
    # (SMOLBSDCONF). The old `vm-image ... CLOUDWARE_CONF=` form never sourced
    # the conf: CLOUDWARE_CONF is not a release Makefile variable and vm-image
    # is a WITH_VMIMAGES-gated target that passes no -c to mk-vmimage.sh.
    log-step "vm-cloudware-release" "starting make cloudware-release (this takes ~30 min)" {}
    vm-step "cloudware-release" (
        "make -C /usr/src/release cloudware-release KERNCONF=SMOLBSD " +
        "WITH_CLOUDWARE=yes CLOUDWARE=smolbsd SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs " +
        "SMOLBSDCONF=/root/smolBSD/release/tools/smolbsd-qemu.conf VMSIZE=2g SWAPSIZE=128m"
    ) $ssh_port $dry_run

    # ── 6. Collect artifact ─────────────────────────────────────────────────
    let artifact = collect-artifact $ssh_port $output_dir $dry_run

    # ── 7. Stop VM ──────────────────────────────────────────────────────────
    stop-vm $vm_pid $dry_run

    # ── Done ────────────────────────────────────────────────────────────────
    let elapsed_secs = (date now) - $t_start | into duration | $in / 1sec | math round
    let h = ($elapsed_secs / 3600 | math floor)
    let m = (($elapsed_secs mod 3600) / 60 | math floor)
    let elapsed_fmt = if $h > 0 { $"($h)h ($m)m" } else { $"($m)m" }

    log-step "done" "build-smolbsd-image complete" {
        artifact:    $artifact
        elapsed:     $elapsed_fmt
        elapsed_s:   $elapsed_secs
    }

    print ""
    print $"Artifact: ($artifact)"
    print $"Elapsed:  ($elapsed_fmt)"
}
