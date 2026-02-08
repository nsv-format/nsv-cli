#!/bin/bash

cd "$(dirname "$0")/.."
cargo build --quiet || exit 1

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# run_test NAME FILE EXPECTED_STDOUT
#   Runs stats on FILE, checks exit 0, compares stdout exactly.
run_test() {
    local name="$1"
    local file="$2"
    local expected="$3"

    local stdout stderr exit_code
    stdout=$(cargo run --quiet -- stats "$file" 2>$TMPDIR/stderr) && exit_code=0 || exit_code=$?
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

echo "Running stats tests..."
echo

F=tests/fixtures

# ── Empty input ──

run_test "empty file" $F/empty.nsv \
"rows: 0
cells: 0
min_arity: 0
max_arity: 0
is_table: true
max_cell_bytes: 0"

# ── 3×4 table ──

run_test "3x4 table" $F/table_3x4.nsv \
"rows: 3
cells: 12
min_arity: 4
max_arity: 4
is_table: true
max_cell_bytes: 1"

# ── 2×2 table ──

run_test "2x2 table" $F/table.nsv \
"rows: 2
cells: 4
min_arity: 2
max_arity: 2
is_table: true
max_cell_bytes: 1"

# ── Ragged data ──

run_test "ragged data" $F/ragged.nsv \
"rows: 3
cells: 6
min_arity: 1
max_arity: 3
is_table: false
max_cell_bytes: 1"

# ── Multiline cell (unescaped content) ──

run_test "multiline cell" $F/multiline_cell.nsv \
"rows: 1
cells: 2
min_arity: 2
max_arity: 2
is_table: true
max_cell_bytes: 45"

# ── BOM is silently stripped ──

run_test "BOM file (silent)" $F/bom_lf.nsv \
"rows: 1
cells: 2
min_arity: 2
max_arity: 2
is_table: true
max_cell_bytes: 5"

# ── CRLF is silently normalized ──

run_test "CRLF file (silent)" $F/crlf.nsv \
"rows: 1
cells: 3
min_arity: 3
max_arity: 3
is_table: true
max_cell_bytes: 5"

# ── BOM + CRLF combined ──

run_test "BOM+CRLF file (silent)" $F/bom_crlf.nsv \
"rows: 1
cells: 2
min_arity: 2
max_arity: 2
is_table: true
max_cell_bytes: 5"

# ── Not a table ──

run_test "not a table" $F/not_a_table.nsv \
"rows: 2
cells: 3
min_arity: 1
max_arity: 2
is_table: false
max_cell_bytes: 1"

# ── stdin ──

stdout=$(printf 'x\ny\n\nz\nw\n\n' | cargo run --quiet -- stats 2>/dev/null)
expected="rows: 2
cells: 4
min_arity: 2
max_arity: 2
is_table: true
max_cell_bytes: 1"
if [[ "$stdout" == "$expected" ]]; then
    echo "PASS: stdin"
    PASS=$((PASS + 1))
else
    echo "FAIL: stdin - stdout mismatch"
    diff <(echo "$stdout") <(echo "$expected")
    FAIL=$((FAIL + 1))
fi

# ── stdin with dash ──

stdout=$(printf 'a\n\nb\nc\n\n' | cargo run --quiet -- stats - 2>/dev/null)
expected="rows: 2
cells: 3
min_arity: 1
max_arity: 2
is_table: false
max_cell_bytes: 1"
if [[ "$stdout" == "$expected" ]]; then
    echo "PASS: stdin with dash"
    PASS=$((PASS + 1))
else
    echo "FAIL: stdin with dash - stdout mismatch"
    diff <(echo "$stdout") <(echo "$expected")
    FAIL=$((FAIL + 1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
