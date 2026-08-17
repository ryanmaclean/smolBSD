#!/bin/sh
# coord-run.sh — Loop runner for the smolfire coordinator FSM.
#
# Invokes `nu bin/coord-tick.nu` repeatedly, sleeping between ticks.
# Supports an emergency-stop mechanism via a HALT sentinel file.
#
# Usage:
#   sh bin/coord-run.sh
#
# Environment variables (all optional):
#   ROOT           Repo root directory              (default: .)
#   INTERVAL       Seconds between normal ticks     (default: 60)
#   HALT_INTERVAL  Seconds to sleep when halted     (default: 10)
#   MAX_TICKS      Unused; kept for compat          (default: 100)
#   STATE_FILE     Path to persisted FSM state      (default: var/run/coord-state.toml)
#   SPOOL          Path to mbox spool directory     (default: var/mail/spool)
#
# Example:
#   ROOT=. INTERVAL=30 sh bin/coord-run.sh

ROOT="${ROOT:-.}"
INTERVAL="${INTERVAL:-60}"
HALT_INTERVAL="${HALT_INTERVAL:-10}"
MAX_TICKS="${MAX_TICKS:-100}"
STATE_FILE="${STATE_FILE:-var/run/coord-state.toml}"
SPOOL="${SPOOL:-var/mail/spool}"

export ROOT INTERVAL HALT_INTERVAL MAX_TICKS STATE_FILE SPOOL

# Clean shutdown handler
_shutdown() {
    echo "coord-run: shutting down"
    exit 0
}
trap '_shutdown' INT TERM

# Timestamp helper
_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

tick=0

while true; do
    tick=$((tick + 1))

    # Warn every 1000 ticks
    remainder=$((tick % 1000))
    if [ "$remainder" -eq 0 ]; then
        echo "coord-run: WARNING: reached $tick ticks — consider restarting if memory usage is high"
    fi

    echo "[$(_ts)] tick $tick"

    if [ -f "${ROOT}/var/mail/HALT" ]; then
        echo "coord-run: HALT sentinel present — coordinator paused; sleeping ${HALT_INTERVAL}s"
        sleep "${HALT_INTERVAL}"
    else
        nu "${ROOT}/bin/coord-tick.nu"
        sleep "${INTERVAL}"
    fi
done
