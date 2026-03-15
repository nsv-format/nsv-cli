#!/bin/bash

cd "$(dirname "$0")/.."
cargo build --quiet || exit 1

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# run_test NAME INPUT_FILE EXPECTED_FILE COMMAND
#   Compares output byte-for-byte using files to avoid command substitution issues.
run_test() {
    local name="$1"
    local input_file="$2"
    local expected_file="$3"
    local cmd="$4"

    cargo run --quiet -- $cmd "$input_file" > "$TMPDIR/actual" 2>"$TMPDIR/stderr"
    local exit_code=$?
    local stderr
    stderr=$(cat "$TMPDIR/stderr")

    local failed=0

    if [[ "$exit_code" -ne 0 ]]; then
        echo "FAIL: $name - expected exit 0, got $exit_code"
        failed=1
    fi

    if [[ -n "$stderr" ]]; then
        echo "FAIL: $name - unexpected stderr: $stderr"
        failed=1
    fi

    if ! cmp -s "$TMPDIR/actual" "$expected_file"; then
        echo "FAIL: $name - output mismatch"
        echo "  expected:"; od -c "$expected_file" | head -3
        echo "  actual:";   od -c "$TMPDIR/actual" | head -3
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

# roundtrip_test NAME INPUT_FILE
#   Checks unlift(lift(input)) == input
roundtrip_test() {
    local name="$1"
    local input_file="$2"

    cargo run --quiet -- lift "$input_file" 2>/dev/null | cargo run --quiet -- unlift > "$TMPDIR/rt_actual" 2>/dev/null
    if cmp -s "$TMPDIR/rt_actual" "$input_file"; then
        echo "PASS: roundtrip $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: roundtrip $name"
        echo "  expected:"; od -c "$input_file" | head -3
        echo "  actual:";   od -c "$TMPDIR/rt_actual" | head -3
        FAIL=$((FAIL + 1))
    fi
}

echo "Running lift/unlift tests..."
echo

# ── Prepare fixtures ──

printf ''                       > "$TMPDIR/empty"
printf 'hello\n'               > "$TMPDIR/plain"
printf '\n'                    > "$TMPDIR/single_lf"
printf '\\\n'                  > "$TMPDIR/backslash_lf"
printf 'a\\b\n'               > "$TMPDIR/has_backslash"
printf 'a\\\\b\n'             > "$TMPDIR/has_double_backslash"
printf 'a\nb\n\nc\nd\n\n'     > "$TMPDIR/nsv_2x2"
printf 'a\nb\n\\\nc\nd\n\\\n' > "$TMPDIR/nsv_2x2_lifted"
printf '\n\n\n'                > "$TMPDIR/three_lf"
printf '\\\n\\\n\\\n'         > "$TMPDIR/three_backslash"
printf 'hello'                 > "$TMPDIR/no_trailing_lf"
printf 'hello\n'              > "$TMPDIR/with_trailing_lf"

# ── Empty input ──

run_test "lift empty" "$TMPDIR/empty" "$TMPDIR/empty" "lift"
run_test "unlift empty" "$TMPDIR/empty" "$TMPDIR/empty" "unlift"

# ── Single plain line ──

run_test "lift plain" "$TMPDIR/plain" "$TMPDIR/plain" "lift"
run_test "unlift plain" "$TMPDIR/plain" "$TMPDIR/plain" "unlift"

# ── Single empty line (just LF) → backslash ──

run_test "lift single LF" "$TMPDIR/single_lf" "$TMPDIR/backslash_lf" "lift"
run_test "unlift backslash to LF" "$TMPDIR/backslash_lf" "$TMPDIR/single_lf" "unlift"

# ── Backslash escaping ──

run_test "lift backslash" "$TMPDIR/has_backslash" "$TMPDIR/has_double_backslash" "lift"
run_test "unlift double backslash" "$TMPDIR/has_double_backslash" "$TMPDIR/has_backslash" "unlift"

# ── NSV structure: lift turns empty lines into backslash lines ──

run_test "lift NSV 2x2" "$TMPDIR/nsv_2x2" "$TMPDIR/nsv_2x2_lifted" "lift"
run_test "unlift to NSV 2x2" "$TMPDIR/nsv_2x2_lifted" "$TMPDIR/nsv_2x2" "unlift"

# ── Multiple empty lines ──

run_test "lift three LFs" "$TMPDIR/three_lf" "$TMPDIR/three_backslash" "lift"
run_test "unlift three backslashes" "$TMPDIR/three_backslash" "$TMPDIR/three_lf" "unlift"

# ── No trailing newline → output still gets trailing newline ──

run_test "lift no trailing LF" "$TMPDIR/no_trailing_lf" "$TMPDIR/with_trailing_lf" "lift"
run_test "unlift no trailing LF" "$TMPDIR/no_trailing_lf" "$TMPDIR/with_trailing_lf" "unlift"

# ── Roundtrips ──

roundtrip_test "plain" "$TMPDIR/plain"
roundtrip_test "nsv 2x2" "$TMPDIR/nsv_2x2"
roundtrip_test "three LFs" "$TMPDIR/three_lf"
roundtrip_test "single LF" "$TMPDIR/single_lf"

# ── Stdin works ──

cargo run --quiet -- lift < "$TMPDIR/nsv_2x2" > "$TMPDIR/stdin_actual" 2>/dev/null
if cmp -s "$TMPDIR/stdin_actual" "$TMPDIR/nsv_2x2_lifted"; then
    echo "PASS: lift via stdin"
    PASS=$((PASS + 1))
else
    echo "FAIL: lift via stdin"
    FAIL=$((FAIL + 1))
fi

# ── Roundtrip with existing NSV fixtures ──

F=tests/fixtures
for f in $F/table.nsv $F/table_3x4.nsv $F/multiline_cell.nsv $F/lf.nsv; do
    if [[ -f "$f" ]]; then
        roundtrip_test "fixture $(basename $f)" "$f"
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
