#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/pre-push-check.nu — scan spool for sensitive patterns before pushing
#
# Usage: nu bin/pre-push-check.nu
# Exit 0 = clean, Exit 1 = sensitive content found

def main [] {
    let spool = "var/mail/spool"
    if not ($spool | path exists) {
        print "spool absent — nothing to check"
        exit 0
    }

    let content = open --raw $spool
    mut hits = []

    # IPv4 addresses that look like public IPs (not RFC1918)
    # RFC1918: 10.x, 172.16-31.x, 192.168.x
    let lines = $content | lines | enumerate
    for entry in $lines {
        let line = $entry.item
        let lineno = $entry.index + 1
        # Simple public IP heuristic: x.x.x.x where first octet not 10/172/192
        # Use =~ regex match operator (Nushell 0.111+)
        if ($line =~ '(?:[0-9]{1,3}\.){3}[0-9]{1,3}') and not ($line =~ '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)') {
            $hits = $hits | append $"line ($lineno): possible public IP: ($line | str trim)"
        }
        # Instance UUIDs (Vultr-style)
        if ($line =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') {
            $hits = $hits | append $"line ($lineno): possible UUID/instance-id: ($line | str trim)"
        }
        # API keys (long alphanum strings)
        if ($line =~ 'api.key\s*[:=]\s*\S{20,}') {
            $hits = $hits | append $"line ($lineno): possible API key"
        }
    }

    if ($hits | length) > 0 {
        print "SENSITIVE CONTENT FOUND IN SPOOL:"
        $hits | each { print $in }
        print "\nDo not push var/mail/spool to a public repo."
        print "Add it to .gitignore or redact before committing."
        exit 1
    }

    print "pre-push-check: clean"
    exit 0
}
