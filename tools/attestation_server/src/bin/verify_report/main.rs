use std::fs::{self, File};

use attestation_server::{calc_expected_ld::VMDescription, snp_validate_report::{parse_id_block_data, verify_and_check_report, CachingVCEKDownloader}};
use clap::Parser;
use sev::firmware::guest::AttestationReport;
use snafu::{whatever, ResultExt, Whatever};
use base64::{engine::general_purpose, Engine};

#[derive(Parser,Debug)]
struct Args {
    ///Path to attestion report file as e.g. obtained by the `get_report` binary`
    #[arg(long, default_value = "./attestation_report.json")]
    input: String,
    ///Path to the vm config toml file. This is require to compute the expected attestation value for the VM
    #[arg(long)]
    vm_definition: String,

    #[arg(long)]
    ///Override the content of "kernel_cmdline" from the config file
    ///Useful to test one-off changes
    override_kernel_cmdline: Option<String>,

    #[arg(long, requires("author_block_path"))]
    ///Path to the id block used during launch. If this is **Some**, we will check
    ///that the attestation report contains the corresponding data.
    //If used, you also need to
    ///specify `author_block_path`
    id_block_path: Option<String>,
    #[arg(long, requires("id_block_path"))]
    ///Path to the id auth block used during launch. If this is **Some**, we will check
    ///that the attestation report contains the corresponding data. If used, you also need to
    ///specify `id_block_path`
    author_block_path: Option<String>,

    /// report data field, encoded in base64
    #[arg(long, default_value = "")]
    report_data: String,
}
fn main() -> Result<(), Whatever> {

    let args = Args::parse();

    //
    // Parse arguments
    //

    let input_file = File::open(&args.input).whatever_context(format!("failed to open attestation report file at {}",&args.input))?;
    let attestation_report : AttestationReport = serde_json::from_reader(input_file).whatever_context("failed to parse attestation report file")?;

    let mut vm_description: VMDescription = toml::from_str(
        &fs::read_to_string(&args.vm_definition).whatever_context(format!(
            "failed to read config from {}",
            &args.vm_definition
        ))?,
    )
    .whatever_context("failed to parse config as toml")?;
    if let Some(cmdline_override) = args.override_kernel_cmdline {
        vm_description.kernel_cmdline = cmdline_override;
    }
    let expected_ld = vm_description.compute_expected_hash().expect("todo");

     //If both the id block and the id auth block flag were specified, this contains the parsed data
    //as well as a representation for checking the attestation report
    let id_data;
    if let (Some(id_block_path), Some(id_auth_block_path)) =
        (&args.id_block_path, &args.author_block_path)
    {
        let raw_id_block = fs::read(&id_block_path)
            .whatever_context(format!("failed to read id block from {}", &id_block_path))?;
        let raw_id_auth_block = fs::read(&id_auth_block_path).whatever_context(format!(
            "failed to read id auth block from {}",
            &id_auth_block_path
        ))?;
        id_data = Some(
            parse_id_block_data(&raw_id_block, &raw_id_auth_block)
                .whatever_context("failed to parse id block related data")?,
        );
    } else {
        id_data = None;
    }

    let report_data_raw = general_purpose::STANDARD_NO_PAD
        .decode(&args.report_data)
        .whatever_context("failed to decode report_data as base64")?;
    let len = report_data_raw.len();

    if len > 64 {
        panic!("Report data length should be <= 64 bytes!");
    }

    let mut report_data = [0u8; 64];
    report_data[..len].copy_from_slice(&report_data_raw);

    //
    // Validate
    //

    println!("Verifying report signature");
    let vcek_resolver =
        CachingVCEKDownloader::new().expect("failed to instantiate vcek downloader");
    let vcek_cert = vcek_resolver
        .get_vceck_cert(
            attestation_report.chip_id,
            vm_description.host_cpu_family,
            &attestation_report.committed_tcb,
        )
        .expect("failed to get vcek cert");

    //Veryfing content
    let report_data_validator = |vm_data: [u8; 64]| {
        let report_data_b64 = general_purpose::STANDARD_NO_PAD
            .encode(&vm_data);

        if args.report_data.is_empty() {
            // just print it for info
            println!("Report data: {}", report_data_b64);
        } else {
            // actually validate
            if report_data != vm_data {
                whatever!(
                    "Report data does not match expected one",
                );
            }
        }
        Ok(())
    };
    let id_block_data = if let Some((_, _, v)) = id_data {
        Some(v)
    } else {
        None
    };
    println!("Verifying report data");
    verify_and_check_report(
        &attestation_report,
        vm_description.host_cpu_family,
        vcek_cert,
        id_block_data,
        Some(vm_description.guest_policy),
        Some(vm_description.min_commited_tcb),
        Some(vm_description.platform_info),
        Some(report_data_validator),
        None, //We don't use host data right now
        Some(expected_ld),
    )
    .whatever_context("Attestation Report Invalid!")?;

    println!("Success!");
    Ok(())
}