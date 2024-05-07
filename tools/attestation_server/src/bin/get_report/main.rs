use std::fs::{self, File};

use attestation_server::snp_attestation::ReportData;
use clap::Parser;
use sev::firmware::guest::Firmware;
use snafu::{ResultExt, Whatever};

#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value = "attestation_report.json")]
    out: String,
}

fn main() -> Result<(), Whatever> {
    let args = Args::parse();

    let mut fw = Firmware::open().whatever_context("failed to open sev firmware device. Is this a SEV-SNP guest?")?;
    let report = fw.get_report(None, None, None).whatever_context("error getting report from firmware device")?;
    
    let f = File::create(&args.out).whatever_context(format!("failed to create output file {}",&args.out))?;
    serde_json::to_writer(f, &report).whatever_context("failed to serialize report as json")?;
    println!("Your result is at {}.\nCopy it to the host system and the the \"client\" binary to verify it, as described in the README", &args.out);
    Ok(())
}