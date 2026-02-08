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
