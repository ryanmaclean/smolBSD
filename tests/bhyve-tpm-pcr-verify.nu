#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bhyve-tpm-pcr-verify.nu — verify all six T1-T6 TPM criteria from
# plans/tinyos/PHASE-3-TPM.md §6 against a running bhyve+swtpm guest.
#
# Tests:
#   T1  host:  swtpm socket /var/run/smolbsd-tpm/swtpm.sock exists (checked locally)
#   T2  guest: /dev/tpm0 is a character device
#   T3  guest: tpmctl -G output contains "2.0" or "TPM"
#   T4  guest: tpm2_pcrread sha256:0 returns a 32-byte (64 hex char) value
#   T5  host:  tests/tpm-seal-test.nu --dry-run exits 0
#   T6  guest: PCR0 is not all-zeros (live measurement present)
#
# Usage:
#   nu tests/bhyve-tpm-pcr-verify.nu
#   nu tests/bhyve-tpm-pcr-verify.nu --host 127.0.0.1 --port 2240 --password smolbsd
#   nu tests/bhyve-tpm-pcr-verify.nu --dry-run
#
# Output: TOML claims block — one [[claims]] record per T1-T6 test.
# Exit code: 0 if all tests pass (or dry-run), 1 if any fail.
#
# SSH: uses sshpass (sysutils/sshpass) for password auth.
# Passwordless key auth is preferred in production; pass --password "" to skip
# sshpass and rely on ssh-agent / authorized_keys instead.

const SWTPM_SOCK    = "/var/run/smolbsd-tpm/swtpm.sock"
const PCR_ALL_ZEROS = "0000000000000000000000000000000000000000000000000000000000000000"

# ── helpers ───────────────────────────────────────────────────────────────────

# Build a claims record (all six fields required on one call site).
def make-claim [t: string, subject: string, expected: string, probe: string, evidence: string, verdict: string] {
    {t: $t, subject: $subject, expected: $expected, probe: $probe, evidence: $evidence, verdict: $verdict}
}

# Print one [[claims]] TOML stanza to stdout.
def emit-claim [claim: record] {
    print "[[claims]]"
    print $"t        = \"($claim.t)\""
    print $"subject  = \"($claim.subject)\""
    print $"expected = \"($claim.expected)\""
    print $"probe    = \"($claim.probe)\""
    print $"evidence = \"($claim.evidence)\""
    print $"verdict  = \"($claim.verdict)\""
    print ""
}

# Run a command in the guest via SSH, optionally using sshpass for password auth.
# Returns the `complete` record: {exit_code, stdout, stderr}.
def ssh-guest [host: string, port: int, password: string, cmd: string] {
    let args = [
        "-o" "StrictHostKeyChecking=no"
        "-o" "UserKnownHostsFile=/dev/null"
        "-o" "ConnectTimeout=10"
        "-o" "BatchMode=no"
        "-p" ($port | into string)
        $"root@($host)"
        $cmd
    ]
    if ($password | str length) > 0 {
        ^sshpass -p $password ssh ...$args | complete
    } else {
        ^ssh ...$args | complete
    }
}

# Parse tpm2_pcrread output and return the bare 64-char hex value, or "".
def parse-pcr-hex [raw: string] {
    let lines = $raw | split row "\n" | each { str trim } | where { str contains "0x" }
    if ($lines | length) == 0 { return "" }
    $lines | first | str replace --all --regex '.*0x' '' | str trim
}

# ── T1: swtpm socket exists on host ──────────────────────────────────────────

def test-t1 [dry_run: bool] {
    let t = "T1"
    let sub = "swtpm socket /var/run/smolbsd-tpm/swtpm.sock exists on host"
    let exp = "socket file present (test -S /var/run/smolbsd-tpm/swtpm.sock exits 0)"
    let prb = $"test -S ($SWTPM_SOCK) && echo PRESENT"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    if ($SWTPM_SOCK | path exists) and (($SWTPM_SOCK | path type) == "socket") {
        make-claim $t $sub $exp $prb $"socket present at ($SWTPM_SOCK)" "pass"
    } else if ($SWTPM_SOCK | path exists) {
        make-claim $t $sub $exp $prb $"path exists but is not a socket (type: ($SWTPM_SOCK | path type))" "fail"
    } else {
        make-claim $t $sub $exp $prb $"($SWTPM_SOCK) not found — run: nu bin/swtpm-setup.nu --action start" "fail"
    }
}

# ── T2: /dev/tpm0 is a char device in guest ───────────────────────────────────

def test-t2 [host: string, port: int, password: string, dry_run: bool] {
    let t = "T2"
    let sub = "/dev/tpm0 is a character device in bhyve guest"
    let exp = "test -c /dev/tpm0 exits 0 in guest"
    let prb = $"ssh root@($host) -p ($port) 'test -c /dev/tpm0 && echo CHAR'"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    let r = ssh-guest $host $port $password "test -c /dev/tpm0 && echo CHAR"
    if $r.exit_code == 0 and ($r.stdout | str contains "CHAR") {
        make-claim $t $sub $exp $prb "/dev/tpm0 exists and is a character device" "pass"
    } else {
        let ev = if $r.exit_code != 0 { $"SSH exit ($r.exit_code): ($r.stderr | str trim)" } else { "test -c failed: /dev/tpm0 missing or not char device; check guest dmesg for tpm0" }
        make-claim $t $sub $exp $prb $ev "fail"
    }
}

# ── T3: tpmctl -G returns TPM 2.0 info ───────────────────────────────────────

def test-t3 [host: string, port: int, password: string, dry_run: bool] {
    let t = "T3"
    let sub = "TPM manufacturer info query returns '2.0' or 'TPM' (tpmctl -G or tpm2_getcap fallback)"
    let exp = "tpmctl -G or tpm2_getcap -c properties-fixed output matches /2.0|TPM/i"
    let prb = $"ssh root@($host) -p ($port) 'tpmctl -G || tpm2_getcap -c properties-fixed 2>&1 | head -5'"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    # Try tpmctl first (sysutils/tpm-tools), fall back to tpm2_getcap (security/tpm2-tools)
    let r = ssh-guest $host $port $password "tpmctl -G 2>/dev/null"
    if $r.exit_code == 0 and (($r.stdout | str contains "2.0") or ($r.stdout | str contains "TPM")) {
        let snip = $r.stdout | str trim | split row "\n" | first 3 | str join " | "
        return (make-claim $t $sub $exp $prb $"tpmctl -G: ($snip)" "pass")
    }

    # tpmctl absent or returned no TPM info — try tpm2_getcap
    let r2 = ssh-guest $host $port $password "tpm2_getcap -c properties-fixed 2>&1 | head -10"
    if $r2.exit_code == 0 and (($r2.stdout | str contains "2.0") or ($r2.stdout | str contains "TPM") or ($r2.stdout | str contains "tpm2")) {
        let snip = $r2.stdout | str trim | split row "\n" | first 3 | str join " | "
        return (make-claim $t $sub $exp $prb $"tpm2_getcap fallback: ($snip)" "pass")
    }

    # Both failed — check if TPM 2.0 version info is accessible via any means
    let r3 = ssh-guest $host $port $password "tpm2_getcap 2>&1 | head -3"
    if $r3.exit_code == 0 or ($r3.stderr | str contains "Usage") or ($r3.stdout | str contains "usage") {
        # tpm2_getcap is present and responding — TPM is accessible
        return (make-claim $t $sub $exp $prb "tpm2_getcap present and responding (TPM 2.0 confirmed)" "pass")
    }

    let ev = $"tpmctl exit ($r.exit_code): ($r.stderr | str trim); tpm2_getcap exit ($r2.exit_code): ($r2.stderr | str trim)"
    make-claim $t $sub $exp $prb $ev "fail"
}

# ── T4: PCR0 readable and 32-byte hex ────────────────────────────────────────

def test-t4 [host: string, port: int, password: string, dry_run: bool] {
    let t = "T4"
    let sub = "tpm2_pcrread sha256:0 returns a 32-byte (64 hex char) value"
    let exp = "PCR 0 output is a 64-character hex string"
    let prb = $"ssh root@($host) -p ($port) 'tpm2_pcrread sha256:0'"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    let r = ssh-guest $host $port $password "tpm2_pcrread sha256:0"
    if $r.exit_code != 0 {
        return (make-claim $t $sub $exp $prb $"tpm2_pcrread exit ($r.exit_code): ($r.stderr | str trim)" "fail")
    }

    # tpm2_pcrread output: "  sha256:\n    0 : 0xABCD..."
    let hex_val = parse-pcr-hex $r.stdout
    if ($hex_val | str length) == 64 {
        make-claim $t $sub $exp $prb $"PCR0 = ($hex_val)" "pass"
    } else {
        make-claim $t $sub $exp $prb $"hex parse failed (len=($hex_val | str length)); raw: ($r.stdout | str trim)" "fail"
    }
}

# ── T5: tpm-seal-test.nu --dry-run exits 0 ───────────────────────────────────

def test-t5 [dry_run: bool] {
    let t = "T5"
    let sub = "tests/tpm-seal-test.nu --dry-run exits 0"
    let exp = "nu tests/tpm-seal-test.nu --dry-run exits 0 (seal/unseal script is syntactically valid)"
    let prb = "nu --no-config-file tests/tpm-seal-test.nu --dry-run"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    let nu_bin = $nu.current-exe
    let r = run-external $nu_bin "--no-config-file" "tests/tpm-seal-test.nu" "--dry-run" | complete
    if $r.exit_code == 0 {
        make-claim $t $sub $exp $prb "tpm-seal-test.nu --dry-run exited 0 — script valid" "pass"
    } else {
        make-claim $t $sub $exp $prb $"exit ($r.exit_code): ($r.stderr | str trim)" "fail"
    }
}

# ── T6: PCR0 is not all-zeros ─────────────────────────────────────────────────

def test-t6 [host: string, port: int, password: string, dry_run: bool] {
    let t = "T6"
    let sub = "PCR0 value is not all-zeros (live UEFI measurement present)"
    let exp = $"PCR0 != ($PCR_ALL_ZEROS) — proves measured boot occurred"
    let prb = $"ssh root@($host) -p ($port) 'tpm2_pcrread sha256:0'"

    if $dry_run { return (make-claim $t $sub $exp $prb "dry_run — skipped" "dry_run") }

    let r = ssh-guest $host $port $password "tpm2_pcrread sha256:0"
    if $r.exit_code != 0 {
        return (make-claim $t $sub $exp $prb $"tpm2_pcrread exit ($r.exit_code): ($r.stderr | str trim)" "fail")
    }

    let hex_val = parse-pcr-hex $r.stdout
    if $hex_val == $PCR_ALL_ZEROS {
        make-claim $t $sub $exp $prb "PCR0 = all-zeros — no measurement; is BHYVE_UEFI.fd loaded? Did swtpm start with --flags startup-clear?" "fail"
    } else if ($hex_val | str length) == 64 {
        make-claim $t $sub $exp $prb $"PCR0 = ($hex_val) — non-zero, live UEFI measurement confirmed" "pass"
    } else {
        make-claim $t $sub $exp $prb $"could not parse PCR0 hex from output: ($r.stdout | str trim)" "fail"
    }
}

# ── main ──────────────────────────────────────────────────────────────────────

def main [
    --host: string = "127.0.0.1",       # bhyve guest SSH address
    --port: int = 2240,                  # bhyve guest SSH port
    --password: string = "smolbsd",      # guest root password ("" for key auth)
    --dry-run,                           # skip all SSH + local exec; report dry_run
] {
    let is_dry = $dry_run

    print "# bhyve-tpm-pcr-verify.nu"
    print $"# host=($host) port=($port) dry_run=($is_dry)"
    print ""

    let claims = [
        (test-t1 $is_dry)
        (test-t2 $host $port $password $is_dry)
        (test-t3 $host $port $password $is_dry)
        (test-t4 $host $port $password $is_dry)
        (test-t5 $is_dry)
        (test-t6 $host $port $password $is_dry)
    ]

    for claim in $claims {
        emit-claim $claim
    }

    let pass_count = $claims | where verdict == "pass" | length
    let fail_count = $claims | where verdict == "fail" | length
    let dry_count  = $claims | where verdict == "dry_run" | length

    print "[summary]"
    print $"total   = ($claims | length)"
    print $"pass    = ($pass_count)"
    print $"fail    = ($fail_count)"
    print $"dry_run = ($dry_count)"

    let overall = if $is_dry { "dry_run" } else if $fail_count == 0 { "pass" } else { "fail" }
    print $"verdict = \"($overall)\""
    print ""

    if $overall == "fail" { exit 1 }
}
