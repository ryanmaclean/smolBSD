#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/vm-execute.nu — execute commands inside a smolBSD VM, return reply
#
# This is the bridge between the coordinator and a real running VM.
# Boots the qcow2 via QEMU, runs commands via SSH, captures output,
# shuts down cleanly, and returns a structured reply record.
#
# Usage from another module:
#   use vm-execute.nu [run-vm-task]
#   let reply = run-vm-task "task-0042" "build/FreeBSD-15-aarch64-smolbsd.qcow2" ["uname -a"]

# Run a list of commands inside a smolBSD VM and return structured output.
# Returns: {verdict: "pass"|"fail", boot_sec: int, outputs: list<{cmd, stdout, stderr, exit_code}>, error?: string}
export def run-vm-task [
    task_id:    string          # unique task identifier (used for temp file names)
    image_path: string          # path to qcow2 image
    commands:   list<string>    # commands to run inside the VM
    --arch:     string = "arm64"       # arm64 | amd64
    --port:     int    = 2234          # SSH hostfwd port (avoid collisions)
    --timeout:  int    = 90            # boot timeout in seconds
    --user:     string = "root"        # VM SSH user
    --password: string = "smolbsd"    # VM root password
    --use-overlay                      # mount thin overlay (keeps base image clean)
] {
    # Locate QEMU binary
    let qemu = if $arch == "arm64" {
        "/opt/homebrew/bin/qemu-system-aarch64"
    } else {
        "/opt/homebrew/bin/qemu-system-x86_64"
    }
    if not ($qemu | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: $"qemu not found: ($qemu)"}
    }

    # Locate sshpass binary
    let sshpass_bin = "/opt/homebrew/bin/sshpass"
    if not ($sshpass_bin | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: "sshpass not found at /opt/homebrew/bin/sshpass — run: brew install hudochenkov/sshpass/sshpass"}
    }

    let abs_image = $image_path | path expand
    if not ($abs_image | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: $"image not found: ($abs_image)"}
    }

    # BIOS args (aarch64 needs EDK2 firmware)
    let bios_args = if $arch == "arm64" {
        let bios = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        if ($bios | path exists) { ["-bios" $bios] } else { [] }
    } else { [] }

    # Machine/CPU args
    let machine_args = if $arch == "arm64" {
        ["-machine" "virt,accel=hvf" "-cpu" "host"]
    } else {
        ["-machine" "q35" "-cpu" "qemu64"]
    }

    # Create overlay if requested (protects the base image from writes)
    let actual_image = if $use_overlay {
        let overlay = $"/tmp/smolbsd-($task_id)-overlay.qcow2"
        let r = (^/opt/homebrew/bin/qemu-img create -f qcow2 -F qcow2 -b $abs_image $overlay) | complete
        if $r.exit_code != 0 {
            return {verdict: "fail", boot_sec: 0, outputs: [], error: $"qemu-img overlay failed: ($r.stderr)"}
        }
        $overlay
    } else {
        $abs_image
    }

    let log_path = $"/tmp/vm-execute-($task_id).log"
    let pid_path = $"/tmp/vm-execute-($task_id).pid"

    # Clean up any leftover PID file from a previous run
    if ($pid_path | path exists) { rm -f $pid_path }

    # Spawn QEMU in background (daemonize writes PID to pid_path)
    let spawn_result = (^$qemu
        ...$machine_args
        ...$bios_args
        -m 256M -smp 2
        -drive $"file=($actual_image),format=qcow2,if=virtio"
        -nic $"user,model=virtio-net-pci,hostfwd=tcp::($port)-:22"
        -nographic
        -daemonize
        -pidfile $pid_path
        -serial $"file:($log_path)"
    ) | complete

    if $spawn_result.exit_code != 0 {
        if $use_overlay { rm -f $actual_image }
        return {verdict: "fail", boot_sec: 0, outputs: [], error: $"qemu spawn failed: ($spawn_result.stderr | str trim)"}
    }

    # Read the QEMU PID
    let qemu_pid = if ($pid_path | path exists) {
        try { open --raw $pid_path | str trim | into int } catch { 0 }
    } else { 0 }

    if $qemu_pid == 0 {
        if $use_overlay { rm -f $actual_image }
        return {verdict: "fail", boot_sec: 0, outputs: [], error: "qemu started but PID file missing"}
    }

    # Poll SSH port until it responds (VM boot)
    let t0 = (date now | into int) / 1_000_000_000
    mut ssh_ready = false
    mut elapsed = 0
    while $elapsed < $timeout {
        sleep 2sec
        let probe = (^nc -z -w 1 localhost $port) | complete
        if $probe.exit_code == 0 {
            $ssh_ready = true
            break
        }
        $elapsed = ((date now | into int) / 1_000_000_000) - $t0
    }
    let boot_sec = ((date now | into int) / 1_000_000_000) - $t0

    if not $ssh_ready {
        ^kill $qemu_pid
        if $use_overlay { rm -f $actual_image }
        rm -f $pid_path
        return {verdict: "fail", boot_sec: $boot_sec, outputs: [], error: $"SSH not reachable within ($timeout)s"}
    }

    # Run each command via SSH
    mut outputs = []
    mut all_ok = true
    for cmd in $commands {
        let ssh_result = (^$sshpass_bin -p $password ssh
            -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null
            -o LogLevel=ERROR
            -p $port
            $"($user)@localhost"
            $cmd
        ) | complete
        $outputs = $outputs | append {
            cmd:       $cmd
            stdout:    ($ssh_result.stdout | str trim)
            stderr:    ($ssh_result.stderr | str trim)
            exit_code: $ssh_result.exit_code
        }
        if $ssh_result.exit_code != 0 { $all_ok = false }
    }

    # Graceful shutdown
    let _ = (^$sshpass_bin -p $password ssh
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -p $port
        $"($user)@localhost"
        "shutdown -p now"
    ) | complete
    sleep 3sec

    # Force-kill if still alive
    if ($pid_path | path exists) {
        let still_pid = try { open --raw $pid_path | str trim | into int } catch { 0 }
        if $still_pid != 0 {
            let ps_check = (^ps -p $still_pid) | complete
            if $ps_check.exit_code == 0 {
                ^kill $still_pid
            }
        }
    }

    # Cleanup temp files
    rm -f $pid_path
    if $use_overlay { rm -f $actual_image }

    {
        verdict:  (if $all_ok { "pass" } else { "fail" })
        boot_sec: $boot_sec
        outputs:  $outputs
    }
}
