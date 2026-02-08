#!/bin/bash

cd "$(dirname "$0")/.."
cargo build --quiet || exit 1

PASS=0
FAIL=0

# run_test NAME EXIT_CODE INPUT_BYTES [STDERR_PATTERN...]
#   INPUT_BYTES is passed via stdin (use printf for control)
#   Extra args are regex patterns that must all appear in stderr
run_test() {
    local name="$1"
    local expected_exit="$2"
    local input="$3"
    shift 3
    local expected_stderr=("$@")

    local stderr exit_code
    echo -ne "$input" | cargo run --quiet -- validate 2>tmp_stderr && exit_code=0 || exit_code=$?
    stderr=$(cat tmp_stderr)
    rm -f tmp_stderr

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

# Same but with extra args passed to validate
run_test_args() {
    local name="$1"
    local expected_exit="$2"
    local input="$3"
    local args="$4"
    shift 4
    local expected_stderr=("$@")

    local stderr exit_code
    echo -ne "$input" | cargo run --quiet -- validate $args 2>tmp_stderr && exit_code=0 || exit_code=$?
    stderr=$(cat tmp_stderr)
    rm -f tmp_stderr

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

echo "Running validate tests..."
echo

# ── Exit codes ──

run_test "clean file" 0 "a\nb\n\n"
run_test "empty file" 0 ""
run_test "warnings exit 1" 1 "hello\\\\t\n\n" "unknown escape"
run_test "bare CR exits 1" 1 "a\rb\n" "bare CR"
run_test "mixed endings exits 1" 1 "a\na\r\n" "mixed line endings"

# ── BOM detection ──

run_test "BOM warns" 1 "\xEF\xBB\xBFa\nb\n\n" "UTF-8 BOM"
run_test "BOM does not block structural checks" 1 \
    "\xEF\xBB\xBFhello\\\\t\n\n" \
    "UTF-8 BOM" "unknown escape"

# ── CRLF detection ──

run_test "CRLF warns" 1 "a\r\nb\r\n\r\n" "CRLF line endings"
run_test "CRLF does not block structural checks" 1 \
    "hello\\\\t\r\n\r\n" \
    "CRLF line endings" "unknown escape"

# ── Structural warnings ──

run_test "unknown escape" 1 "hello\\\\tworld\n\n" \
    "unknown escape sequence"
run_test "dangling backslash" 1 "text\\\\\n\n" \
    "dangling backslash"
run_test "missing terminal newline" 1 "hello" \
    "missing terminal newline"

# ── Byte offset: plain LF, no BOM ──
# "hello\t" = h(0) e(1) l(2) l(3) o(4) \(5) t(6)
# check() col for \ is 6 (1-indexed byte col), pos is 5
run_test "byte offset plain" 1 "hello\\\\tworld\n\n" \
    "line 1, col 6, byte 5"

# ── Byte offset: with BOM ──
# BOM adds 3 to original byte offset
# Same escape at clean pos 5 → original byte 5+3=8
run_test "byte offset with BOM" 1 "\xEF\xBB\xBFhello\\\\tworld\n\n" \
    "line 1, col 6, byte 8"

# ── Byte offset: with CRLF ──
# Line 1: "ok\r\n" (4 bytes original), Line 2: "hello\t\r\n"
# In clean data: "ok\n" (3 bytes), "hello\t\n" — \ at clean pos 8, line 2
# Original byte = 8 + 0 (no BOM) + 1 (line 2, one prior CRLF) = 9
run_test "byte offset with CRLF" 1 "ok\r\nhello\\\\t\r\n\r\n" \
    "line 2, col 6, byte 9"

# ── Byte offset: BOM + CRLF ──
# BOM(3) + "ok\r\n"(4) + "hello\t\r\n"
# Clean pos of \ = 8, original = 8 + 3 (BOM) + 1 (line 2 CRLF) = 12
run_test "byte offset with BOM and CRLF" 1 "\xEF\xBB\xBFok\r\nhello\\\\t\r\n\r\n" \
    "line 2, col 6, byte 12"

# ── Char col with multi-byte UTF-8 ──
# é (C3 A9, 2 bytes) then "hello\t"
# Byte col of \ = 8 (2 + 5 + 1), char col = 7 (é + hello + \)
run_test "char col with multibyte UTF-8" 1 "\xC3\xA9hello\\\\tworld\n\n" \
    "line 1, col 7, byte 7"

# ── Warning on line 2, ASCII only ──
# Line 1: "ok\n", Line 2: "hello\t\n"
# Clean pos of \ = 8 (3 + 5), line 2 col 6, original byte 8
run_test "warning on line 2" 1 "ok\nhello\\\\tworld\n\n" \
    "line 2, col 6, byte 8"

# ── Table check ──

run_test_args "valid table" 0 "a\nb\n\nc\nd\n\n" "--table"
run_test_args "empty file is valid table" 0 "" "--table"
run_test_args "not a table" 1 "a\nb\n\nc\n\n" "--table" \
    "not a table.*min 1.*max 2"
run_test_args "table check reports alongside warnings" 1 \
    "a\\\\t\nb\n\nc\n\n" "--table" \
    "unknown escape" "not a table"

# ── stdin and file arg ──

echo -ne "a\nb\n\n" > tmp_valid.nsv
cargo run --quiet -- validate tmp_valid.nsv 2>tmp_stderr && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    echo "PASS: file argument"
    PASS=$((PASS + 1))
else
    echo "FAIL: file argument - expected exit 0, got $exit_code"
    FAIL=$((FAIL + 1))
fi
rm -f tmp_valid.nsv tmp_stderr

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
