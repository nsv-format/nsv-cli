# NSV, CLI tool

Command-line tool for the [NSV (Newline-Separated Values)](https://nsv-format.org) format.

## Installation

To install (or update) from crates.io, run
```sh
cargo install nsv-cli
```

## Usage

```sh
nsv help     # proper summary
nsv version  # this tool + underlying parser's versions
```

### Sanitize

Clean up files corrupted by Microsoft's software.

```sh
# From file
nsv sanitize dirty.nsv > clean.nsv

# From stdin
cat dirty.nsv | nsv sanitize > clean.nsv
```

The `sanitize` command:
- Strips UTF-8 BOM
- Normalizes CRLF to LF
- Errors on bare CR or mixed line endings
- NSV-agnostic, can be used on any text file

### Validate

Check encoding and structural correctness.

```sh
nsv validate data.nsv
nsv validate --table data.nsv
```

The `validate` command:
- Checks for [rejected strings](https://github.com/nsv-format/nsv/blob/master/README.md#handling-rejected-strings): dangling backslashes, unknown escape sequences, missing termination
- Reports byte offsets and UTF-8-aware character columns for each issue (rely on byte offsets if you're not using UTF-8)
- with `--table`, checks that all rows have equal length
- Exits with 0 on success, 1 on warnings or errors

### Transpose

Transpose a table.  
Both `t` and `transpose` are valid, prefer the latter for long-living scripts.

```sh
nsv t table.nsv
cat table.nsv | nsv t
```

The `transpose` command:
- Requires table input (all rows must have equal arity), errors on ragged data
- Allocates full input in memory (once, but still)

### Stats

Structural overview of an NSV file. Output is itself NSV (2-column key-value table).

```sh
$ nsv stats data.nsv
rows
3

cells
12

min_arity
4

max_arity
4

is_table
true

max_cell_bytes
1

```

### Lift / Unlift

Apply or reverse NSV escaping on each line.
Both `l`/`u` and `lift`/`unlift` are valid, prefer the latter for long-living scripts.

```sh
# Lift: escape each line (empty lines become \, backslashes double, etc.)
nsv lift data.nsv

# Unlift: unescape each line (inverse of lift)
nsv unlift data.nsv

# Roundtrip: unlift(lift(x)) == x
nsv lift data.nsv | nsv unlift
```

The `lift` command:
- Applies `escape` to each line of input
- Turns empty lines into `\` (the NSV empty cell token)
- Is the line-level equivalent of the lift operation from the [ENSV spec](https://github.com/nsv-format/nsv/blob/master/ensv.md)

The `unlift` command:
- Applies `unescape` to each line of input
- Is the exact inverse of `lift`
