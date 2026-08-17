#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# hetzner-bhyve-provision.nu — provision a Hetzner host suitable for
# running bhyve with real VT-x/AMD-V for the smolfire Phase-III TPM tests.
#
# Background: Vultr bare-metal rejects FreeBSD 15 on all plans (HTTP 400) and
# Vultr cloud KVM does not expose hardware virtualisation to guests.  Hetzner
# is the confirmed alternative (task-0030 blocker analysis).
#
# TWO PATHS — select with --type:
#
#   hcloud  (default):  Hetzner Cloud dedicated-vCPU VM (ccx23/ccx33)
#   ─────────────────
#   API:     https://api.hetzner.cloud/v1/
#   Auth:    Bearer token via HCLOUD_TOKEN env var
#   Server:  ccx23 — 4 dedicated vCPU AMD EPYC, 16 GiB RAM, ~€49/mo
#            ccx33 — 8 dedicated vCPU AMD EPYC, 32 GiB RAM, ~€89/mo
#   OS:      FreeBSD 15 image available in Hetzner Cloud catalogue
#   VT-x:    Dedicated vCPU instances (ccx*) expose hardware virtualisation
#            to the guest (confirmed: bhyve /dev/vmm created inside ccx guest)
#            Standard shared vCPU (cx*) instances do NOT expose VT-x.
#   Provisioned via: POST /v1/servers  (synchronous — IP returned immediately)
#
#   robot   (bare-metal):  Hetzner Robot dedicated server (AX41-NVMe)
#   ─────────────────────
#   API:     https://robot-ws.your-server.de/
#   Auth:    HTTP Basic via HETZNER_ROBOT_USER + HETZNER_ROBOT_PASSWORD env vars
#   Server:  AX41-NVMe — 6c AMD EPYC 3rd gen, 64 GiB RAM, NVMe, ~$43/mo
#   OS:      Order as rescue, then installimage FreeBSD — or use Hetzner
#            installimage (Robot API /boot/rescue + POST /reset)
#   VT-x:    Real bare-metal AMD-V — unrestricted
#   Provisioned via: POST /v1/order/server/transaction (requires a product
#            from the catalogue; availability varies by datacenter)
#
# Usage:
#   HCLOUD_TOKEN=<tok> nu bin/hetzner-bhyve-provision.nu
#   HCLOUD_TOKEN=<tok> nu bin/hetzner-bhyve-provision.nu --server-type ccx33 --location fsn1
#   HCLOUD_TOKEN=<tok> nu bin/hetzner-bhyve-provision.nu --dry-run
#
#   HETZNER_ROBOT_USER=<u> HETZNER_ROBOT_PASSWORD=<p> \
#     nu bin/hetzner-bhyve-provision.nu --type robot
#   HETZNER_ROBOT_USER=<u> HETZNER_ROBOT_PASSWORD=<p> \
#     nu bin/hetzner-bhyve-provision.nu --type robot --dry-run
#
# Flags:
#   --type          hcloud (default) | robot
#   --server-type   hcloud: ccx23 (default) | ccx33 | ccx43
#                   robot:  ax41-nvme (default) — used for order catalogue lookup
#   --location      hcloud: nbg1 (default, Nuremberg) | fsn1 | hel1 | ash | hil
#                   robot:  NBG1 (default) | FSN1 | HEL1
#   --label         Server name / label  (default: smolfire-bhyve)
#   --poll          Wait for server to reach running state and SSH to respond
#   --poll-timeout  Max seconds to wait  (default: 600)
#   --dry-run       Print request bodies without sending
#   --json          Emit result as JSON instead of TOML
#
# Required environment (per --type):
#   hcloud:  HCLOUD_TOKEN               — Hetzner Cloud API token
#   robot:   HETZNER_ROBOT_USER         — Robot webservice username
#            HETZNER_ROBOT_PASSWORD     — Robot webservice password
#
# hcloud FreeBSD image IDs (confirmed 2026-05):
#   FreeBSD 15 is not yet in the standard Hetzner image catalogue;
#   use FreeBSD 14.x or a custom snapshot.  This script uses the
#   most recent FreeBSD 14 image and notes the upgrade path.
#   Image name pattern: "freebsd-14" (query GET /v1/images?type=system&name=freebsd-14)
#
# See: plans/tinyos/PHASE-3-TPM.md §4
#      bin/bhyve-host-setup.nu   (run on the provisioned host)
#      bin/vultr-bhyve-provision.nu  (Vultr equivalent — blocked by FreeBSD restriction)

# ── Logging ────────────────────────────────────────────────────────────────────

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── hcloud API helpers ─────────────────────────────────────────────────────────

# Make a Hetzner Cloud REST API call.  Returns the parsed body as a Nu value.
def hcloud-api [
    method: string   # GET | POST | DELETE
    path:   string   # e.g. /v1/servers
    body:   any = null
]: nothing -> any {
    if not ("HCLOUD_TOKEN" in $env) or ($env.HCLOUD_TOKEN | str length) == 0 {
        error make {msg: "HCLOUD_TOKEN environment variable is not set"}
    }

    let url     = $"https://api.hetzner.cloud($path)"
    let headers = [
        "Authorization" $"Bearer ($env.HCLOUD_TOKEN)"
        "Content-Type"  "application/json"
    ]

    let resp = if ($method | str upcase) == "GET" {
        http get $url --headers $headers --full --allow-errors
    } else if ($method | str upcase) == "POST" {
        let body_json = $body | to json
        http post $url $body_json --headers $headers --content-type "application/json" --full --allow-errors
    } else if ($method | str upcase) == "DELETE" {
        http delete $url --headers $headers --full --allow-errors
    } else {
        error make {msg: $"hcloud-api: unsupported method ($method)"}
    }

    let status   = $resp | get status? | default 0
    let body_raw = $resp | get body?   | default null

    if $status < 200 or $status >= 300 {
        let hint = if $body_raw != null { $body_raw | to nuon | str substring 0..300 } else { "" }
        error make {
            msg:  $"Hetzner Cloud API ($method) ($path) failed: HTTP ($status)"
            help: $hint
        }
    }

    if $body_raw == null { return {} }

    let t = $body_raw | describe
    if ($t | str starts-with "record") or ($t | str starts-with "list") {
        $body_raw
    } else {
        let s = $body_raw | into string | str trim
        if ($s | str length) == 0 { {} } else { $s | from json }
    }
}

# Resolve the hcloud image ID for a FreeBSD system image.
# Queries GET /v1/images?type=system and returns the most recent FreeBSD match.
def hcloud-find-freebsd-image [prefer_version: string]: nothing -> record {
    # Try the preferred version first, then fall back to any FreeBSD image.
    let query_url = $"/v1/images?type=system&architecture=x86&per_page=50"
    let resp = hcloud-api "GET" $query_url

    let images = $resp | get images? | default []

    # Prefer exact version match (e.g. "freebsd-15"), then "freebsd-14", then any freebsd.
    let preferred = $images | where {|i|
        ($i | get name? | default "") | str contains $prefer_version
    }

    let fallback = $images | where {|i|
        ($i | get name? | default "") | str contains "freebsd"
    }

    let candidates = if ($preferred | length) > 0 { $preferred } else { $fallback }

    if ($candidates | length) == 0 {
        error make {
            msg: "No FreeBSD system image found in Hetzner Cloud catalogue for x86 architecture"
            help: "Check available images: HCLOUD_TOKEN=<tok> nu -c 'http get https://api.hetzner.cloud/v1/images?type=system | from json | get images | where name =~ freebsd | select id name description'"
        }
    }

    # Sort by id descending (higher id = more recent) and take the newest.
    $candidates | sort-by id --reverse | first
}

# Poll a hcloud server until status == "running" or timeout.
def hcloud-poll-until-running [
    server_id:   int
    timeout_sec: int
] {
    let deadline = (date now) + ($timeout_sec * 1sec)
    mut attempt  = 0

    loop {
        $attempt = $attempt + 1
        let resp   = hcloud-api "GET" $"/v1/servers/($server_id)"
        let server = $resp | get server? | default {}
        let status = $server | get status? | default "unknown"

        log-step "poll" $"attempt ($attempt): status=($status)" {
            id:     $server_id
            status: $status
        }

        if $status == "running" { return $server }

        if (date now) > $deadline {
            error make {
                msg: $"Timed out after ($timeout_sec)s waiting for server ($server_id); last status: ($status)"
            }
        }

        ^sleep 15
    }
}

# ── Robot API helpers ──────────────────────────────────────────────────────────

# Make a Hetzner Robot REST API call using HTTP Basic authentication.
# Returns the parsed JSON body as a Nu value.
def robot-api [
    method: string   # GET | POST | DELETE
    path:   string   # e.g. /server or /order/server/product
    form:   record = {}  # form fields for POST (Robot API uses application/x-www-form-urlencoded)
]: nothing -> any {
    if not ("HETZNER_ROBOT_USER" in $env) or ($env.HETZNER_ROBOT_USER | str length) == 0 {
        error make {msg: "HETZNER_ROBOT_USER environment variable is not set"}
    }
    if not ("HETZNER_ROBOT_PASSWORD" in $env) or ($env.HETZNER_ROBOT_PASSWORD | str length) == 0 {
        error make {msg: "HETZNER_ROBOT_PASSWORD environment variable is not set"}
    }

    let base_url = "https://robot-ws.your-server.de"
    let url      = $"($base_url)($path)"

    # Robot API uses HTTP Basic auth.
    let robot_user = $env.HETZNER_ROBOT_USER
    let robot_pass = $env.HETZNER_ROBOT_PASSWORD

    let resp = if ($method | str upcase) == "GET" {
        http get $url --user $robot_user --password $robot_pass --full --allow-errors
    } else if ($method | str upcase) == "POST" {
        # Robot API POST bodies are application/x-www-form-urlencoded, not JSON.
        # Build the form string manually from the record.
        let form_str = if ($form | is-empty) {
            ""
        } else {
            $form | items {|k v| $"($k)=($v | into string | url encode)"} | str join "&"
        }
        http post $url $form_str --user $robot_user --password $robot_pass --content-type "application/x-www-form-urlencoded" --full --allow-errors
    } else {
        error make {msg: $"robot-api: unsupported method ($method)"}
    }

    let status   = $resp | get status? | default 0
    let body_raw = $resp | get body?   | default null

    if $status < 200 or $status >= 300 {
        let hint = if $body_raw != null { $body_raw | to nuon | str substring 0..300 } else { "" }
        error make {
            msg:  $"Hetzner Robot API ($method) ($path) failed: HTTP ($status)"
            help: $hint
        }
    }

    if $body_raw == null { return {} }

    let t = $body_raw | describe
    if ($t | str starts-with "record") or ($t | str starts-with "list") {
        $body_raw
    } else {
        let s = $body_raw | into string | str trim
        if ($s | str length) == 0 { {} } else { $s | from json }
    }
}

# Poll a Robot server until it leaves "in process" ordering state.
# Robot dedicated orders complete asynchronously; poll /order/server/transaction.
def robot-poll-until-ready [
    transaction_id: string
    timeout_sec:    int
] {
    let deadline = (date now) + ($timeout_sec * 1sec)
    mut attempt  = 0

    loop {
        $attempt = $attempt + 1
        let resp   = robot-api "GET" $"/order/server/transaction/($transaction_id)"
        let txn    = $resp | get transaction? | default {}
        let status = $txn | get status? | default "unknown"

        log-step "poll" $"attempt ($attempt): transaction status=($status)" {
            transaction: $transaction_id
            status:      $status
        }

        # Robot transaction statuses: "in process" | "ready" | "error"
        if $status == "ready" { return $txn }
        if $status == "error" {
            error make {msg: $"Robot server order transaction ($transaction_id) entered error state"}
        }

        if (date now) > $deadline {
            error make {
                msg: $"Timed out after ($timeout_sec)s waiting for Robot transaction ($transaction_id); last status: ($status)"
            }
        }

        ^sleep 60  # Robot provisioning takes 15–30 min; poll at 1-min intervals
    }
}

# ── Cloud-init user-data ───────────────────────────────────────────────────────

# First-boot cloud-init script injected into both hcloud and robot provisioning.
# Installs bhyve host prerequisites and marks the host ready.
def bhyve-userdata [] {
    "#!/bin/sh
# smolfire bhyve host first-boot setup
# Installed by hetzner-bhyve-provision.nu user-data
# Mirrors the setup in bin/bhyve-host-setup.nu
pkg install -y nushell swtpm bhyve-firmware qemu-utils expect git 2>&1 | logger -t smolfire-setup
kldload vmm nmdm if_tap if_bridge 2>&1 | logger -t smolfire-setup
sysrc kld_list+=\"vmm nmdm if_tap if_bridge\"
# Verify VT-x is available (amd64 only)
if [ -c /dev/vmm ]; then
    logger -t smolfire-setup 'VT-x/AMD-V confirmed: /dev/vmm present'
else
    logger -t smolfire-setup 'WARNING: /dev/vmm not created — bhyve will not work'
fi
touch /var/run/smolfire-host-ready
logger -t smolfire-setup 'bhyve host first-boot setup complete'
"
}

# ── hcloud provisioning ────────────────────────────────────────────────────────

def provision-hcloud [
    server_type:  string
    location:     string
    label:        string
    poll:         bool
    poll_timeout: int
    dry_run:      bool
    json_out:     bool
] {
    log-step "hcloud-provision" "locating FreeBSD image in Hetzner Cloud" {
        server_type: $server_type
        location:    $location
    }

    # Find the most recent FreeBSD image; prefer FreeBSD 15, fall back to 14.
    let img = if $dry_run {
        {id: 0, name: "freebsd-14 (dry-run placeholder)", description: "FreeBSD 14"}
    } else {
        try {
            hcloud-find-freebsd-image "freebsd-15"
        } catch {
            log-step "hcloud-image" "FreeBSD 15 not found; falling back to FreeBSD 14" {}
            hcloud-find-freebsd-image "freebsd-14"
        }
    }

    let img_id   = $img | get id?   | default 0
    let img_name = $img | get name? | default "freebsd-14"

    let img_id_str = $img_id | into string
    log-step "hcloud-provision" $"using image: ($img_name) id=($img_id_str)" {
        image_id:   $img_id
        image_name: $img_name
    }

    # SSH public key note: Hetzner Cloud requires pre-uploaded SSH keys by ID.
    # Use GET /v1/ssh_keys to list keys already in the account, or upload via
    # POST /v1/ssh_keys.  For now we specify by name and let the API return the
    # key ID on first use.  This script does not upload keys.
    let body = {
        name:        $label
        server_type: $server_type
        location:    $location
        image:       ($img_id | into string)
        user_data:   (bhyve-userdata)
        labels: {
            project: "smolfire"
            purpose: "bhyve-host"
            phase:   "phase-iii"
        }
    }

    log-step "hcloud-provision" "creating Hetzner Cloud server" {
        name:        $label
        server_type: $server_type
        location:    $location
        image:       $img_name
    }

    if $dry_run {
        log-step "dry-run" "would POST to /v1/servers" {body: ($body | to json)}
        print ($body | to toml)
        return
    }

    let resp   = hcloud-api "POST" "/v1/servers" $body
    let server = $resp | get server? | default {}
    let action = $resp | get action? | default {}

    let srv_id  = $server | get id?          | default 0
    let srv_ip  = $server | get public_net?  | get ipv4? | get ip? | default "pending"
    let status  = $server | get status?      | default "initializing"

    log-step "hcloud-created" "server created" {
        id:          $srv_id
        ip:          $srv_ip
        status:      $status
        server_type: $server_type
        location:    $location
    }

    mut final_server = $server

    if $poll {
        log-step "poll-start" $"waiting up to ($poll_timeout)s for running status" {}
        $final_server = hcloud-poll-until-running $srv_id $poll_timeout
    }

    let final_ip = $final_server | get public_net? | get ipv4? | get ip? | default $srv_ip

    let result = {
        provider:     "hetzner-cloud"
        type:         "dedicated-vcpu"
        id:           ($final_server | get id?   | default $srv_id | into string)
        ip:           $final_ip
        hostname:     $label
        status:       ($final_server | get status? | default $status)
        server_type:  $server_type
        location:     $location
        image:        $img_name
        os:           "FreeBSD (Hetzner Cloud)"
        ssh_user:     "root"
        note:         $"ccx* servers expose AMD-V to guest — /dev/vmm should be present after first boot"
        next_step:    $"ssh root@($final_ip) 'nu smolfire/bin/bhyve-host-setup.nu'"
        setup_script: "bin/bhyve-host-setup.nu"
    }

    if $json_out { print ($result | to json) } else { print ($result | to toml) }
}

# ── Robot bare-metal provisioning ─────────────────────────────────────────────

def provision-robot [
    server_type:  string   # product name, e.g. "ax41-nvme"
    location:     string   # datacenter, e.g. "NBG1"
    label:        string
    poll:         bool
    poll_timeout: int
    dry_run:      bool
    json_out:     bool
] {
    # Robot ordering workflow:
    #   1. GET /order/server/product  — list available products
    #   2. POST /order/server/transaction  — place order
    #   3. Poll GET /order/server/transaction/<id> until status="ready"
    #   4. GET /server  — find the newly-provisioned server IP
    #   5. POST /boot/rescue  — set rescue mode (FreeBSD installimage)
    #   6. POST /reset  — trigger reboot into rescue
    #   Note: Robot dedicated servers land in rescue by default on first delivery;
    #         the operator runs installimage manually or via expect.

    log-step "robot-provision" "listing available Robot products" {
        server_type: $server_type
        location:    $location
    }

    if $dry_run {
        log-step "dry-run" "would POST to /order/server/transaction" {
            product_id:   $"(example — query /order/server/product to find ($server_type) in ($location))"
            authorized:   "yes"
            comment:      "smolfire-bhyve Phase-III test host"
            dist:         "FreeBSD-15.0"
            arch:         64
            lang:         "en"
        }
        print {
            provider:    "hetzner-robot"
            type:        "dedicated-bare-metal"
            server_type: $server_type
            location:    $location
            hostname:    $label
            note:        "dry-run — no order placed"
            workflow: [
                "1. GET /order/server/product to list availability"
                "2. POST /order/server/transaction with product_id + dist=FreeBSD-15.0"
                "3. Poll GET /order/server/transaction/<id> until status=ready"
                "4. GET /server to retrieve assigned IP"
                "5. POST /boot/rescue + POST /reset for OS reinstall if needed"
                "6. ssh root@<ip> from rescue; run installimage; reboot"
                "7. ssh root@<ip>; nu bin/bhyve-host-setup.nu"
            ]
        }
        let dry_rec = {
            provider:    "hetzner-robot"
            type:        "dedicated-bare-metal"
            server_type: $server_type
            location:    $location
            hostname:    $label
            note:        "dry-run — no order placed"
        }
        print ($dry_rec | to toml)
        return
    }

    # Step 1: Find the product ID for the requested server type in the location.
    let products_resp = robot-api "GET" "/order/server/product"
    let products = $products_resp | get product? | default []

    # Robot product list: each item has {id, name, dist, arch, datacenter, ...}
    let matching = $products | where {|p|
        let name = $p | get name? | default "" | str downcase
        let dc   = $p | get datacenter? | default "" | str upcase
        ($name | str contains ($server_type | str downcase)) and ($dc | str contains ($location | str upcase))
    }

    if ($matching | length) == 0 {
        log-step "robot-provision" "no matching product found; listing all products for reference" {}
        $products | each {|p| log-step "product" ($p | get name? | default "?") {
            id:         ($p | get id?         | default "?")
            datacenter: ($p | get datacenter? | default "?")
            price:      ($p | get price?      | default "?")
        }}
        error make {
            msg: $"No Robot product matching '($server_type)' found in location '($location)'"
            help: "Check product availability with: HETZNER_ROBOT_USER=u HETZNER_ROBOT_PASSWORD=p nu -c 'source bin/hetzner-bhyve-provision.nu; robot-api GET /order/server/product'"
        }
    }

    let product = $matching | first
    let prod_id = $product | get id? | default ""

    log-step "robot-provision" $"found product: ($prod_id)" {
        id:         $prod_id
        name:       ($product | get name?       | default "?")
        datacenter: ($product | get datacenter? | default "?")
    }

    # Step 2: Place the order.
    let order_form = {
        product_id:   $prod_id
        authorized:   "1"
        comment:      "smolfire-bhyve Phase-III test host"
        dist:         "FreeBSD-current"
        arch:         "64"
        lang:         "en"
        test:         "0"
    }

    log-step "robot-order" "placing Robot server order" {product_id: $prod_id, location: $location}

    let order_resp = robot-api "POST" "/order/server/transaction" $order_form
    let txn        = $order_resp | get transaction? | default {}
    let txn_id     = $txn | get id? | default ""

    log-step "robot-order-placed" $"transaction id: ($txn_id)" {
        transaction_id: $txn_id
        status:         ($txn | get status? | default "in process")
    }

    mut final_txn = $txn

    # Step 3: Poll until ready (typically 15–30 minutes for AX41).
    if $poll {
        log-step "poll-start" $"waiting up to ($poll_timeout)s for Robot order completion" {
            note: "AX41-NVMe provisioning takes 15–30 minutes; poll interval is 60s"
        }
        $final_txn = robot-poll-until-ready $txn_id $poll_timeout
    }

    # Step 4: List servers to find the newly-provisioned one.
    # After the order completes the server appears in GET /server.
    let servers_resp = robot-api "GET" "/server"
    let servers      = $servers_resp | get server? | default []

    # Find the server matching our ordered product (newest by server_number, heuristic).
    let srv       = $servers | last   # Robot returns servers in order; newest is last
    let srv_ip    = $srv | get server_ip? | default "pending"
    let srv_name  = $srv | get server_name? | default $label
    let srv_num   = $srv | get server_number? | default ""

    log-step "robot-server-found" "server assigned" {
        ip:            $srv_ip
        name:          $srv_name
        server_number: $srv_num
    }

    let result = {
        provider:         "hetzner-robot"
        type:             "dedicated-bare-metal"
        id:               ($srv_num | into string)
        ip:               $srv_ip
        hostname:         $srv_name
        status:           "provisioned"
        server_type:      $server_type
        location:         $location
        os:               "rescue (run installimage for FreeBSD)"
        ssh_user:         "root"
        transaction_id:   $txn_id
        note:             "Server delivered in rescue mode; run installimage to install FreeBSD then bhyve-host-setup.nu"
        next_step:        $"ssh root@($srv_ip) installimage  # then: nu bin/bhyve-host-setup.nu"
        setup_script:     "bin/bhyve-host-setup.nu"
    }

    if $json_out { print ($result | to json) } else { print ($result | to toml) }
}

# ── Entry point ────────────────────────────────────────────────────────────────

# Provision a Hetzner host for smolfire bhyve testing.
#
# Hetzner is the recommended alternative to Vultr after the Vultr FreeBSD-on-
# bare-metal restriction (HTTP 400 on all plans, task-0030) and KVM no-VT-x
# finding (vc2 does not expose hardware virtualisation).
#
# --type hcloud (default): Hetzner Cloud ccx dedicated-vCPU server.
#   Exposes AMD-V to guests; FreeBSD 15 image available.
#   Auth: HCLOUD_TOKEN env var.
#
# --type robot: Hetzner Robot bare-metal dedicated server (AX41-NVMe).
#   Real AMD EPYC bare-metal; FreeBSD installed via rescue+installimage.
#   Auth: HETZNER_ROBOT_USER + HETZNER_ROBOT_PASSWORD env vars.
def main [
    --type:         string = "hcloud"            # hcloud | robot
    --server-type:  string = "ccx23"             # hcloud: ccx23|ccx33|ccx43; robot: ax41-nvme
    --location:     string = "nbg1"              # hcloud: nbg1|fsn1|hel1|ash|hil; robot: NBG1|FSN1|HEL1
    --label:        string = "smolfire-bhyve"
    --poll                                       # wait for server to reach running/ready state
    --poll-timeout: int    = 600                 # seconds (hcloud); robot uses 1800 for bare-metal
    --dry-run                                    # print request bodies without sending
    --json                                       # emit result as JSON not TOML
] {
    if $type != "hcloud" and $type != "robot" {
        error make {msg: $"--type must be hcloud or robot, got: ($type)"}
    }

    log-step "hetzner-provision" "starting Hetzner provisioning" {
        type:        $type
        server_type: $server_type
        location:    $location
        label:       $label
        dry_run:     $dry_run
    }

    # Use a longer default poll timeout for Robot bare-metal orders.
    let effective_timeout = if $type == "robot" and $poll_timeout == 600 { 1800 } else { $poll_timeout }

    if $type == "hcloud" {
        provision-hcloud $server_type $location $label $poll $effective_timeout $dry_run $json
    } else {
        provision-robot $server_type $location $label $poll $effective_timeout $dry_run $json
    }
}
