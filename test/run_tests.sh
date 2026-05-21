#!/usr/bin/env bash
# pg_rollup test runner.
#
# Prerequisites:
#   * PGROLLUP_DB env var pointing at a Postgres 15+ database
#   * pg_rollup installed there (psql "$PGROLLUP_DB" -f install.sql)
#   * psql on PATH
#
# Each test file is a self-contained psql script that uses RAISE EXCEPTION
# for assertions. Any failure aborts that file (via ON_ERROR_STOP) and the
# runner reports it with a non-zero exit code.

set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${PGROLLUP_DB:-}" ]]; then
    echo "ERROR: PGROLLUP_DB is not set." >&2
    echo "       export PGROLLUP_DB=postgresql://..." >&2
    exit 2
fi

PSQL=(psql "$PGROLLUP_DB" -v ON_ERROR_STOP=1 --no-psqlrc --quiet)

run_file() {
    local label="$1"
    local file="$2"
    printf '── %-30s' "$label"
    if "${PSQL[@]}" -f "$file" > /tmp/pgrollup_test.log 2>&1; then
        echo "ok"
    else
        echo "FAIL"
        echo "----- output -----"
        cat /tmp/pgrollup_test.log
        echo "----- end --------"
        return 1
    fi
}

failures=0

run_file "setup"      setup.sql      || failures=$((failures + 1))
for f in test_*.sql; do
    [[ -e "$f" ]] || continue
    run_file "${f%.sql}" "$f" || failures=$((failures + 1))
done

echo
if [[ $failures -eq 0 ]]; then
    echo "All tests passed."
else
    echo "$failures test file(s) failed."
    exit 1
fi
