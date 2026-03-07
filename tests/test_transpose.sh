#!/bin/bash

cd "$(dirname "$0")/.."
cargo build --quiet || exit 1

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# run_test NAME STDIN_OR_FILE EXPECTED_STDOUT [USE_STDIN]
#   Runs transpose, checks exit 0, compares stdout exactly.
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    local use_stdin="$4"

    local stdout stderr exit_code

    if [[ "$use_stdin" == "stdin" ]]; then
        stdout=$(printf '%s' "$input" | cargo run --quiet -- transpose 2>$TMPDIR/stderr) && exit_code=0 || exit_code=$?
    else
        stdout=$(cargo run --quiet -- transpose "$input" 2>$TMPDIR/stderr) && exit_code=0 || exit_code=$?
    fi
    stderr=$(cat $TMPDIR/stderr)
    rm -f $TMPDIR/stderr

    local failed=0

    if [[ "$exit_code" -ne 0 ]]; then
        echo "FAIL: $name - expected exit 0, got $exit_code"
        failed=1
    fi

    if [[ -n "$stderr" ]]; then
        echo "FAIL: $name - unexpected stderr: $stderr"
        failed=1
    fi

    if [[ "$stdout" != "$expected" ]]; then
        echo "FAIL: $name - stdout mismatch"
        diff <(echo "$stdout") <(echo "$expected")
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

echo "Running transpose tests..."
echo

F=tests/fixtures

# ── Empty input ──

run_test "empty file" $F/empty.nsv ""

# ── 2×2 table → 2×2 table ──

run_test "2x2 table" $F/table.nsv "$(printf 'a\nc\n\nb\nd\n\n')"

# ── 3×4 table → 4×3 table ──

run_test "3x4 table" $F/table_3x4.nsv "$(printf 'a\ne\ni\n\nb\nf\nj\n\nc\ng\nk\n\nd\nh\nl\n\n')"

# ── Ragged rows rejected ──

cargo run --quiet -- transpose $F/ragged.nsv >/dev/null 2>$TMPDIR/stderr && exit_code=0 || exit_code=$?
stderr=$(cat $TMPDIR/stderr)
rm -f $TMPDIR/stderr
if [[ "$exit_code" -eq 1 ]] && [[ "$stderr" == *"not a table"* ]]; then
    echo "PASS: ragged rows rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL: ragged rows rejected - exit=$exit_code stderr=$stderr"
    FAIL=$((FAIL + 1))
fi

# ── Single row → single column ──
# Input: one row with 3 cells [x,y,z]

run_test "single row to column" "$(printf 'x\ny\nz\n\n')" "$(printf 'x\n\ny\n\nz\n\n')" "stdin"

# ── Single column → single row ──
# Input: two rows each with one cell
run_test "single column to row" "$(printf 'p\n\nq\n\n')" "$(printf 'p\nq\n\n')" "stdin"

# ── stdin input ──

run_test "stdin" "$(printf 'a\nb\n\nc\nd\n\n')" "$(printf 'a\nc\n\nb\nd\n\n')" "stdin"

# ── Roundtrip: transpose(transpose(x)) == x ──

# Use table.nsv: transpose twice should recover original
first=$(cargo run --quiet -- transpose $F/table.nsv 2>/dev/null)
second=$(printf '%s' "$first" | cargo run --quiet -- transpose 2>/dev/null)
original=$(cat $F/table.nsv)
if [[ "$second" == "$original" ]]; then
    echo "PASS: roundtrip transpose(transpose(x)) == x"
    PASS=$((PASS + 1))
else
    echo "FAIL: roundtrip transpose(transpose(x)) == x"
    diff <(echo "$second") <(echo "$original")
    FAIL=$((FAIL + 1))
fi

# ── Roundtrip with 3×4 table ──

first=$(cargo run --quiet -- transpose $F/table_3x4.nsv 2>/dev/null)
second=$(printf '%s' "$first" | cargo run --quiet -- transpose 2>/dev/null)
original=$(cat $F/table_3x4.nsv)
if [[ "$second" == "$original" ]]; then
    echo "PASS: roundtrip 3x4"
    PASS=$((PASS + 1))
else
    echo "FAIL: roundtrip 3x4"
    diff <(echo "$second") <(echo "$original")
    FAIL=$((FAIL + 1))
fi

# ── Multiline cell (escaped content preserved) ──

stdout=$(cargo run --quiet -- transpose $F/multiline_cell.nsv 2>/dev/null)
exit_code=$?
if [[ "$exit_code" -eq 0 ]] && [[ -n "$stdout" ]]; then
    # Validate the transposed output is valid NSV
    echo "$stdout" | cargo run --quiet -- validate 2>/dev/null && validate_exit=0 || validate_exit=$?
    if [[ "$validate_exit" -eq 0 ]]; then
        echo "PASS: multiline cell transposed is valid NSV"
        PASS=$((PASS + 1))
    else
        echo "FAIL: multiline cell transposed is not valid NSV"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL: multiline cell transpose failed"
    FAIL=$((FAIL + 1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
