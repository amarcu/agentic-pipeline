#!/bin/bash
# Entry point: runs every test in tests/unit/ and tests/static/.
# Usage:
#   tests/run.sh                # all tests
#   tests/run.sh unit           # only unit tests
#   tests/run.sh static         # only static tests
#   tests/run.sh test_name      # run only tests matching a substring

set -uo pipefail

TESTS_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

# Parse filter
FILTER="${1:-}"
SUITES=()
case "$FILTER" in
    unit)    SUITES=("$TESTS_DIR/unit") ;;
    static)  SUITES=("$TESTS_DIR/static") ;;
    "")      SUITES=("$TESTS_DIR/unit" "$TESTS_DIR/static") ;;
    *)       SUITES=("$TESTS_DIR/unit" "$TESTS_DIR/static") ;;
esac

echo "agentic-skills test suite"
echo "─────────────────────────────────────────────────────────────────"

# Source every test_*.sh in the chosen suites. Each file contributes its
# test_* functions to the current shell environment.
for suite_dir in "${SUITES[@]}"; do
    [[ -d "$suite_dir" ]] || continue
    suite_name=$(/usr/bin/basename "$suite_dir")
    echo ""
    echo "[$suite_name]"

    # Collect function names BEFORE sourcing, so we can diff after
    before=$(compgen -A function | /usr/bin/grep '^test_' || true)

    for test_file in "$suite_dir"/test_*.sh; do
        [[ -f "$test_file" ]] || continue
        . "$test_file"
    done

    after=$(compgen -A function | /usr/bin/grep '^test_' || true)

    # New functions = the ones this suite added
    new_fns=$(/usr/bin/comm -13 <(echo "$before" | /usr/bin/sort) <(echo "$after" | /usr/bin/sort))

    # If a substring filter was given (and it wasn't a suite name), narrow further
    if [[ -n "$FILTER" && "$FILTER" != "unit" && "$FILTER" != "static" ]]; then
        new_fns=$(echo "$new_fns" | /usr/bin/grep -i "$FILTER" || true)
    fi

    for fn in $new_fns; do
        run_test "$fn"
    done
done

print_test_summary
