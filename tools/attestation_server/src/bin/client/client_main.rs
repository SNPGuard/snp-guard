//! Tool for the VM Owner to verify the attestation report at runtime and securely
//! provision a disk encryption key to the VM
use std::{
    fs::{self, File},
    io::Write, str::FromStr, time::Duration,
};

use attestation_server::{
    calc_expected_ld::VMDescription,
    req_resp_ds::{aead_enc, AttestationRequest, WrappedDiskKey},
    snp_attestation::ReportData,
    snp_validate_report::{
        parse_id_block_data, verify_and_check_report, CachingVCEKDownloader, ReportDataMismatchSnafu, ReportVerificationError
    },
};

use clap::Parser;
use indicatif::ProgressBar;
use reqwest::{blocking::Client, Url};
use ring::{
    agreement,
    rand::{SecureRandom, SystemRandom},
};
use sev::
    firmware::guest::AttestationReport;
use snafu::{ FromString, ResultExt, Whatever};
use snafu::prelude::*;

#[derive(Debug, Snafu)]
enum UserError {
    #[snafu(display("Attestation report not valid : {}", source))]
    InvalidReport { source: ReportVerificationError },

    ///catch-all error type
    #[snafu(whatever, display("{message}"))]
    Whatever {
        message: String,
        #[snafu(source(from(Box<dyn std::error::Error>, Some)))]
        source: Option<Box<dyn std::error::Error>>,
    },
}

#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value = "http://localhost:8080")]
    ///URL of the Server running in the VM that we want to attest
    server_url: String,

    #[arg(long)]
    ///Disk encryption key that should be injected into the VM
    disk_key: String,

    #[arg(long)]
    ///Config file used to compute the expected vm hash
    vm_definition: String,

    #[arg(long)]
    ///Override the content of "kernel_cmdline" from the config file
    ///Useful to test one-off changes
    override_kernel_cmdline: Option<String>,

    #[arg(long)]
    ///If set, we store the attestation report under this path
    dump_report: Option<String>,

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
}

#[snafu::report]
fn main() -> Result<(), UserError> {
    let args = Args::parse();
    match run(&args) {
        Ok(_) => {
            println!("Success!");
            Ok(())
        }
        Err(e) => {
            match e {
                UserError::InvalidReport { .. } => {
                    println!("Program executed successfully but attestation report was invalid.\nIn case of mismatching values, verify that the data in the vm config file {} matches your host.
                    \nAfter updating the config file, you may simply run this command again.\nPlease find more details on the verification error below.",&args.vm_definition);
                }
                _ => (),
            }
            Err(e)
        }
    }
}

fn run(args: &Args) -> Result<(), UserError> {
    let mut vm_description: VMDescription = toml::from_str(
        &fs::read_to_string(&args.vm_definition).whatever_context(format!(
            "failed to read config from {}",
            &args.vm_definition
        ))?,
    )
    .whatever_context("failed to parse vm config as toml")?;

    if let Some(cmdline_override) = &args.override_kernel_cmdline {
        vm_description.kernel_cmdline = cmdline_override.clone();
    }

    let expected_ld = vm_description.compute_expected_hash().whatever_context("failed to compute the expected launch digest based on the vm config")?;

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

    //Phase1: Request attestation report from server and validate it
    //As part of the report, we get a public key agreement key

    let rng = SystemRandom::new();

    let mut buffer = [0u8; 8];

    rng.fill(&mut buffer).map_err(|_| Whatever::without_source("failed to sample randomness".to_string())).whatever_context("failed to sample nonce")?;

    // Convert the bytes to u64
    let nonce = u64::from_le_bytes(buffer);
    let att_req = AttestationRequest { nonce };
    let client = Client::new();

    //This is the first network request that we send. The VM might still be booting up, show some 
    let wait_for_request_bar = ProgressBar::new_spinner().with_message("Waiting for attestation server").with_elapsed(Duration::from_secs(0));
    wait_for_request_bar.enable_steady_tick(Duration::from_millis(100));
    let reset_endpoint = Url::from_str(&args.server_url).whatever_context(format!("Failed to parse server url {}",&args.server_url))?.join("reset").whatever_context("failed to assemble reset endpoint URL")?;
    client.post(reset_endpoint.clone()).send().whatever_context(format!("failed to send init request to attestation server at {:?}",reset_endpoint))?;
    wait_for_request_bar.finish();

    println!("Requesting attestation report from {}", &args.server_url);
    let attestation_report: AttestationReport = client
        .post(&args.server_url)
        .json(&att_req)
        .send()
        .whatever_context("failed to send nonce request")?
        .json()
        .whatever_context("failed to parse attestation report request result as json")?;

    println!("Received report");

    if let Some(dump_path) = &args.dump_report {
        let f = File::create(dump_path).whatever_context(format!("failed to create report dump file at {}",dump_path))?;
        serde_json::to_writer_pretty(f, &attestation_report)
            .whatever_context(format!("failed to serialize attestation report to file {}",&dump_path))?;
    }

    println!("Verifying Report");
    let vcek_resolver =
    CachingVCEKDownloader::new().whatever_context("failed to instantiate vcek downloader")?;
let vcek_cert = vcek_resolver
    .get_vceck_cert(
        attestation_report.chip_id,
        vm_description.host_cpu_family,
        &attestation_report.committed_tcb,
    )
    .whatever_context(format!(
        "failed to download vcek cert for cpu family {}, chip_id 0x{}",
        &vm_description.host_cpu_family,
        hex::encode(attestation_report.chip_id)
    ))?;

    let report_data_validator = |vm_data: [u8; 64]| {
        let report_data: ReportData = vm_data.clone().into();
        if nonce != report_data.nonce {
            return ReportDataMismatchSnafu{
                expected:format!("0x{:x}",report_data.nonce),
                got: format!("0x{:x}",nonce),
            }.fail();
        }
        Ok(())
    };

    let id_block_data = if let Some((_, _, v)) = id_data {
        Some(v)
    } else {
        None
    };
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
    .context(InvalidReportSnafu {})?;

    let user_report_data: ReportData = attestation_report.report_data.into();

    //Phase2: Derive Shared secret and send encrypted disk encryption key to server

    //Verified report and have pulic key agreement key from server (authenticity attested by report signature)
    //Generate our key pair and encrypt the password for the disk with the shared secret
    //Then send encrypted disk key + our public key to server
    println!("Deriving shared secret");
    let client_private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).map_err(|_| Whatever::without_source("failed to generate private DH key".to_string())).whatever_context("failed to generate private DH key for client")?;
    let client_public_key = client_private_key
        .compute_public_key().map_err(|_| Whatever::without_source("failed to derive public dh key from private key".to_string())).whatever_context("failed to generate public DH key for client")?;

    let mut shared_secret = Vec::new();
    agreement::agree_ephemeral(
        client_private_key,
        &user_report_data.server_public_key,
        |key_material| -> Result<(),Whatever>{
            shared_secret
                .write_all(key_material).whatever_context("failed to store derived shared secret in buffer")
            // In a real application, we'd apply a KDF to the key material and the
            // public keys (as recommended in RFC 7748) and then derive session
            // keys from the result. We omit all that here.
        },
    ).map_err(|_| Whatever::without_source("failed to compute shared secret from DH keys".to_string())).whatever_context("failed to derive shared secret")?.whatever_context("internal error")?;

    println!("Wrapping disk encryption key");
    let disk_encryption_key = args.disk_key.as_bytes();
    let wrapped_disk_key = aead_enc(&shared_secret, nonce, disk_encryption_key).whatever_context("failed to encrypt disk encryption key")?;

    let wrapped_disk_key = WrappedDiskKey {
        wrapped_disk_key,
        client_public_key: client_public_key
            .as_ref()
            .try_into()
            .whatever_context("failed to serialize public client DH key")?,
    };

    println!("Sending wrapped disk encryption key to server");
    client
        .post(&args.server_url)
        .json(&wrapped_disk_key)
        .send()
        .whatever_context("failed to send wrapped disk key")?;

    Ok(())
}
