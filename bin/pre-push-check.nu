#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/pre-push-check.nu — block pushes that would leak sensitive content
#
# Checks:
#   1. var/mail/spool — public IPs, instance UUIDs, API keys (original check)
#   2. the whole tracked tree (HEAD) — private/CGNAT IPs and internal
#      hostnames. The hostname denylist is deliberately NOT committed
#      (committing it would re-leak the names): one hostname per line in
#      var/private-hostnames.txt (gitignored), and/or comma-separated in
#      $SMOLBSD_HOSTNAME_DENYLIST.
#
# Usage: nu bin/pre-push-check.nu
# Exit 0 = clean, Exit 1 = sensitive content found

# ── Check 1: spool ───────────────────────────────────────────────────────────
def check-spool [] {
    let spool = "var/mail/spool"
    mut hits = []
    if not ($spool | path exists) {
        return $hits
    }

    let content = open --raw $spool
    let lines = $content | lines | enumerate
    for entry in $lines {
        let line = $entry.item
        let lineno = $entry.index + 1
        # Simple public IP heuristic: x.x.x.x where first octet not 10/172/192
        if ($line =~ '(?:[0-9]{1,3}\.){3}[0-9]{1,3}') and not ($line =~ '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)') {
            $hits = $hits | append $"spool line ($lineno): possible public IP: ($line | str trim)"
        }
        # Instance UUIDs (Vultr-style)
        if ($line =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') {
            $hits = $hits | append $"spool line ($lineno): possible UUID/instance-id: ($line | str trim)"
        }
        # API keys (long alphanum strings)
        if ($line =~ 'api.key\s*[:=]\s*\S{20,}') {
            $hits = $hits | append $"spool line ($lineno): possible API key"
        }
    }
    $hits
}

# ── Check 2: private IPs / internal hostnames in the tracked tree ────────────
def check-tree [] {
    mut hits = []

    # QEMU user-mode networking protocol constants — legitimate in docs/tests.
    let ip_allow = ["10.0.2.2" "10.0.2.15"]

    # RFC1918 (10/8, 172.16/12, 192.168/16) and CGNAT (100.64/10).
    let ip_patterns = [
        '(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
        '(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
        '(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
        '(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
    ]
    for pat in $ip_patterns {
        # git grep over HEAD = exactly what a push publishes (not the worktree)
        let r = (do { ^git grep -nIE $pat HEAD } | complete)
        if $r.exit_code == 0 {
            for line in ($r.stdout | lines) {
                let allowed = $ip_allow | any { |ip| $line | str contains $ip }
                if not $allowed {
                    $hits = $hits | append $"private IP: ($line)"
                }
            }
        }
    }

    # Internal hostname denylist (see header — never commit the list itself).
    mut names = []
    let deny_file = "var/private-hostnames.txt"
    if ($deny_file | path exists) {
        let file_names = open --raw $deny_file | lines | each { |l| $l | str trim } | where { |l| $l != "" and not ($l | str starts-with "#") }
        $names = $names | append $file_names
    }
    let env_deny = $env.SMOLBSD_HOSTNAME_DENYLIST? | default ""
    if $env_deny != "" {
        let env_names = $env_deny | split row "," | each { |n| $n | str trim } | where { |n| $n != "" }
        $names = $names | append $env_names
    }
    for name in $names {
        let r = (do { ^git grep -inIF $name HEAD } | complete)
        if $r.exit_code == 0 {
            for line in ($r.stdout | lines) {
                $hits = $hits | append $"internal hostname '($name)': ($line)"
            }
        }
    }
    $hits
}

def main [] {
    let spool_hits = check-spool
    let tree_hits = check-tree
    let hits = $spool_hits | append $tree_hits

    if ($hits | length) > 0 {
        print "SENSITIVE CONTENT WOULD BE PUSHED:"
        $hits | each { print $"  ($in)" }
        print ""
        print "Private IPs and internal hostnames must not reach a public remote."
        print "Replace with placeholders (<kvm-host>, <internal-ip>, ...) or pass"
        print "values via environment variables. Spool data stays out entirely."
        print "Denylist: var/private-hostnames.txt (gitignored) or $SMOLBSD_HOSTNAME_DENYLIST."
        exit 1
    }

    print "pre-push-check: clean (spool + tree)"
    exit 0
}
