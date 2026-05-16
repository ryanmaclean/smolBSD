#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# secret-materialize.nu — D1 secret envelope writer for smolBSD coordinator
#
# Writes a secret value to an out-of-band envelope file at
# var/run/secrets/<task-id>/<key> (mode 0600) with a .meta.toml sidecar
# carrying the SHA-256 fingerprint.  The spool carries only pointer tables —
# never the value itself.
#
# Usage:
#   nu bin/secret-materialize.nu --task-id t42 --key gitea_token --value "ghp_xxx"
#   echo "ghp_xxx" | nu bin/secret-materialize.nu --task-id t42 --key gitea_token
#
# Prints the TOML pointer table entry to stdout after materializing.

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# Compute SHA-256 hex of a string value.  Tries sha256sum (Linux/FreeBSD)
# then shasum -a 256 (macOS).  Returns the hex digest only.
def sha256-hex [value: string] {
    let result = try {
        $value | ^sha256sum | complete
    } catch {
        {exit_code: 1, stdout: ""}
    }
    if $result.exit_code == 0 {
        $result.stdout | split row " " | first | str trim
    } else {
        # macOS fallback
        let r2 = $value | ^shasum -a 256 | complete
        if $r2.exit_code == 0 {
            $r2.stdout | split row " " | first | str trim
        } else {
            error make {msg: "neither sha256sum nor shasum -a 256 found; cannot fingerprint secret"}
        }
    }
}

def main [
    --task-id: string        # task that owns this secret (required)
    --key:     string        # secret name, e.g. "gitea_token" (required)
    --value:   string = ""   # secret value; if empty, reads from stdin
    --root:    string = "."
] {
    if $task_id == null or $task_id == "" {
        error make {msg: "--task-id is required"}
    }
    if $key == null or $key == "" {
        error make {msg: "--key is required"}
    }

    # Read value from stdin if not provided on CLI
    let secret_value = if $value == "" {
        let stdin_val = $in | str trim
        if ($stdin_val | str length) == 0 {
            error make {msg: "--value is empty and stdin is empty; provide the secret value"}
        }
        $stdin_val
    } else {
        $value
    }

    let abs_root     = $root | path expand
    let envelope_dir = [$abs_root, "var", "run", "secrets", $task_id] | path join
    let envelope_path = [$envelope_dir, $key] | path join
    let meta_path     = [$envelope_dir, ".meta.toml"] | path join
    let rel_envelope  = ["var", "run", "secrets", $task_id, $key] | path join

    if not ($envelope_dir | path exists) { mkdir $envelope_dir }

    # Write secret file
    $secret_value | save --force $envelope_path
    ^chmod 0600 $envelope_path

    # Compute fingerprint
    let fingerprint = sha256-hex $secret_value

    # Write .meta.toml sidecar
    let ts_iso = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let meta = [
        $"task_id          = \"($task_id)\""
        $"key              = \"($key)\""
        $"fingerprint      = \"($fingerprint)\""
        $"materialized_at  = \"($ts_iso)\""
    ] | str join "\n"
    $meta | save --force $meta_path
    ^chmod 0600 $meta_path

    log-step "secret-materialize" "envelope written" {
        task_id:  $task_id
        key:      $key
        path:     $envelope_path
        # value and fingerprint intentionally omitted (redacted)
    }

    # Print the pointer table entry for inclusion in a spool message body
    print $"[secrets.($key)]"
    print $"envelope    = \"($rel_envelope)\""
    print $"fingerprint = \"($fingerprint)\""
}
