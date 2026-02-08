use std::fs::File;
use std::io::{self, Read, Write};

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "nsv")]
#[command(about = "Command-line tool for the NSV format")]
#[command(after_help = "Format specification: https://nsv-format.org")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Print version information
    Version,

    /// Sanitize NSV data: strip UTF-8 BOM, normalize CRLF to LF
    Sanitize {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,
    },

    /// Validate NSV data: check encoding, structure, and optionally table-ness
    Validate {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,

        /// Check that all rows have the same length (i.e. the data forms a table)
        #[arg(long)]
        table: bool,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Version => {
            println!("nsv-cli {}", env!("CARGO_PKG_VERSION"));
            println!("nsv     {}", nsv::VERSION);
        }
        Commands::Sanitize { file } => {
            if let Err(e) = sanitize(file) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
        }
        Commands::Validate { file, table } => {
            std::process::exit(validate(file, table));
        }
    }
}

fn read_input(file: &Option<String>) -> Vec<u8> {
    let mut data = Vec::new();
    match file.as_deref() {
        Some(path) if path != "-" => {
            File::open(path)
                .unwrap_or_else(|e| panic!("cannot open '{}': {}", path, e))
                .read_to_end(&mut data)
                .unwrap_or_else(|e| panic!("read error: {}", e));
        }
        _ => {
            io::stdin()
                .read_to_end(&mut data)
                .unwrap_or_else(|e| panic!("read error: {}", e));
        }
    };
    data
}

/// Sanitize NSV data.
///
/// - Strips UTF-8 BOM (EF BB BF)
/// - Detects line ending style from first occurrence
/// - Errors on bare CR or mixed line endings
/// - Normalizes CRLF to LF
///
/// Currently reads the entire file,
/// will fix once streaming is exposed in the parser
fn sanitize(file: Option<String>) -> Result<(), String> {
    let data = read_input(&file);

    let mut start = 0;
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        eprintln!("stripped Windows BOM");
        start = 3;
    }
    let (output, crlf_count) = process_line_endings(&data, start)?;
    if crlf_count > 0 {
        eprintln!("fixed {} Windows line endings", crlf_count);
    }
    io::stdout()
        .write_all(&output)
        .map_err(|e| format!("write error: {}", e))?;
    Ok(())
}

/// Infers style from first line ending, errors on bare CR or mixed styles.
/// Returns (sanitized bytes, number of CRLFs normalized).
fn process_line_endings(data: &[u8], start: usize) -> Result<(Vec<u8>, u64), String> {
    let mut output = Vec::with_capacity(data.len() - start);
    let mut first_crlf: Option<usize> = None;
    let mut first_lf: Option<usize> = None;
    let mut crlf_count: u64 = 0;
    let mut i = start;

    while i < data.len() {
        match data[i] {
            b'\n' => {
                if let Some(crlf_pos) = first_crlf {
                    return Err(format!("mixed line endings — inferred CRLF at byte {}, found LF at byte {}", crlf_pos, i));
                }
                first_lf.get_or_insert(i);
                output.push(b'\n');
            }
            b'\r' if data.get(i + 1) == Some(&b'\n') => {
                if let Some(lf_pos) = first_lf {
                    return Err(format!("mixed line endings — inferred LF at byte {}, found CRLF at byte {}", lf_pos, i));
                }
                first_crlf.get_or_insert(i);
                output.push(b'\n');
                crlf_count += 1;
                i += 1;
            }
            b'\r' => return Err(format!("bare CR line ending detected at byte {}", i)),
            byte => output.push(byte),
        }
        i += 1;
    }

    Ok((output, crlf_count))
}

/// Validate NSV data. Returns the process exit code.
///
/// Sanitizes internally (strip BOM, normalize CRLF) so that structural
/// checks run on clean data and reported positions match what the user
/// would see after `nsv sanitize`. Corruption is detected from the
/// length delta and reported as warnings.
fn validate(file: Option<String>, table: bool) -> i32 {
    let raw = read_input(&file);
    let mut exit_code = 0;

    // Internal sanitization
    let had_bom = raw.starts_with(&[0xEF, 0xBB, 0xBF]);
    let start = if had_bom { 3 } else { 0 };

    let (clean, crlf_count) = match process_line_endings(&raw, start) {
        Ok(result) => result,
        Err(e) => {
            eprintln!("error: {}", e);
            return 1;
        }
    };

    if had_bom {
        eprintln!("warning: file contains a UTF-8 BOM — run nsv sanitize to fix");
        exit_code = 1;
    }
    if crlf_count > 0 {
        eprintln!("warning: file contains CRLF line endings — run nsv sanitize to fix");
        exit_code = 1;
    }

    let text = String::from_utf8_lossy(&clean);

    // Structural warnings — check() reports byte offsets into the clean data
    let warnings = nsv::check(&text);

    for w in &warnings {
        // Character column (1-indexed) from byte column, assuming UTF-8
        let char_col = byte_col_to_char_col(clean.as_slice(), w.line, w.col);
        // Original byte offset: account for stripped BOM and removed CRs
        let original_byte = w.pos + start + (w.line - 1) * (crlf_count > 0) as usize;

        let location = match char_col {
            Some(cc) => format!("line {}, col {}, byte {}", w.line, cc, original_byte),
            None => format!("line {}, byte {}", w.line, original_byte),
        };

        match w.kind {
            nsv::WarningKind::UnknownEscape(b) => {
                eprintln!("warning: unknown escape sequence '\\{}' ({})", b as char, location);
            }
            nsv::WarningKind::DanglingBackslash => {
                eprintln!("warning: dangling backslash ({})", location);
            }
            nsv::WarningKind::NoTerminalLf => {
                eprintln!("warning: missing terminal newline ({})", location);
            }
        }
        exit_code = 1;
    }

    // Table check
    if table {
        let rows = nsv::loads(&text);
        if !rows.is_empty() {
            let arities: Vec<usize> = rows.iter().map(|r| r.len()).collect();
            let min = *arities.iter().min().unwrap();
            let max = *arities.iter().max().unwrap();
            if min != max {
                eprintln!(
                    "error: not a table — row arities vary (min {}, max {})",
                    min, max
                );
                exit_code = 1;
            }
        }
    }

    exit_code
}

/// Convert a 1-indexed byte column (from nsv::check) to a 1-indexed
/// character column, assuming UTF-8. Returns None if the slice isn't
/// valid UTF-8 up to that point.
fn byte_col_to_char_col(clean: &[u8], line: usize, byte_col: usize) -> Option<usize> {
    let line_start = if line == 1 {
        0
    } else {
        let mut current = 1;
        let mut pos = 0;
        for (i, &b) in clean.iter().enumerate() {
            if b == b'\n' {
                current += 1;
                if current == line {
                    pos = i + 1;
                    break;
                }
            }
        }
        if current < line {
            return None;
        }
        pos
    };

    let end = line_start + byte_col;
    if end > clean.len() {
        return None;
    }
    std::str::from_utf8(&clean[line_start..end])
        .ok()
        .map(|s| s.chars().count())
}
