#!/bin/bash

cd "$(dirname "$0")/.."
cargo build --quiet || exit 1

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local expected_exit="$2"
    local input="$3"
    shift 3
    local expected_stderr=("$@")

    local output stderr exit_code
    output=$(cargo run --quiet -- sanitize "$input" 2>$TMPDIR/stderr) && exit_code=0 || exit_code=$?
    stderr=$(cat $TMPDIR/stderr)
    rm -f $TMPDIR/stderr

    local failed=0

    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        echo "FAIL: $name - expected exit $expected_exit, got $exit_code"
        failed=1
    fi

    for pattern in "${expected_stderr[@]}"; do
        if [[ ! "$stderr" =~ $pattern ]]; then
            echo "FAIL: $name - stderr missing pattern: $pattern"
            echo "  got: $stderr"
            failed=1
        fi
    done

    if [[ "$failed" -eq 0 ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

run_test_output() {
    local name="$1"
    local input="$2"
    local expected_file="$3"

    cargo run --quiet -- sanitize "$input" 2>/dev/null > $TMPDIR/output

    if diff -q $TMPDIR/output "$expected_file" > /dev/null 2>&1; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name - output mismatch"
        diff $TMPDIR/output "$expected_file"
        FAIL=$((FAIL + 1))
    fi
    rm -f $TMPDIR/output
}

echo "Running sanitize tests..."
echo

# Success cases
run_test "CRLF normalization" 0 tests/fixtures/crlf.nsv "fixed 3 Windows line endings"
run_test "LF passthrough" 0 tests/fixtures/lf.nsv
run_test "BOM + CRLF" 0 tests/fixtures/bom_crlf.nsv "stripped Windows BOM" "fixed 2 Windows line endings"
run_test "BOM + LF" 0 tests/fixtures/bom_lf.nsv "stripped Windows BOM"
run_test "Empty file" 0 tests/fixtures/empty.nsv
run_test "No newlines" 0 tests/fixtures/no_newlines.nsv

# Output verification (CRLF normalized should match LF file)
run_test_output "CRLF becomes LF" tests/fixtures/crlf.nsv tests/fixtures/lf.nsv
run_test_output "LF unchanged" tests/fixtures/lf.nsv tests/fixtures/lf.nsv

# Error cases
run_test "Mixed line endings" 1 tests/fixtures/mixed.nsv "mixed line endings"
run_test "Bare CR" 1 tests/fixtures/bare_cr.nsv "bare CR"

# Stdin tests
printf 'a\r\nb\r\n' | cargo run --quiet -- sanitize 2>/dev/null > $TMPDIR/output
printf 'a\nb\n' > $TMPDIR/expected
if diff -q $TMPDIR/output $TMPDIR/expected > /dev/null 2>&1; then
    echo "PASS: stdin"
    PASS=$((PASS + 1))
else
    echo "FAIL: stdin"
    FAIL=$((FAIL + 1))
fi

printf 'a\r\nb\r\n' | cargo run --quiet -- sanitize - 2>/dev/null > $TMPDIR/output
if diff -q $TMPDIR/output $TMPDIR/expected > /dev/null 2>&1; then
    echo "PASS: stdin with dash"
    PASS=$((PASS + 1))
else
    echo "FAIL: stdin with dash"
    FAIL=$((FAIL + 1))
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
