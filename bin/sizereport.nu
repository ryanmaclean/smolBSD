#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/sizereport.nu — turn the SIZEREPORT lines from a build log into tables.
#
# The release confs (release/tools/smolbsd-qemu*.conf) print a SIZEREPORT
# block at the end of vm_extra_pre_umount: rootfs total, directories to
# depth 2, the 30 largest files, and installed packages by size. That lands
# in the in-VM make log, which CI ships out as smolbsd-build-vm.log. This
# script parses those lines back into ranked tables so a diet round starts
# from data, not guesses.
#
# Usage: nu bin/sizereport.nu [<log>] [--top N]
#   <log>  build log to parse (default: smolbsd-build-vm.log)
#   --top  rows per table (default: 15)
#
# Exit 0 = report printed, 1 = log exists but has no SIZEREPORT lines
# (build predates the instrumentation), 0 with SKIP if the log is absent.
#
# Covered by CI: tests/sizereport-test.nu runs this against
# tests/fixtures/sizereport-sample.log on the pinned nu.

# Lines of one section: everything after its '==== name ====' header up to
# the next '====' header.
def section [rl: list<string>, name: string] {
    let start = ($rl | enumerate | where {|r| $r.item =~ $name} | get -o 0.index)
    if $start == null {
        []
    } else {
        $rl | skip ($start + 1) | take while {|l| not ($l =~ '^====')}
    }
}

# '<number> <path>' rows -> table, largest first. du/pkg output is
# "size<TAB or spaces>name"; anything that doesn't match is dropped.
def rows [body: list<string>] {
    $body
        | each {|l| $l | parse --regex '^\s*(?<size>\d+)\s+(?<name>.+)$' }
        | flatten
        | each {|r| {size: ($r.size | into int), name: ($r.name | str trim)} }
        | sort-by --reverse size
}

def main [
    log: string = "smolbsd-build-vm.log"   # build log to parse
    --top: int = 15                        # rows per table
] {
    if not ($log | path exists) {
        print $"sizereport: SKIP — ($log) not found"
        exit 0
    }

    # Strip the 'SIZEREPORT: ' prefix; ignore every other log line.
    let rl = open --raw $log
        | lines
        | where {|l| $l | str starts-with 'SIZEREPORT: '}
        | each {|l| $l | str substring 12..}

    if ($rl | is-empty) {
        print $"sizereport: no SIZEREPORT lines in ($log) — build predates the instrumentation?"
        exit 1
    }

    let total = (rows (section $rl 'rootfs total') | get -o 0)
    if $total != null {
        print $"rootfs total: ($total.size) MiB \(($total.name)\)"
    }

    print ""
    print $"== directories to depth 2, MiB, top ($top) =="
    print (rows (section $rl 'directories to depth 2') | first $top)

    print ""
    print $"== largest files, KiB, top ($top) =="
    print (rows (section $rl 'largest files') | first $top)

    print ""
    print $"== installed packages, MiB, top ($top) =="
    print (rows (section $rl 'installed packages')
        | each {|r| {size: ($r.size / 1048576 | math round --precision 1), name: $r.name} }
        | first $top)
}
