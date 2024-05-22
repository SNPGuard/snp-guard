use std::fs::File;

use clap::Parser;
use sev::firmware::guest::Firmware;
use snafu::{whatever, ResultExt, Whatever};
use base64::{engine::general_purpose, Engine};

#[derive(Parser, Debug)]
struct Args {
    /// Path to output file
    #[arg(long, default_value = "attestation_report.json")]
    out: String,

    /// Optional 64-byte data to pass to the report, encoded in base64
    #[arg(long, default_value = "")]
    report_data: String,
}
#[snafu::report]
fn main() -> Result<(), Whatever> {
    let args = Args::parse();

    let report_data_raw = general_purpose::STANDARD_NO_PAD
        .decode(&args.report_data)
        .whatever_context("failed to decode report_data as base64")?;
    let len = report_data_raw.len();

    if len > 64 {
        whatever!("report data length should be <= 64 bytes, but got {} bytes!", len);
    }

    let mut report_data = [0u8; 64];
    report_data[..len].copy_from_slice(&report_data_raw);
    
    let mut fw = Firmware::open().whatever_context("failed to open sev firmware device. Is this a SEV-SNP guest?")?;
    let report = fw.get_report(None, Some(report_data), None).whatever_context("error getting report from firmware device")?;
    
    let f = File::create(&args.out).whatever_context(format!("failed to create output file {}",&args.out))?;
    serde_json::to_writer(f, &report).whatever_context("failed to serialize report as json")?;
    println!("Your result is at {}.\nCopy it to the host system and the \"verify_report\" binary to verify it, as described in the README", &args.out);
    Ok(())
}