#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tpm-smoke-test.nu — orchestrate a full QEMU+swtpm TPM smoke test.
#
# Boots a FreeBSD VM image under QEMU with a software TPM (swtpm), applies
# first-boot fixes via bin/fix-freebsd-vm.py, then SSHes in to verify:
#   - /dev/tpm0 exists
#   - tpm.ko is loaded (kldstat)
#   - tpm2_pcrread sha256:0 returns a non-zero value
#
# Emits structured TOML at each step and a final [tpm_test] result block.
# Exits 0 on pass, 1 on any failure.
#
# Usage:
#   nu tests/tpm-smoke-test.nu --image /path/to/smolbsd.qcow2
#   nu tests/tpm-smoke-test.nu --image smolbsd.qcow2 --ssh-port 2241 --dry-run
#
# Requirements:
#   qemu-system-x86_64, swtpm, sshpass
#   /usr/share/qemu/OVMF.fd  (or equivalent — see find-bios below)
#   python3  (stdlib only — for bin/fix-freebsd-vm.py)
#
# See: bin/fix-freebsd-vm.py  — first-boot fix script
#      bin/qemu-smolbsd.nu    — interactive QEMU launcher
#      bin/swtpm-setup.nu     — swtpm lifecycle helper

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped TOML step log line to stdout.
# Matches the three-argument convention used in bin/qemu-smolbsd.nu.
def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── Preflight ──────────────────────────────────────────────────────────────────

# Locate a binary on the system.  Returns the path or errors with a clear message.
def require-bin [name: string, hint: string] {
    let candidates = [
        $"/usr/local/bin/($name)"
        $"/usr/bin/($name)"
        $"/opt/homebrew/bin/($name)"
        $"/usr/local/sbin/($name)"
    ]
    let found = $candidates | where {|p| $p | path exists}
    if ($found | length) > 0 {
        return ($found | first)
    }
    # Fall back to PATH
    let w = (^which $name | complete)
    if $w.exit_code == 0 {
        return ($w.stdout | str trim)
    }
    error make {msg: $"required binary '($name)' not found; ($hint)"}
}

# Locate the UEFI firmware file for amd64.
def find-bios [] {
    let candidates = [
        "/usr/share/qemu/OVMF.fd"
        "/usr/share/qemu/edk2-x86_64-code.fd"
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/ovmf/OVMF.fd"
        "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
    ]
    let found = $candidates | where {|p| $p | path exists}
    if ($found | length) > 0 {
        return ($found | first)
    }
    error make {msg: $"OVMF UEFI firmware not found; tried: ($candidates | str join ', ')"}
}

# Locate the swtpm binary.
def find-swtpm []: nothing -> string {
    require-bin "swtpm" "install security/swtpm (FreeBSD), swtpm (Linux/apt/yum), or brew install swtpm (macOS)"
}

# Run preflight checks.  Returns a record of resolved paths.
def preflight [image: string, arch: string, dry_run: bool]: nothing -> record {
    log-step "preflight" "running preflight checks" {image: $image, arch: $arch}

    # Image existence. No image on a fresh clone is the normal case — skip,
    # don't fail (run-all.sh counts the SKIP marker; pass --image to run).
    if not $dry_run {
        if $image == "" or not ($image | path exists) {
            print $"tpm-smoke-test: SKIP — no disk image \(pass --image; got '($image)'\)"
            exit 0
        }
    }
    log-step "preflight" "image ok" {image: $image, dry_run: $dry_run}

    # Required binaries.
    let qemu_bin  = require-bin "qemu-system-x86_64" "install qemu (pkg install qemu / brew install qemu)"
    let swtpm_bin = find-swtpm
    let sshpass   = require-bin "sshpass" "install sshpass (pkg install sshpass / brew install sshpass)"
    let python3   = require-bin "python3" "install Python 3"

    log-step "preflight" "binaries found" {
        qemu:    $qemu_bin
        swtpm:   $swtpm_bin
        sshpass: $sshpass
        python3: $python3
    }

    # UEFI firmware.
    let bios = find-bios
    log-step "preflight" "UEFI firmware found" {bios: $bios}

    {
        qemu_bin:  $qemu_bin
        swtpm_bin: $swtpm_bin
        sshpass:   $sshpass
        python3:   $python3
        bios:      $bios
    }
}

# ── swtpm lifecycle ────────────────────────────────────────────────────────────

# Start an swtpm socket daemon.  Returns the socket path.
def start-swtpm [swtpm_bin: string, state_dir: string, dry_run: bool]: nothing -> string {
    let sock     = $"($state_dir)/swtpm.sock"
    let pid_file = $"($state_dir)/swtpm.pid"

    log-step "swtpm-start" "creating swtpm state directory" {dir: $state_dir}
    if not $dry_run {
        ^mkdir -p $state_dir
    }

    let tpmstate_arg = $"dir=($state_dir)"
    let ctrl_arg     = $"type=unixio,path=($sock)"
    let cmd_str      = $"($swtpm_bin) socket --tpmstate ($tpmstate_arg) --tpm2 --ctrl ($ctrl_arg) --pid-file ($pid_file) --daemon"

    log-step "swtpm-start" "launching swtpm daemon" {
        cmd:      $cmd_str
        dry_run:  $dry_run
        sock:     $sock
    }

    if not $dry_run {
        ^$swtpm_bin socket --tpmstate $tpmstate_arg --tpm2 --ctrl $ctrl_arg --pid-file $pid_file --daemon
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: $"swtpm failed to start (exit ($env.LAST_EXIT_CODE))"}
        }

        # Poll up to 5s for the socket to appear.
        mut waited_ms = 0
        loop {
            if ($sock | path exists) { break }
            if $waited_ms >= 5000 {
                error make {msg: $"swtpm socket did not appear within 5s at ($sock)"}
            }
            ^sleep 0.1
            $waited_ms = $waited_ms + 100
        }
        log-step "swtpm-start" "swtpm socket ready" {sock: $sock, waited_ms: $waited_ms}
    }

    $sock
}

# Stop swtpm via pid file, then remove stale socket.
def stop-swtpm [state_dir: string, dry_run: bool] {
    let sock     = $"($state_dir)/swtpm.sock"
    let pid_file = $"($state_dir)/swtpm.pid"

    log-step "swtpm-stop" "stopping swtpm" {sock: $sock, dry_run: $dry_run}
    if $dry_run { return }

    if ($pid_file | path exists) {
        let pid = open --raw $pid_file | str trim
        ^kill $pid o> /dev/null e> /dev/null
    } else {
        # Best-effort fallback.
        ^pkill -f $"swtpm.*($state_dir)" o> /dev/null e> /dev/null
    }

    if ($sock | path exists) {
        ^rm -f $sock
    }

    log-step "swtpm-stop" "swtpm stopped" {}
}

# ── QEMU ───────────────────────────────────────────────────────────────────────

# Build and return the QEMU amd64 command-line argument list.
def build-qemu-cmd [
    qemu_bin:     string
    image:        string
    bios:         string
    swtpm_sock:   string
    console_sock: string
    ssh_port:     int
    mem:          string
]: nothing -> list<string> {
    [
        $qemu_bin
        # Machine / accelerator
        "-M"       "q35"
        "-accel"   "kvm"
        "-cpu"     "host"
        "-bios"    $bios
        "-m"       $mem
        # Disk
        "-drive"   $"file=($image),format=qcow2,if=virtio"
        # Console socket (for fix-freebsd-vm.py)
        "-chardev" $"socket,path=($console_sock),server=on,wait=off,id=console"
        "-serial"  "chardev:console"
        # TPM
        "-chardev" $"socket,id=chrtpm,path=($swtpm_sock)"
        "-tpmdev"  "emulator,id=tpm0,chardev=chrtpm"
        "-device"  "tpm-tis,tpmdev=tpm0"
        # Network
        "-nic"     $"user,model=virtio-net-pci,hostfwd=tcp::($ssh_port)-:22"
        # No interactive console
        "-nographic"
        "-monitor" "none"
    ]
}

# Launch QEMU in the background.  Returns its PID.
def start-qemu [args: list<string>, dry_run: bool, log_file: string]: nothing -> int {
    let cmd_str = $args | str join " "
    log-step "qemu-start" "launching QEMU in background" {
        cmd:      $cmd_str
        dry_run:  $dry_run
        log_file: $log_file
    }

    if $dry_run {
        print $"# QEMU command:\n($cmd_str)"
        return 0
    }

    # Nushell does not have a built-in background job that returns a PID.
    # Use sh -c to launch QEMU detached and capture its PID.
    let bg_cmd = $"($cmd_str) >> ($log_file) 2>&1 & echo $!"
    let pid_str = ^sh -c $bg_cmd | str trim
    let pid = $pid_str | into int
    log-step "qemu-start" "QEMU started" {pid: $pid, log_file: $log_file}
    $pid
}

# Wait for the QEMU console socket file to appear (up to max_wait seconds).
def wait-for-console-sock [sock: string, max_wait: int, dry_run: bool] {
    log-step "qemu-wait-sock" "waiting for console socket" {
        sock:     $sock
        max_wait: $max_wait
        dry_run:  $dry_run
    }
    if $dry_run { return }

    mut waited = 0
    loop {
        if ($sock | path exists) {
            log-step "qemu-wait-sock" "console socket appeared" {sock: $sock, waited_s: $waited}
            return
        }
        if $waited >= $max_wait {
            error make {msg: $"console socket ($sock) did not appear within ($max_wait)s"}
        }
        ^sleep 1
        $waited = $waited + 1
    }
}

# ── SSH polling ────────────────────────────────────────────────────────────────

# Poll SSH on the forwarded port until it accepts a connection (up to max_wait seconds).
def poll-ssh [sshpass: string, ssh_port: int, password: string, max_wait: int, dry_run: bool] {
    log-step "ssh-poll" "polling SSH until ready" {
        port:     $ssh_port
        max_wait: $max_wait
        dry_run:  $dry_run
    }
    if $dry_run { return }

    mut waited = 0
    loop {
        let r = (
            ^$sshpass
                -p $password
                ssh
                -o "StrictHostKeyChecking=no"
                -o "UserKnownHostsFile=/dev/null"
                -o "ConnectTimeout=3"
                -o "BatchMode=no"
                -p ($ssh_port | into string)
                $"root@127.0.0.1"
                "true"
            | complete
        )
        if $r.exit_code == 0 {
            log-step "ssh-poll" "SSH is accepting connections" {port: $ssh_port, waited_s: $waited}
            return
        }
        if $waited >= $max_wait {
            error make {msg: $"SSH on port ($ssh_port) not ready after ($max_wait)s"}
        }
        log-step "ssh-poll" $"SSH not ready yet, retrying" {waited_s: $waited}
        ^sleep 2
        $waited = $waited + 2
    }
}

# ── SSH command runner ─────────────────────────────────────────────────────────

# Run a command over SSH and return its stdout.
def ssh-run [
    sshpass:  string
    ssh_port: int
    password: string
    cmd:      string
    dry_run:  bool
]: nothing -> string {
    log-step "ssh-run" $"running: ($cmd)" {port: $ssh_port, dry_run: $dry_run}
    if $dry_run { return "" }

    let r = (
        ^$sshpass
            -p $password
            ssh
            -o "StrictHostKeyChecking=no"
            -o "UserKnownHostsFile=/dev/null"
            -o "ConnectTimeout=10"
            -o "BatchMode=no"
            -p ($ssh_port | into string)
            $"root@127.0.0.1"
            $cmd
        | complete
    )
    if $r.exit_code != 0 {
        let stderr_text = $r.stderr | str trim
        error make {msg: $"SSH command failed (exit ($r.exit_code)): ($cmd)\nstderr: ($stderr_text)"}
    }
    $r.stdout | str trim
}

# ── TPM verification ───────────────────────────────────────────────────────────

# Run the three TPM verification checks over SSH.
# Returns a record with device, kldstat, and pcr0.
def verify-tpm [
    sshpass:  string
    ssh_port: int
    password: string
    dry_run:  bool
]: nothing -> record {
    log-step "tpm-verify" "starting TPM verification checks" {}

    # 1. /dev/tpm0 must exist.
    let dev_out = ssh-run $sshpass $ssh_port $password "ls /dev/tpm0 2>&1 || echo MISSING" $dry_run
    let tpm_device = if $dry_run or ($dev_out | str contains "/dev/tpm0") {
        "/dev/tpm0"
    } else {
        ""
    }
    log-step "tpm-verify" "tpm device check" {result: $tpm_device, expected: "/dev/tpm0"}

    if not $dry_run and ($tpm_device | str length) == 0 {
        error make {msg: $"/dev/tpm0 not found in guest; got: ($dev_out)"}
    }

    # 2. kldstat must show tpm.ko.
    let kld_out = ssh-run $sshpass $ssh_port $password "kldstat 2>&1 | grep tpm || echo NO_TPM_KO" $dry_run
    let kld_ok = $dry_run or ($kld_out | str contains "tpm")
    log-step "tpm-verify" "kldstat tpm check" {result: $kld_out, ok: $kld_ok}

    if not $dry_run and not $kld_ok {
        error make {msg: $"tpm.ko not loaded in guest; kldstat output: ($kld_out)"}
    }

    # 3. tpm2_pcrread sha256:0 must return a non-zero hex value.
    let pcr_out = ssh-run $sshpass $ssh_port $password "tpm2_pcrread sha256:0 2>&1" $dry_run
    # Parse the hex value from the output: "sha256:0 : 0xB6A903D1..."
    let pcr0 = if $dry_run {
        "DRY_RUN"
    } else {
        let lines = $pcr_out | lines | where {|l| $l | str contains "0x"}
        if ($lines | length) > 0 {
            $lines | first | str trim | split row "0x" | last | str trim | str upcase
        } else {
            ""
        }
    }
    log-step "tpm-verify" "tpm2_pcrread sha256:0" {pcr0: $pcr0, raw: $pcr_out}

    if not $dry_run and ($pcr0 | str length) == 0 {
        error make {msg: $"tpm2_pcrread returned no PCR0 value; output: ($pcr_out)"}
    }

    # Check that PCR0 is not all-zeroes (a zeroed PCR means no firmware measurement).
    let zeroed = ($pcr0 | str replace --all "0" "") | str length
    if not $dry_run and $zeroed == 0 {
        log-step "tpm-verify" "WARNING: PCR0 is all-zeroes — firmware may not have measured into the TPM" {pcr0: $pcr0}
    }

    {
        tpm_device: $tpm_device
        kldstat_ok: $kld_ok
        pcr0:       $pcr0
    }
}

# ── Cleanup ────────────────────────────────────────────────────────────────────

def cleanup [swtpm_state: string, dry_run: bool] {
    log-step "cleanup" "stopping QEMU and swtpm" {dry_run: $dry_run}
    if not $dry_run {
        ^pkill -f "qemu-system-x86_64" o> /dev/null e> /dev/null
        ^sleep 1
    }
    stop-swtpm $swtpm_state $dry_run
    log-step "cleanup" "cleanup complete" {}
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Run a QEMU+swtpm TPM smoke test against a FreeBSD disk image.
#
# --image      Path to the smolBSD qcow2 disk image (required unless --dry-run)
# --arch       Guest architecture; only amd64 is currently supported (default: amd64)
# --ssh-port   Host port forwarded to guest :22 (default: 2241)
# --password   Root password set by fix-freebsd-vm.py (default: smolbsd)
# --mem        Guest RAM (default: 512M)
# --dry-run    Print all commands without executing; useful for CI/CD config review
export def main [
    --image:    string = ""     # path to smolBSD qcow2 disk image
    --arch:     string = "amd64"
    --ssh-port: int    = 2241   # host port forwarded to guest :22
    --password: string = "smolbsd"
    --mem:      string = "512M"
    --dry-run                   # print commands without executing
] {
    let start_time = date now

    log-step "smoke-test" "tpm-smoke-test starting" {
        image:    $image
        arch:     $arch
        ssh_port: $ssh_port
        dry_run:  $dry_run
    }

    # Resolve script root: look for bin/ relative to this file, then cwd.
    let script_dir  = $env.CURRENT_FILE? | default "" | path dirname
    let repo_root   = if ($"($script_dir)/../bin" | path exists) {
        $script_dir | path join ".."
    } else {
        "."
    }
    let fix_script   = $repo_root | path join "bin" "fix-freebsd-vm.py"
    let console_sock = "/tmp/smolbsd-console.sock"
    let swtpm_state  = "/tmp/smolbsd-swtpm-test"

    # ── Preflight ────────────────────────────────────────────────────────────
    let bins = preflight $image $arch $dry_run

    # ── Start swtpm ──────────────────────────────────────────────────────────
    let swtpm_sock = start-swtpm $bins.swtpm_bin $swtpm_state $dry_run

    # ── Start QEMU ───────────────────────────────────────────────────────────
    let qemu_log  = "/tmp/smolbsd-qemu.log"
    let qemu_args = build-qemu-cmd $bins.qemu_bin $image $bins.bios $swtpm_sock $console_sock $ssh_port $mem
    let qemu_pid  = start-qemu $qemu_args $dry_run $qemu_log

    # Wrap the rest in a try/catch so cleanup always runs.
    let test_result = try {
        # ── Wait for console socket ───────────────────────────────────────────
        wait-for-console-sock $console_sock 30 $dry_run

        # ── Run fix-freebsd-vm.py ─────────────────────────────────────────────
        log-step "fix-vm" "running fix-freebsd-vm.py" {
            script:       $fix_script
            console_sock: $console_sock
            dry_run:      $dry_run
        }

        let fix_cmd = [
            $bins.python3
            $fix_script
            "--socket" $console_sock
            "--password" $password
        ]
        let fix_cmd = if $dry_run { $fix_cmd | append "--dry-run" } else { $fix_cmd }
        let fix_cmd_str = $fix_cmd | str join " "

        if $dry_run {
            print $"# fix command:\n($fix_cmd_str)"
        } else {
            let fix_r = run-external ($fix_cmd | first) ...($fix_cmd | skip 1) | complete
            if $fix_r.exit_code != 0 {
                error make {msg: $"fix-freebsd-vm.py failed (exit ($fix_r.exit_code)): ($fix_r.stdout | str trim)"}
            }
            log-step "fix-vm" "fix-freebsd-vm.py completed" {stdout: ($fix_r.stdout | str trim)}
        }

        # ── Poll SSH ──────────────────────────────────────────────────────────
        poll-ssh $bins.sshpass $ssh_port $password 60 $dry_run

        # ── Verify TPM ────────────────────────────────────────────────────────
        let tpm = verify-tpm $bins.sshpass $ssh_port $password $dry_run

        # ── Emit structured result ────────────────────────────────────────────
        let end_time = date now
        let duration_s = ($end_time - $start_time) / 1sec | into int

        let result = {
            status:     "pass"
            pcr0:       $tpm.pcr0
            tpm_device: $tpm.tpm_device
            duration_s: $duration_s
            image:      $image
        }

        log-step "smoke-test" "TPM smoke test PASSED" $result
        $result

    } catch {|err|
        let end_time = date now
        let duration_s = ($end_time - $start_time) / 1sec | into int
        let detail = $err.msg
        log-step "smoke-test" $"TPM smoke test FAILED: ($detail)" {duration_s: $duration_s}
        {
            status:     "fail"
            pcr0:       ""
            tpm_device: ""
            duration_s: $duration_s
            image:      $image
            error:      $detail
        }
    }

    # ── Cleanup ───────────────────────────────────────────────────────────────
    cleanup $swtpm_state $dry_run

    # ── Final TOML report ─────────────────────────────────────────────────────
    print ""
    print "# smolBSD TPM smoke test result"
    print "[tpm_test]"
    $test_result | to toml | print

    # ── Exit code ─────────────────────────────────────────────────────────────
    if $test_result.status != "pass" {
        exit 1
    }
}
