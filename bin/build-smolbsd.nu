#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/build-smolbsd.nu — reproducible smolBSD build pipeline
#
# Encodes all lessons from Phase I builds (2026-04-30 to 2026-05-07).
# Run as root (or with sudo) on a FreeBSD aarch64 or amd64 host.
#
# Hard-won fixes encoded here:
#   FIX-1: /etc/src.conf must exist before buildworld (WITHOUT_SENDMAIL etc.)
#           Without it: freebsd.cf install fails, cascades through 8 make levels.
#   FIX-2: make vm-image must run as root — release chroot requires it;
#           running as builder produces empty pkgbase silently.
#   FIX-3: VMSIZE=2g — sparse image works for smolBSD; 4g needs ~4G disk free.
#   FIX-4: WITHOUT_DEPEND_FILES=yes — prevents bad substitution from bsd.dep.mk
#           in LLVM builds.
#   FIX-5: Disk check before starting — buildworld needs ~50GB in /usr/obj.
#   FIX-6: Pipeline gating — release must not start if buildworld failed.
#   FIX-7: git safe.directory — release make checks git; must be set before release.
#   FIX-8: Kernel obj cleanup after buildworld to free space before vm-image.
#
# Usage:
#   sudo nu bin/build-smolbsd.nu                    # full pipeline
#   sudo nu bin/build-smolbsd.nu --skip-buildworld  # release only (obj already built)
#   sudo nu bin/build-smolbsd.nu --arch aarch64     # explicit arch
#   sudo nu bin/build-smolbsd.nu --check            # preflight checks only

export def main [
    --arch: string = ""              # aarch64 | amd64 (auto-detect if empty)
    --src: string = "/usr/src"       # FreeBSD source tree
    --obj: string = "/usr/obj"       # obj directory
    --kernconf: string = "SMOLBSD"   # kernel config name
    --vmsize: string = "2g"          # qcow2 sparse size (FIX-3: 2g not 4g)
    --jobs: int = 0                  # parallelism (0 = nproc)
    --skip-buildworld                # skip to release (obj already populated)
    --skip-release                   # buildworld+kernel only, no vm-image
    --check                          # preflight only, no build
    --log: string = "/var/tmp/smolbsd-build.log"
] {
    let t_start = (date now)

    # --- Resolve arch ---
    let resolved_arch = if $arch == "" {
        (^uname -m | str trim)
    } else {
        $arch
    }

    # Normalise: uname returns "aarch64" or "amd64" on FreeBSD
    let arch_target = match $resolved_arch {
        "aarch64" | "arm64" => "aarch64",
        "amd64" | "x86_64"  => "amd64",
        _ => {
            error make {msg: $"Unknown arch: ($resolved_arch) — expected aarch64 or amd64"}
        }
    }
    let arch_freebsd = if $arch_target == "aarch64" { "arm64" } else { "amd64" }

    # --- Resolve job count ---
    let nj = if $jobs == 0 {
        let ncpu = (^sysctl -n hw.ncpu | str trim | into int)
        # Leave one core free to keep the system responsive
        [($ncpu - 1) 1] | math max
    } else {
        $jobs
    }

    # --- Resolve conf paths ---
    let kernconf_path = $"($src)/sys/($arch_freebsd)/conf/($kernconf)"
    let conf_name = if $arch_target == "aarch64" {
        "smolbsd-qemu-aarch64.conf"
    } else {
        "smolbsd-qemu.conf"
    }
    let release_conf = $"($src)/release/tools/($conf_name)"

    print $"smolBSD build pipeline starting — arch: ($arch_target)  jobs: ($nj)"
    print $"  src:      ($src)"
    print $"  obj:      ($obj)"
    print $"  kernconf: ($kernconf)"
    print $"  vmsize:   ($vmsize)"
    print $"  log:      ($log)"
    print ""

    # =========================================================================
    # PREFLIGHT
    # =========================================================================
    preflight $src $obj $arch_freebsd $kernconf_path $release_conf $conf_name

    if $check {
        print "Preflight complete — --check mode, no build started."
        return
    }

    # =========================================================================
    # SETUP (always runs before build)
    # =========================================================================
    setup $src

    # =========================================================================
    # STAGE 1: buildworld
    # =========================================================================
    if not $skip_buildworld {
        build_world $src $obj $nj $log $arch_freebsd $arch_target
    } else {
        print "[skip] buildworld (--skip-buildworld)"
    }

    # =========================================================================
    # STAGE 2: buildkernel
    # =========================================================================
    if not $skip_buildworld {
        build_kernel $src $obj $nj $log $kernconf $arch_freebsd $arch_target
    } else {
        print "[skip] buildkernel (--skip-buildworld)"
    }

    # =========================================================================
    # STAGE 3: Kernel obj cleanup (FIX-8: free space before vm-image)
    # =========================================================================
    if not $skip_buildworld and not $skip_release {
        cleanup_kernel_obj $obj $arch_freebsd $arch_target $kernconf
    }

    # =========================================================================
    # STAGE 4: make vm-image
    # =========================================================================
    if not $skip_release {
        build_vm_image $src $obj $nj $log $kernconf $vmsize $release_conf $arch_freebsd $arch_target
    } else {
        print "[skip] vm-image (--skip-release)"
    }

    # =========================================================================
    # DONE
    # =========================================================================
    let t_end = (date now)
    let elapsed_secs = ($t_end - $t_start) / 1sec | math round

    if not $skip_release {
        let qcow2 = find_qcow2 $obj $arch_freebsd $arch_target
        print_summary $arch_target $kernconf $qcow2 $elapsed_secs
    } else {
        let elapsed_fmt = format_elapsed $elapsed_secs
        print $"Build stages complete — elapsed: ($elapsed_fmt)"
    }
}

# =========================================================================
# PREFLIGHT — safe read-only checks (used by --check and before every build)
# =========================================================================
def preflight [
    src: string
    obj: string
    arch_freebsd: string
    kernconf_path: string
    release_conf: string
    conf_name: string
] {
    print "==> Preflight checks"
    mut errors = []
    mut warnings = []

    # CHECK: running as root (FIX-2)
    let euid = (^id -u | str trim | into int)
    if $euid != 0 {
        $errors = ($errors | append "Not running as root. release chroot requires root. Run: sudo nu bin/build-smolbsd.nu")
    } else {
        print "  [ok] running as root"
    }

    # CHECK: /usr/src/Makefile exists
    if not ($"($src)/Makefile" | path exists) {
        $errors = ($errors | append $"($src)/Makefile not found. Clone the source tree first:\n       git clone -b releng/15.0 https://git.freebsd.org/src.git ($src)")
    } else {
        print $"  [ok] ($src)/Makefile exists"
    }

    # CHECK: obj disk space (FIX-5)
    # df -k returns 1K blocks; we need ~50GB = 50_000_000 KiB free
    # Use the mount point if the dir doesn't exist yet (df the parent)
    let df_target = if ($obj | path exists) { $obj } else { "/" }
    let df_result = (do { ^df -k $df_target } | complete)
    let free_kb = if $df_result.exit_code == 0 {
        let df_out = ($df_result.stdout | lines | where { |l| ($l | str trim) != "" } | last | split row -r '\s+')
        try { $df_out | get 3 | into int } catch { 0 }
    } else {
        0
    }
    let free_gb_str = (($free_kb / 1_048_576.0) | math round --precision 1)
    if $free_kb == 0 {
        $warnings = ($warnings | append $"Could not check disk space for ($obj) — verify manually before building.")
        print $"  [warn] could not check disk space for ($obj)"
    } else if $free_kb < 20_000_000 {
        let msg = $"($obj) has only ($free_gb_str) GiB free. Minimum 20 GiB required for buildworld."
        $errors = ($errors | append $msg)
    } else if $free_kb < 50_000_000 {
        let msg = $"($obj) has ($free_gb_str) GiB free — under 50 GiB; build may fail late."
        $warnings = ($warnings | append $msg)
        print $"  [warn] ($obj): ($free_gb_str) GiB free"
    } else {
        print $"  [ok] ($obj): ($free_gb_str) GiB free"
    }

    # CHECK: kernel config exists
    if not ($kernconf_path | path exists) {
        $warnings = ($warnings | append $"Kernel config ($kernconf_path) not found in /usr/src — will install from repo before build.")
        print $"  [warn] kernel config not in src tree — will be installed by setup"
    } else {
        print $"  [ok] ($kernconf_path) present"
    }

    # CHECK: release conf exists
    if not ($release_conf | path exists) {
        $warnings = ($warnings | append $"Release conf ($release_conf) not found — will install from repo.")
        print $"  [warn] ($conf_name) not in src tree — will be installed by setup"
    } else {
        print $"  [ok] ($release_conf) present"
    }

    # CHECK: /etc/src.conf has required keys (FIX-1)
    let src_conf = "/etc/src.conf"
    if ($src_conf | path exists) {
        let content = (open --raw $src_conf)
        if not ($content | str contains "WITHOUT_SENDMAIL") {
            $warnings = ($warnings | append "/etc/src.conf exists but WITHOUT_SENDMAIL not set — setup will add required keys.")
            print "  [warn] /etc/src.conf missing WITHOUT_SENDMAIL — setup will patch"
        } else {
            print "  [ok] /etc/src.conf has required keys"
        }
    } else {
        $warnings = ($warnings | append "/etc/src.conf absent — setup will create it.")
        print "  [warn] /etc/src.conf absent — setup will create it"
    }

    print ""
    if ($warnings | length) > 0 {
        print $"Preflight warnings: ($warnings | length)"
        for w in $warnings { print $"  ! ($w)" }
        print ""
    }
    if ($errors | length) > 0 {
        print $"Preflight ERRORS: ($errors | length)"
        for e in $errors { print $"  ERROR: ($e)" }
        error make {msg: "Preflight failed — fix errors above before building."}
    }
    print "Preflight passed."
    print ""
}

# =========================================================================
# SETUP — writes that must happen before any build stage
# =========================================================================
def setup [src: string] {
    print "==> Setup"

    # FIX-1: Write /etc/src.conf if missing or incomplete
    let src_conf = "/etc/src.conf"
    let required_keys = [
        "WITHOUT_SENDMAIL=yes"
        "WITHOUT_TESTS=yes"
        "WITHOUT_DEBUG_FILES=yes"
        "WITHOUT_DEBUG_LIBRARIES=yes"
        "WITHOUT_GAMES=yes"
        "WITHOUT_EXAMPLES=yes"
        "WITHOUT_DEPEND_FILES=yes"   # FIX-4: prevents bad substitution in LLVM builds
    ]

    if not ($src_conf | path exists) {
        print $"  Writing ($src_conf)"
        ($required_keys | str join "\n") + "\n" | save $src_conf
    } else {
        let existing = (open --raw $src_conf)
        let missing = ($required_keys | where { |k| not ($existing | str contains ($k | split row "=" | first)) })
        if ($missing | length) > 0 {
            print $"  Appending ($missing | length) missing key(s) to ($src_conf)"
            "\n# Added by build-smolbsd.nu\n" + ($missing | str join "\n") + "\n" | save --append $src_conf
        } else {
            print $"  ($src_conf) already complete"
        }
    }

    # FIX-7: git safe.directory — release make checks git
    print $"  Setting git safe.directory for ($src)"
    run_or_fail "git config" [
        "git" "--no-pager" "config" "--global" "--add" "safe.directory" $src
    ] ""

    # Install kernel configs and release conf from repo if missing
    let repo_root = (^git -C $src rev-parse --show-toplevel 2>/dev/null | str trim)
    # We're in the smolBSD repo — kernel configs are checked in here
    let script_dir = ($env.CURRENT_FILE? | default "" | path dirname)
    # Resolve relative to the script location
    let repo_dir = if ($script_dir | str length) > 0 {
        $script_dir | path join ".."
    } else {
        "."
    }

    for arch_pair in [["arm64" "aarch64"] ["amd64" "amd64"]] {
        let af = ($arch_pair | get 0)
        let at = ($arch_pair | get 1)
        let kconf_src = $"($repo_dir)/sys/($af)/conf/SMOLBSD"
        let kconf_dst = $"($src)/sys/($af)/conf/SMOLBSD"
        if ($kconf_src | path exists) and not ($kconf_dst | path exists) {
            print $"  Installing sys/($af)/conf/SMOLBSD into src tree"
            ^cp $kconf_src $kconf_dst
        }
    }

    for conf_pair in [["smolbsd-qemu.conf" ""] ["smolbsd-qemu-aarch64.conf" ""]] {
        let cname = ($conf_pair | get 0)
        let csrc = $"($repo_dir)/release/tools/($cname)"
        let cdst = $"($src)/release/tools/($cname)"
        if ($csrc | path exists) and not ($cdst | path exists) {
            print $"  Installing ($cname) into src tree"
            ^cp $csrc $cdst
        }
    }

    print "  Setup complete."
    print ""
}

# =========================================================================
# STAGE 1: buildworld
# =========================================================================
def build_world [
    src: string
    obj: string
    nj: int
    log: string
    arch_freebsd: string
    arch_target: string
] {
    print "==> Stage 1: buildworld"

    let make_args = (base_make_args $arch_freebsd $arch_target)
    let cmd_args = ["make" "-j" ($nj | into string) "-C" $src "buildworld"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"
    print $"  Log: ($log)"

    run_logged $cmd_args $log "buildworld"
    print "  buildworld complete."
    print ""
}

# =========================================================================
# STAGE 2: buildkernel
# =========================================================================
def build_kernel [
    src: string
    obj: string
    nj: int
    log: string
    kernconf: string
    arch_freebsd: string
    arch_target: string
] {
    print $"==> Stage 2: buildkernel KERNCONF=($kernconf)"

    let make_args = (base_make_args $arch_freebsd $arch_target) ++ [$"KERNCONF=($kernconf)"]
    let cmd_args = ["make" "-j" ($nj | into string) "-C" $src "buildkernel"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"

    run_logged $cmd_args $log "buildkernel"
    print "  buildkernel complete."
    print ""
}

# =========================================================================
# STAGE 3: Kernel obj cleanup (FIX-8)
# =========================================================================
def cleanup_kernel_obj [
    obj: string
    arch_freebsd: string
    arch_target: string
    kernconf: string
] {
    print "==> Stage 3: Kernel obj cleanup (FIX-8 — free space before vm-image)"

    # Path pattern: /usr/obj/usr/src/<arch>.<arch_target>/sys/KERNCONF
    # e.g. /usr/obj/usr/src/arm64.aarch64/sys/SMOLBSD
    let obj_path = $"($obj)/usr/src/($arch_freebsd).($arch_target)/sys/($kernconf)"
    if ($obj_path | path exists) {
        print $"  Removing ($obj_path)"
        ^rm -rf $obj_path
        print "  Kernel obj cleaned — ~4–6 GiB freed."
    } else {
        # Try alternate path layout (older FreeBSD obj layout)
        let alt_path = $"($obj)/($arch_target).($arch_freebsd)/usr/src/sys/($kernconf)"
        if ($alt_path | path exists) {
            print $"  Removing ($alt_path)"
            ^rm -rf $alt_path
            print "  Kernel obj cleaned."
        } else {
            print $"  [warn] kernel obj path not found at ($obj_path) — skipping cleanup"
        }
    }
    print ""
}

# =========================================================================
# STAGE 4: make vm-image
# =========================================================================
def build_vm_image [
    src: string
    obj: string
    nj: int
    log: string
    kernconf: string
    vmsize: string
    release_conf: string
    arch_freebsd: string
    arch_target: string
] {
    print "==> Stage 4: make vm-image"

    # FIX-2: verify still root
    let euid = (^id -u | str trim | into int)
    if $euid != 0 {
        error make {msg: "vm-image must run as root (release chroot requires root). Re-run with sudo."}
    }

    # Disk check before release (need ~3 GiB after buildworld; FIX-5)
    let df_out = (^df -k $obj | lines | last | split row -r '\s+')
    let free_kb = try { $df_out | get 3 | into int } catch { 0 }
    let free_gb = ($free_kb / 1_048_576.0 | math round --precision 1)
    if $free_kb < 3_000_000 {
        error make {msg: $"Insufficient disk space: ($free_gb) GiB free in ($obj). Need at least 3 GiB for vm-image."}
    }
    print $"  Disk: ($free_gb) GiB free in ($obj)"

    # FIX-9: CLOUDWARE_CONF is not a variable the release Makefiles read, and
    # the plain vm-image target never sources a conf (it is also gated behind
    # WITH_VMIMAGES — without it the recipe is a no-op touch). The only path
    # that sources smolbsd-qemu*.conf — and thus runs the pkgbase filter, the
    # size-trim, and sshd enablement — is the cloudware machinery with the
    # real per-type variable ${TYPE}CONF (SMOLBSDCONF for CLOUDWARE=smolbsd).
    # Proven on pop4090 (.planning/phases/03-*, .github/workflows/build-image.yml):
    # cloudware-release generates the cw-smolbsd-ufs-qcow2 target.
    let make_args = (base_make_args $arch_freebsd $arch_target) ++ [
        $"KERNCONF=($kernconf)"
        "WITH_PKGBASE=yes"
        "WITH_CLOUDWARE=yes"
        "CLOUDWARE=smolbsd"
        $"SMOLBSDCONF=($release_conf)"
        "SMOLBSD_FORMAT=qcow2"
        "SMOLBSD_FSLIST=ufs"
        $"VMSIZE=($vmsize)"          # FIX-3: 2g not 4g (conf respects caller)
    ]
    let cmd_args = ["make" "-C" $"($src)/release" "cloudware-release"] ++ $make_args

    print $"  Command: ($cmd_args | str join ' ')"
    print $"  Release conf: ($release_conf)"

    run_logged $cmd_args $log "vm-image"
    print "  vm-image complete."
    print ""
}

# =========================================================================
# HELPERS
# =========================================================================

# Return TARGET/TARGET_ARCH make flags when cross-compiling; empty for native
def base_make_args [arch_freebsd: string arch_target: string] {
    let host_arch = (^uname -m | str trim)
    # If the host and target arch match, native build — no cross flags needed
    # FreeBSD uname -m returns "amd64" or "aarch64"
    let is_native = (
        ($host_arch == "aarch64" and $arch_target == "aarch64") or
        ($host_arch == "amd64"   and $arch_target == "amd64")
    )
    if $is_native {
        []
    } else {
        [$"TARGET=($arch_freebsd)" $"TARGET_ARCH=($arch_target)"]
    }
}

# Run a command, stream to stdout and append to log, error on non-zero exit (FIX-6)
# Strategy: redirect both stdout+stderr to the log file, then tail -f the log so the
# user sees live output. The make commands are long-running; streaming matters.
def run_logged [cmd_args: list<string> log: string stage: string] {
    let cmd = ($cmd_args | first)
    let args = ($cmd_args | skip 1)

    # Append a stage header to the log
    let ts = (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    $"\n=== ($stage) started at ($ts) ===\n" | save --append $log

    print $"  Streaming output to ($log) — run 'tail -f ($log)' in another terminal"

    # Use sh -c to get both stdout+stderr into the log while preserving exit code
    # We use /usr/bin/env sh (POSIX; available on all FreeBSD/macOS)
    let shell_cmd = ($cmd_args | str join ' ')
    let result = (do {
        ^/usr/bin/env sh -c $"($shell_cmd) >> ($log) 2>&1"
    } | complete)

    if $result.exit_code != 0 {
        error make {
            msg: $"Stage '($stage)' failed (exit ($result.exit_code)). See log: ($log)"
        }
    }
}

# Run a command and fail on non-zero exit; used for quick setup commands
def run_or_fail [label: string cmd_args: list<string> _log: string] {
    let cmd = ($cmd_args | first)
    let args = ($cmd_args | skip 1)
    let result = (do { run-external $cmd ...$args } | complete)
    if $result.exit_code != 0 {
        error make {msg: $"($label) failed (exit ($result.exit_code))"}
    }
}

# Find the built qcow2 image
def find_qcow2 [obj: string arch_freebsd: string arch_target: string] {
    # Standard FreeBSD release output paths.
    # cloudware-release (FIX-9) writes to the release objdir root (e.g.
    # vm.ufs.qcow2 / smolbsd.ufs.qcow2); legacy vm-image wrote under release/vm/.
    let candidates = [
        $"($obj)/($arch_freebsd).($arch_target)/usr/src/release"
        $"($obj)/usr/src/($arch_freebsd).($arch_target)/release"
        $"($obj)/usr/src/($arch_freebsd).($arch_target)/release/vm"
        $"($obj)/($arch_target).($arch_freebsd)/usr/src/release/vm"
        $"($obj)/usr/src/release/vm"
    ]

    for dir in $candidates {
        if ($dir | path exists) {
            let found = (ls $dir | where name =~ '\.qcow2$' | get name | first?)
            if $found != null {
                return $found
            }
        }
    }

    # Broader fallback search
    let fallback = (
        do { ^find $obj -name '*.qcow2' -type f 2>/dev/null } |
        complete | get stdout | lines | where { |l| ($l | str trim) != "" } | first?
    )
    $fallback | default "<qcow2 not found — check /usr/obj manually>"
}

def format_elapsed [secs: int] {
    let h = ($secs / 3600 | math floor)
    let m = (($secs mod 3600) / 60 | math floor)
    let s = ($secs mod 60)
    if $h > 0 {
        $"($h)h ($m)m"
    } else if $m > 0 {
        $"($m)m ($s)s"
    } else {
        $"($s)s"
    }
}

def print_summary [arch: string kernconf: string qcow2: string elapsed_secs: int] {
    let elapsed = (format_elapsed $elapsed_secs)
    let size_str = if ($qcow2 | path exists) {
        let sz = (ls $qcow2 | get size | first)
        $sz | into string
    } else {
        "unknown"
    }
    let sha_str = if ($qcow2 | path exists) {
        (^sha256 -q $qcow2 | str trim | str substring 0..16) + "..."
    } else {
        "n/a"
    }
    let qcow2_name = ($qcow2 | path basename)

    print ""
    print "╔══════════════════════════════════════════╗"
    print "║  smolBSD Build Complete                  ║"
    print "╠══════════════════════════════════════════╣"
    print $"║  arch:    ($arch | fill -w 32)║"
    print $"║  kernel:  ($kernconf | fill -w 32)║"
    print $"║  qcow2:   ($qcow2_name | str substring 0..32 | fill -w 32)║"
    print $"║  size:    ($size_str | fill -w 32)║"
    print $"║  sha256:  ($sha_str | fill -w 32)║"
    print $"║  elapsed: ($elapsed | fill -w 32)║"
    print "╚══════════════════════════════════════════╝"
    print ""
    print $"Full path: ($qcow2)"
}
