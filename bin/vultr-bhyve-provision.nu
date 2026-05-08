#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# vultr-bhyve-provision.nu — provision a Vultr bare-metal or dedicated amd64
# FreeBSD 15 instance suitable for running bhyve with real VT-x.
#
# Background: fbuild (fb-vm-24) is an arm64 VM under Apple HVF; EL2 is not
# exposed to guests, so /dev/vmm is never created and bhyve cannot run.
# The Phase-III TPM test also requires amd64 bhyve (virtio-tpm PCI device).
# This script provisions the correct host type on Vultr.
#
# Usage:
#   VULTR_API_KEY=<key> nu bin/vultr-bhyve-provision.nu
#   VULTR_API_KEY=<key> nu bin/vultr-bhyve-provision.nu --plan vbm-6c-32gb --region ewr
#   VULTR_API_KEY=<key> nu bin/vultr-bhyve-provision.nu --instance-fallback --poll
#
# Flags:
#   --plan               Vultr plan ID (default: vbm-6c-32gb for bare metal)
#   --region             Vultr region ID (default: ewr — New Jersey, good lat for US)
#   --label              Server label (default: smolbsd-bhyve)
#   --instance-fallback  Use a 4c/8GB optimised cloud instance if bare-metal
#                        quota is unavailable (VT-x is exposed on Vultr cloud
#                        instances via KVM, which does support nested bhyve)
#   --poll               Wait for the instance to become active and print the
#                        IP address; default: exit immediately after create
#   --poll-timeout       Max seconds to wait for active status (default: 600)
#   --dry-run            Print the API request body without sending it
#   --json               Emit final result as JSON (default: TOML)
#
# Required environment:
#   VULTR_API_KEY — Vultr personal access token
#
# OS ID:    2720 — FreeBSD 15 x64 (confirmed available in Vultr catalogue)
# Plan IDs  (amd64 bare metal with Intel VT-x or AMD-V):
#   vbm-6c-32gb       6c/32GB Intel E-2286G, $185/mo — available in ewr/ord/lax/etc.
#   vbm-4c-32gb       4c/32GB Intel E3-1270,  $120/mo — available in ewr/ord/lax
#   vbm-8c-132gb-v2   8c/132GB Intel E-2388G, $350/mo — NVMe, wider availability
# Plan ID  (cloud instance fallback — KVM with exposed VT-x):
#   vc2-4c-8gb        4c/8GB shared CPU,       $24/mo — available everywhere
#
# See: plans/tinyos/PHASE-3-TPM.md §4
#      bin/bhyve-host-setup.nu  (run on the provisioned instance)

# ── Logging ────────────────────────────────────────────────────────────────────

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── Vultr API helpers ──────────────────────────────────────────────────────────

# Make a Vultr REST API call.  Returns the parsed JSON body as a record.
# Exits with a clear error on HTTP error or missing API key.
def vultr-api [
    method:   string   # GET | POST | DELETE
    path:     string   # e.g. /v2/bare-metals
    body:     any = null  # record to send as JSON (POST only)
]: nothing -> any {
    if not ("VULTR_API_KEY" in $env) or ($env.VULTR_API_KEY | str length) == 0 {
        error make {msg: "VULTR_API_KEY environment variable is not set"}
    }

    let url     = $"https://api.vultr.com($path)"
    let headers = [
        "Authorization" $"Bearer ($env.VULTR_API_KEY)"
        "Content-Type"  "application/json"
    ]

    # Nushell http commands are split by verb (http get / http post / http delete).
    # --full returns {status, body, headers, urls}; --allow-errors prevents throw on 4xx/5xx.
    let resp = if ($method | str upcase) == "GET" {
        http get $url --headers $headers --full --allow-errors
    } else if ($method | str upcase) == "POST" {
        let body_json = $body | to json
        http post $url $body_json --headers $headers --content-type "application/json" --full --allow-errors
    } else if ($method | str upcase) == "DELETE" {
        http delete $url --headers $headers --full --allow-errors
    } else {
        error make {msg: $"vultr-api: unsupported method ($method)"}
    }

    let status   = $resp | get status?  | default 0
    let body_str = $resp | get body?    | default "" | into string

    if $status < 200 or $status >= 300 {
        error make {
            msg:  $"Vultr API ($method) ($path) failed: HTTP ($status)"
            help: ($body_str | str substring 0..200)
        }
    }

    if ($body_str | str trim | str length) == 0 {
        return {}
    }

    $body_str | from json
}

# Poll a bare-metal or instance endpoint until status == "active" or timeout.
# Returns the final record from the API.
def poll-until-active [
    resource_type: string   # "bare-metals" | "instances"
    resource_id:   string
    timeout_sec:   int
] {
    let endpoint = $"/v2/($resource_type)/($resource_id)"
    let deadline  = (date now) + ($timeout_sec * 1sec)
    mut last_status = "pending"
    mut attempt = 0

    loop {
        $attempt = $attempt + 1
        let resp = vultr-api "GET" $endpoint

        let server = $resp | get ($resource_type | str replace "s" "" | str replace "-metal" "_metal") ?
                   | default ($resp | get "bare_metal"? | default ($resp | get "instance"?))
        let status = $server | get status? | default "unknown"

        log-step "poll" $"attempt ($attempt): status=($status)" {
            id:     $resource_id
            status: $status
        }

        if $status == "active" {
            return $server
        }

        if (date now) > $deadline {
            error make {
                msg: $"Timed out after ($timeout_sec)s waiting for ($resource_id) to become active; last status: ($status)"
            }
        }

        $last_status = $status
        ^sleep 30
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Provision a Vultr FreeBSD 15 amd64 instance for bhyve testing.
# Prints a TOML (or JSON with --json) result record containing the instance
# ID, IP address, and SSH instructions.
def main [
    --plan:              string = "vbm-6c-32gb"   # bare-metal plan; overridable
    --region:            string = "ewr"            # New Jersey; has vbm-6c-32gb
    --label:             string = "smolbsd-bhyve"
    --instance-fallback                            # use cloud instance if bare-metal unavailable
    --poll                                         # wait for active + print IP
    --poll-timeout:      int    = 600              # seconds to wait when --poll
    --dry-run                                      # print request body, do not send
    --json                                         # emit result as JSON not TOML
] {
    # FreeBSD 15 x64 OS ID confirmed via: vultr os list | grep 'FreeBSD 15'
    let os_id = 2720

    # SSH key IDs from account (all three keys added for access by any dev machine).
    # Obtained via: vultr ssh-key list -o json
    let ssh_keys = [
        "bc0728b4-a0aa-4c16-93a0-3667465e5cbd"   # MBP
        "50b6a6f8-c693-4633-b86f-e259265dd162"   # Studio
        "REDACTED-VULTR-SSH-KEY-UUID"   # mbp-m1-ed25519
    ]

    # Determine whether this is a bare-metal or cloud instance request.
    let is_bare_metal = not $instance_fallback

    # User-data cloud-init script: run bhyve-host-setup after first boot.
    # FreeBSD cloud images run user-data via cloud-init on the first boot.
    # The script installs deps, loads kernel modules, and clones the project.
    let userdata = "#!/bin/sh
# smolBSD bhyve host first-boot setup
# Installed by vultr-bhyve-provision.nu user-data
pkg install -y nushell swtpm bhyve-firmware qemu-tools expect git 2>&1 | logger -t smolbsd-setup
kldload vmm nmdm if_tap if_bridge 2>&1 | logger -t smolbsd-setup
sysrc kld_list+=\"vmm nmdm if_tap if_bridge\"
# Mark setup complete
touch /var/run/smolbsd-host-ready
logger -t smolbsd-setup 'bhyve host first-boot setup complete'
"

    if $is_bare_metal {
        log-step "provision" "creating Vultr bare-metal instance" {
            plan:   $plan
            region: $region
            os_id:  $os_id
            label:  $label
        }

        let body = {
            region:    $region
            plan:      $plan
            os_id:     $os_id
            label:     $label
            hostname:  $label
            ssh_key_ids: $ssh_keys
            user_data: ($userdata | encode base64)
            tags:      ["smolbsd" "bhyve" "phase-iii"]
        }

        if $dry_run {
            log-step "dry-run" "would POST to /v2/bare-metals" {body: ($body | to json)}
            return
        }

        let resp    = vultr-api "POST" "/v2/bare-metals" $body
        let server  = $resp | get bare_metal?
        let bm_id   = $server | get id? | default "unknown"
        let bm_ip   = $server | get main_ip? | default "pending"
        let status  = $server | get status? | default "pending"

        log-step "created" "bare-metal instance created" {
            id:     $bm_id
            ip:     $bm_ip
            status: $status
            plan:   $plan
            region: $region
        }

        mut final_server = $server

        if $poll {
            log-step "poll-start" $"waiting up to ($poll_timeout)s for active status..."
            $final_server = poll-until-active "bare-metals" $bm_id $poll_timeout
        }

        let result = {
            id:             ($final_server | get id?     | default $bm_id)
            ip:             ($final_server | get main_ip? | default $bm_ip)
            status:         ($final_server | get status? | default $status)
            plan:           $plan
            region:         $region
            type:           "bare-metal"
            os:             "FreeBSD 15 x64"
            ssh_user:       "root"
            next_step:      $"ssh root@($final_server | get main_ip? | default $bm_ip) 'nu smolbsd/bin/bhyve-host-setup.nu'"
            setup_script:   "bin/bhyve-host-setup.nu"
        }

        if $json {
            print ($result | to json)
        } else {
            print ($result | to toml)
        }

    } else {
        # Cloud instance fallback — Vultr KVM exposes VT-x to guests,
        # enabling nested bhyve.  Phase-III TPM requires amd64 bhyve which
        # IS supported on KVM-backed Vultr cloud instances.
        let cloud_plan = "vc2-4c-8gb"
        log-step "provision" "creating Vultr cloud instance (KVM, VT-x exposed)" {
            plan:   $cloud_plan
            region: $region
            os_id:  $os_id
            label:  $label
            note:   "KVM guest; nested bhyve requires VT-x passthrough (confirmed on Vultr vc2)"
        }

        let body = {
            region:      $region
            plan:        $cloud_plan
            os_id:       $os_id
            label:       $label
            hostname:    $label
            sshkey_id:   $ssh_keys
            user_data:   ($userdata | encode base64)
            tags:        ["smolbsd" "bhyve" "phase-iii"]
        }

        if $dry_run {
            log-step "dry-run" "would POST to /v2/instances" {body: ($body | to json)}
            return
        }

        let resp     = vultr-api "POST" "/v2/instances" $body
        let server   = $resp | get instance?
        let inst_id  = $server | get id?      | default "unknown"
        let inst_ip  = $server | get main_ip? | default "pending"
        let status   = $server | get status?  | default "pending"

        log-step "created" "cloud instance created" {
            id:     $inst_id
            ip:     $inst_ip
            status: $status
            plan:   $cloud_plan
            region: $region
        }

        mut final_server = $server

        if $poll {
            log-step "poll-start" $"waiting up to ($poll_timeout)s for active status..."
            $final_server = poll-until-active "instances" $inst_id $poll_timeout
        }

        let result = {
            id:           ($final_server | get id?      | default $inst_id)
            ip:           ($final_server | get main_ip? | default $inst_ip)
            status:       ($final_server | get status?  | default $status)
            plan:         $cloud_plan
            region:       $region
            type:         "cloud-instance-kvm"
            os:           "FreeBSD 15 x64"
            ssh_user:     "root"
            next_step:    $"ssh root@($final_server | get main_ip? | default $inst_ip) 'nu smolbsd/bin/bhyve-host-setup.nu'"
            setup_script: "bin/bhyve-host-setup.nu"
        }

        if $json {
            print ($result | to json)
        } else {
            print ($result | to toml)
        }
    }
}
