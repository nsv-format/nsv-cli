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

    /// Print structural statistics about NSV data
    Stats {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,
    },

    /// Transpose rows and columns of NSV data
    #[command(alias = "t")]
    Transpose {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,
    },

    /// Apply NSV escaping to each line (collapse one structural dimension)
    Lift {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,
    },

    /// Apply NSV unescaping to each line (restore one structural dimension)
    Unlift {
        /// Input file (reads from stdin if omitted or "-")
        #[arg(value_name = "FILE")]
        file: Option<String>,
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
        Commands::Stats { file } => {
            stats(file);
        }
        Commands::Transpose { file } => {
            if let Err(e) = transpose(file) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
        }
        Commands::Lift { file } => {
            if let Err(e) = lift(file) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
        }
        Commands::Unlift { file } => {
            if let Err(e) = unlift(file) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
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
    let output = process_line_endings(&data, start, false)?;
    io::stdout()
        .write_all(&output)
        .map_err(|e| format!("write error: {}", e))?;
    Ok(())
}

/// Infers style from first line ending, errors on bare CR or mixed styles.
fn process_line_endings(data: &[u8], start: usize, quiet: bool) -> Result<Vec<u8>, String> {
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

    if !quiet && crlf_count > 0 {
        eprintln!("fixed {} Windows line endings", crlf_count);
    }

    Ok(output)
}

/// Print structural statistics about NSV data, in NSV format.
///
/// Silently sanitizes (strip BOM, normalize CRLF) before parsing.
/// No warnings or validation — just stats to stdout.
fn stats(file: Option<String>) {
    let raw = read_input(&file);

    let start = if raw.starts_with(&[0xEF, 0xBB, 0xBF]) { 3 } else { 0 };
    let clean = match process_line_endings(&raw, start, true) {
        Ok(output) => output,
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    };
    let rows = nsv::decode_bytes(&clean);

    let num_rows = rows.len();
    let cells: usize = rows.iter().map(|r| r.len()).sum();
    let min_arity = rows.iter().map(|r| r.len()).min().unwrap_or(0);
    let max_arity = rows.iter().map(|r| r.len()).max().unwrap_or(0);
    let is_table = min_arity == max_arity;
    let max_cell_bytes = rows
        .iter()
        .flat_map(|r| r.iter())
        .map(|c| c.len())
        .max()
        .unwrap_or(0);

    let data = vec![
        vec!["rows".to_string(), num_rows.to_string()],
        vec!["cells".to_string(), cells.to_string()],
        vec!["min_arity".to_string(), min_arity.to_string()],
        vec!["max_arity".to_string(), max_arity.to_string()],
        vec!["is_table".to_string(), is_table.to_string()],
        vec!["max_cell_bytes".to_string(), max_cell_bytes.to_string()],
    ];
    print!("{}", nsv::encode(&data));
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

    let clean = match process_line_endings(&raw, start, true) {
        Ok(output) => output,
        Err(e) => {
            eprintln!("error: {}", e);
            return 1;
        }
    };

    let had_crlf = clean.len() < raw.len() - start;

    if had_bom {
        eprintln!("warning: file contains a UTF-8 BOM — run nsv sanitize to fix");
        exit_code = 1;
    }
    if had_crlf {
        eprintln!("warning: file contains CRLF line endings — run nsv sanitize to fix");
        exit_code = 1;
    }

    // Structural warnings — check() reports byte offsets into the clean data
    let warnings = nsv::check(&clean);

    // Convert a 1-indexed byte column to a 1-indexed character column,
    // assuming UTF-8. Returns None if the bytes aren't valid UTF-8.
    let byte_col_to_char_col = |line: usize, byte_col: usize| -> Option<usize> {
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
    };

    for w in &warnings {
        let char_col = byte_col_to_char_col(w.line, w.col);
        // Original byte offset: account for stripped BOM and removed CRs
        let original_byte = w.pos + start + (w.line - 1) * had_crlf as usize;

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
        let rows = nsv::decode_bytes(&clean);
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

/// Transpose rows and columns of NSV data.
///
/// Requires table input (all rows must have equal arity).
/// Errors on ragged data.
fn transpose(file: Option<String>) -> Result<(), String> {
    let raw = read_input(&file);

    // Split into raw lines (already-escaped cell bytes).
    // Group by blank lines into rows of raw cell slices.
    let mut rows: Vec<Vec<&[u8]>> = Vec::new();
    let mut current_row: Vec<&[u8]> = Vec::new();
    for line in raw.split(|&b| b == b'\n') {
        if line.is_empty() {
            if !current_row.is_empty() {
                rows.push(current_row);
                current_row = Vec::new();
            }
        } else {
            current_row.push(line);
        }
    }
    if !current_row.is_empty() {
        rows.push(current_row);
    }

    if rows.is_empty() {
        return Ok(());
    }

    let arity = rows[0].len();
    if rows.iter().any(|r| r.len() != arity) {
        return Err("not a table — row arities differ".to_string());
    }
    if arity == 0 {
        return Ok(());
    }

    let mut out = io::BufWriter::new(io::stdout().lock());
    for col in 0..arity {
        for row in &rows {
            out.write_all(row[col]).map_err(|e| e.to_string())?;
            out.write_all(b"\n").map_err(|e| e.to_string())?;
        }
        out.write_all(b"\n").map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Apply NSV escaping to each line.
///
/// Treats input as raw lines (split on LF), applies `escape` to each,
/// and writes the escaped lines back out with LF terminators.
/// This is the line-level equivalent of the lift operation from the ENSV spec.
fn lift(file: Option<String>) -> Result<(), String> {
    let data = read_input(&file);
    if data.is_empty() {
        return Ok(());
    }
    // Trim trailing LF — it's a terminator, not a separator creating an empty line
    let body = if data.ends_with(b"\n") { &data[..data.len() - 1] } else { &data[..] };
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in body.split(|&b| b == b'\n') {
        out.write_all(&nsv::escape_bytes(line)).map_err(|e| e.to_string())?;
        out.write_all(b"\n").map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Apply NSV unescaping to each line.
///
/// Treats input as raw lines (split on LF), applies `unescape` to each,
/// and writes the unescaped lines back out with LF terminators.
/// This is the line-level equivalent of the unlift operation from the ENSV spec.
fn unlift(file: Option<String>) -> Result<(), String> {
    let data = read_input(&file);
    if data.is_empty() {
        return Ok(());
    }
    let body = if data.ends_with(b"\n") { &data[..data.len() - 1] } else { &data[..] };
    let mut out = io::BufWriter::new(io::stdout().lock());
    for line in body.split(|&b| b == b'\n') {
        out.write_all(&nsv::unescape_bytes(line)).map_err(|e| e.to_string())?;
        out.write_all(b"\n").map_err(|e| e.to_string())?;
    }
    Ok(())
}

