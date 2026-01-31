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
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Version => {
            println!("nsv-cli {}", env!("CARGO_PKG_VERSION"));
            println!("nsv     {}", nsv::VERSION);
        }
    }
}
