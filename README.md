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

```sh
nsv t table.nsv
cat table.nsv | nsv t
```

The `transpose` command:
- Requires table input (all rows must have equal arity)
- Errors on ragged data
- Is its own inverse: `nsv t | nsv t` recovers the original

### Stats

Structural overview of an NSV file.

```sh
$ nsv stats data.nsv
rows: 3
cells: 12
min_arity: 4
max_arity: 4
is_table: true
max_cell_bytes: 1
```
