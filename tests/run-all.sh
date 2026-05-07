#!/bin/sh
set -e
PASS=0
FAIL=0
for f in tests/*-test.nu; do
    printf "running %s ... " "$f"
    if nu "$f" > /dev/null 2>&1; then
        echo "ok"
        PASS=$((PASS + 1))
    else
        echo "FAILED"
        FAIL=$((FAIL + 1))
    fi
done
echo ""
echo "results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
