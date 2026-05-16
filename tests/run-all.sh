#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
for f in tests/*-test.nu; do
    printf "running %s ... " "$f"
    _exit=0; nu "$f" 2>&1 || _exit=$?
    if [ $_exit -eq 77 ]; then
        echo "skip"
        SKIP=$((SKIP + 1))
    elif [ $_exit -ne 0 ]; then
        echo "FAILED"
        FAIL=$((FAIL + 1))
    else
        echo "ok"
        PASS=$((PASS + 1))
    fi
done
echo ""
echo "results: $PASS passed, $SKIP skipped, $FAIL failed"
[ $FAIL -eq 0 ]
