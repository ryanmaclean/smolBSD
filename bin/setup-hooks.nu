#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/setup-hooks.nu — install git hooks for smolBSD
#
# Run once after cloning:
#   nu bin/setup-hooks.nu
#
# Installs:
#   .git/hooks/pre-push  — blocks pushing spool data with public IPs / UUIDs

def main [] {
    let repo_root = (git rev-parse --show-toplevel | str trim)
    let hooks_dir = $"($repo_root)/.git/hooks"
    let hook_path = $"($hooks_dir)/pre-push"
    let check_script = $"($repo_root)/bin/pre-push-check.nu"

    if not ($check_script | path exists) {
        print $"ERROR: ($check_script) not found. Are you running from the repo root?"
        exit 1
    }

    let hook_content = $"#!/bin/sh\n# Auto-installed pre-push guard: blocks pushing var/mail/spool data\nexec nu ($check_script)\n"
    $hook_content | save --force $hook_path
    chmod 0755 $hook_path
    print $"Installed pre-push hook at ($hook_path)"
    print "Test with: git push --dry-run"
}
