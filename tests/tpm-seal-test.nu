#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tpm-seal-test.nu — host-side TPM 2.0 seal/unseal round-trip test.
#
# Demonstrates TPM sealing on the bhyve host using tpm2-tools.
# Creates a primary key, seals a test secret bound to PCR 0 + PCR 7,
# unseals it, and verifies the plaintext matches.
#
# Reports pass/fail in TOML format compatible with the smolBSD claims convention.
#
# Usage:
#   nu tests/tpm-seal-test.nu
#   nu tests/tpm-seal-test.nu --dry-run       # print commands, do not execute
#   nu tests/tpm-seal-test.nu --tcti "device:/dev/tpm0"
#
# Requirements (unless --dry-run):
#   security/tpm2-tools (FreeBSD port) — provides tpm2_createprimary,
#   tpm2_create, tpm2_load, tpm2_unseal, tpm2_pcrread.
#
# PCR policy binds to PCR 0 (firmware) + PCR 7 (Secure Boot state).
# The secret can only be unsealed while those PCR values remain unchanged.

# Emit a structured TOML log-step line to stdout.
def log-step [step: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, step: $step} | merge $payload
    $row | to toml | print
    print "---"
}

# Run an external command, log it, and return its stdout as a string.
# In dry-run mode, just print the command and return an empty string.
def run-cmd [label: string, args: list<string>, dry_run: bool] {
    let cmd_str = $args | str join " "
    log-step $label {cmd: $cmd_str, dry_run: $dry_run}
    if $dry_run {
        return ""
    }
    let result = try {
        run-external ($args | first) ...($args | skip 1) | complete
    } catch {|err|
        error make {msg: $"command failed: ($cmd_str)\nerror: ($err.msg)"}
    }
    if $result.exit_code != 0 {
        let stderr_text = $result.stderr | str trim
        error make {msg: $"command exited ($result.exit_code): ($cmd_str)\nstderr: ($stderr_text)"}
    }
    $result.stdout | str trim
}

# Emit the final TOML claims block consumed by the proveryay hook.
def emit-claims [verdict: string, detail: record] {
    let ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let claims = {
        ts:      $ts
        test:    "tpm-seal-test"
        verdict: $verdict
        detail:  $detail
    }
    print ""
    print "# smolBSD TPM seal/unseal result"
    $claims | to toml | print
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Run a TPM 2.0 seal/unseal round-trip test on the bhyve host.
#
# --dry-run   print tpm2-tools commands without executing them
# --tcti      TPM command transmission interface (default: device:/dev/tpm0)
# --work-dir  scratch directory for key + blob files (default: /tmp/smolbsd-tpm-seal-test)
export def main [
    --dry-run               # print commands without executing (for hosts without tpm2-tools)
    --tcti:    string = "device:/dev/tpm0"           # TCTI string passed to tpm2-tools
    --work-dir: string = "/tmp/smolbsd-tpm-seal-test" # scratch dir for keys and blobs
] {
    let secret_text = "smolbsd-seal-test"

    log-step "tpm_seal_test_start" {
        dry_run:  $dry_run
        tcti:     $tcti
        work_dir: $work_dir
        secret:   $secret_text
        pcrs:     "0+7"
    }

    # ── Prepare scratch directory ─────────────────────────────────────────────

    if not $dry_run {
        if ($work_dir | path exists) {
            ^rm -rf $work_dir
        }
        ^mkdir -p $work_dir
        log-step "tpm_seal_workdir_created" {path: $work_dir}
    } else {
        log-step "tpm_seal_workdir_skip" {note: "dry-run; skipping mkdir"}
    }

    let primary_ctx  = [$work_dir, "primary.ctx"]  | path join
    let policy_pcr   = [$work_dir, "pcr.policy"]   | path join
    let seal_pub     = [$work_dir, "seal.pub"]      | path join
    let seal_priv    = [$work_dir, "seal.priv"]     | path join
    let seal_ctx     = [$work_dir, "seal.ctx"]      | path join
    let secret_file  = [$work_dir, "secret.txt"]    | path join
    let unseal_file  = [$work_dir, "unsealed.txt"]  | path join

    # ── Step 1: Write secret to a temp file ──────────────────────────────────

    log-step "tpm_seal_step1_write_secret" {file: $secret_file, value: $secret_text}
    if not $dry_run {
        $secret_text | save --force $secret_file
    }

    # ── Step 2: Create primary key in the Owner hierarchy ────────────────────
    #
    # tpm2_createprimary -C o -g sha256 -G ecc -c <ctx>

    run-cmd "tpm_seal_step2_createprimary" [
        "tpm2_createprimary"
        "-T" $tcti
        "-C" "o"
        "-g" "sha256"
        "-G" "ecc"
        "-c" $primary_ctx
    ] $dry_run

    # ── Step 3: Generate PCR policy (SHA-256 bank, PCR 0 and PCR 7) ──────────
    #
    # tpm2_createpolicy --policy-pcr -l sha256:0,7 -L <policy>

    run-cmd "tpm_seal_step3_createpolicy" [
        "tpm2_createpolicy"
        "-T" $tcti
        "--policy-pcr"
        "-l" "sha256:0,7"
        "-L" $policy_pcr
    ] $dry_run

    # ── Step 4: Create sealing object bound to the PCR policy ────────────────
    #
    # tpm2_create -C <primary_ctx> -i <secret> -u <pub> -r <priv>
    #             -L <policy> -a "fixedtpm|fixedparent|noda|adminwithpolicy"

    run-cmd "tpm_seal_step4_create" [
        "tpm2_create"
        "-T" $tcti
        "-C" $primary_ctx
        "-i" $secret_file
        "-u" $seal_pub
        "-r" $seal_priv
        "-L" $policy_pcr
        "-a" "fixedtpm|fixedparent|noda|adminwithpolicy"
    ] $dry_run

    # ── Step 5: Load the sealing object ──────────────────────────────────────

    run-cmd "tpm_seal_step5_load" [
        "tpm2_load"
        "-T" $tcti
        "-C" $primary_ctx
        "-u" $seal_pub
        "-r" $seal_priv
        "-c" $seal_ctx
    ] $dry_run

    # ── Step 6: Unseal ────────────────────────────────────────────────────────
    #
    # tpm2_unseal requires presenting the PCR policy session.
    # We use --auth pcr:sha256:0,7 which creates a policy session inline.

    run-cmd "tpm_seal_step6_unseal" [
        "tpm2_unseal"
        "-T" $tcti
        "-c" $seal_ctx
        "--auth" "pcr:sha256:0,7"
        "-o" $unseal_file
    ] $dry_run

    # ── Step 7: Verify plaintext matches ─────────────────────────────────────

    log-step "tpm_seal_step7_verify" {expected: $secret_text, unsealed_file: $unseal_file}

    if $dry_run {
        log-step "tpm_seal_step7_dry_run_skip" {note: "dry-run; skipping plaintext comparison"}
        emit-claims "dry_run" {note: "commands printed; no TPM interaction performed"}
        return
    }

    let unsealed = if ($unseal_file | path exists) {
        open --raw $unseal_file | str trim
    } else {
        ""
    }

    if $unsealed == $secret_text {
        log-step "tpm_seal_step7_match" {
            expected: $secret_text
            got:      $unsealed
            verdict:  "pass"
        }
        # Cleanup scratch dir.
        ^rm -rf $work_dir
        emit-claims "pass" {
            secret:   $secret_text
            unsealed: $unsealed
            pcrs:     "sha256:0,7"
            tcti:     $tcti
        }
    } else {
        log-step "tpm_seal_step7_mismatch" {
            expected: $secret_text
            got:      $unsealed
            verdict:  "fail"
        }
        emit-claims "fail" {
            expected:     $secret_text
            got:          $unsealed
            pcrs:         "sha256:0,7"
            tcti:         $tcti
            note:         "unsealed plaintext does not match original secret"
        }
        exit 1
    }
}
