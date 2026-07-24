#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/pre-push-check.nu — scan spool for sensitive patterns before pushing
#
# Usage: nu bin/pre-push-check.nu [--spool <path>]
# Exit 0 = clean, Exit 1 = sensitive content found
#
# Covered by CI: .github/workflows/ci.yml runs this against absent, clean,
# and dirty fixture spools (tests/fixtures/spool-*.mbox) on the pinned nu.

# All findings for one spool line (empty list = clean line).
# Nushell's map is `each`; a per-line rule table beats a for+mut accumulator.
def line-findings [lineno: int, line: string] {
    [
        # IPv4 that looks public: exempt lines starting with RFC1918/loopback
        (if ($line =~ '(?:[0-9]{1,3}\.){3}[0-9]{1,3}') and not ($line =~ '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)') {
            $"line ($lineno): possible public IP: ($line | str trim)"
        })
        # Instance UUIDs (Vultr-style)
        (if $line =~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' {
            $"line ($lineno): possible UUID/instance-id: ($line | str trim)"
        })
        # API keys (long alphanum strings)
        (if $line =~ 'api.key\s*[:=]\s*\S{20,}' {
            $"line ($lineno): possible API key"
        })
    ] | compact
}

def main [
    --spool: string = "var/mail/spool"   # override for tests/fixtures
] {
    if not ($spool | path exists) {
        print "spool absent — nothing to check"
        exit 0
    }

    let hits = open --raw $spool
        | lines
        | enumerate
        | each {|e| line-findings ($e.index + 1) $e.item }
        | flatten

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
