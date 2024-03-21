//! Tool for the VM Owner to verify the attestation report at runtime and securely
//! provision a disk encryption key to the VM
use std::{
    env,
    fs::{self, File},
    io::Write,
};

use attestation_server::{
    calc_expected_ld::VMDescription,
    req_resp_ds::{aead_enc, AttestationRequest, WrappedDiskKey},
    snp_attestation::ReportData,
    snp_validate_report::{
        verify_and_check_report, verify_report_signature, CachingVCEKDownloader, IDBLockReportData,
        ProductName,
    },
};

use base64::{engine::general_purpose, Engine};
use clap::Parser;
use reqwest::blocking::Client;
use ring::{
    agreement,
    rand::{SecureRandom, SystemRandom},
};
use sev::{
    firmware::guest::AttestationReport,
    measurement::idblock_types::{IdAuth, IdBlock},
};
use snafu::{whatever, OptionExt, ResultExt, Whatever};

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

    ///Override the content of "kernel_cmdline" from the config while
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

fn main() {
    let args = Args::parse();
    if let Err(e) = run(args) {
        println!("\nError: {:#?}\n", e);
    }
}

fn run(args: Args) -> Result<(), Whatever> {
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
    println!(
        "Computed expected launch digest: {}",
        hex::encode(expected_ld)
    );

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

    rng.fill(&mut buffer).unwrap();

    // Convert the bytes to u64
    let nonce = u64::from_le_bytes(buffer);
    let att_req = AttestationRequest { nonce };
    let client = Client::new();
    println!("Requesting attestation report");
    let resp: AttestationReport = client
        .post(&args.server_url)
        .json(&att_req)
        .send()
        .expect("nonce request failed")
        .json()
        .expect("failed to deserialize");

    println!("Received report");
    println!("Received Launch digest: {}", hex::encode(resp.measurement));

    if let Some(dump_path) = args.dump_report {
        let f = File::create(dump_path).expect("failed to create report dump file");
        serde_json::to_writer_pretty(f, &resp)
            .expect("failed to serialize attestation report to file");
    }

    println!("Verifying report signature");
    let vcek_resolver =
        CachingVCEKDownloader::new().expect("failed to instantiate vcek downloader");
    let vcek_cert = vcek_resolver
        .get_vceck_cert(
            resp.chip_id,
            vm_description.host_cpu_family,
            &resp.committed_tcb,
        )
        .expect("failed to get vcek cert");

    let report_data_validator = |vm_data: [u8; 64]| {
        let report_data: ReportData = vm_data.clone().into();
        if nonce != report_data.nonce {
            whatever!(
                "nonce validation in report data failed, expected {} got {}",
                report_data.nonce,
                nonce
            );
        }
        Ok(())
    };

    let id_block_data = if let Some((_, _, v)) = id_data {
        Some(v)
    } else {
        None
    };
    verify_and_check_report(
        &resp,
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

    let user_report_data: ReportData = resp.report_data.into();

    //Phase2: Derive Shared secret and send encrypted disk encryption key to server

    //Verified report and have pulic key agreement key from server (authenticity attested by report signature)
    //Generate our key pair and encrypt the password for the disk with the shared secret
    //Then send encrypted disk key + our public key to server
    println!("wrapping disk encryption key");
    let client_private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
        .expect("failed to generate private server key");
    let client_public_key = client_private_key
        .compute_public_key()
        .expect("failed to compute public key");

    let mut shared_secret = Vec::new();
    agreement::agree_ephemeral(
        client_private_key,
        &user_report_data.server_public_key,
        |key_material| {
            shared_secret
                .write_all(key_material)
                .expect("failed to store key material");
            // In a real application, we'd apply a KDF to the key material and the
            // public keys (as recommended in RFC 7748) and then derive session
            // keys from the result. We omit all that here.
        },
    )
    .expect("failed to generate shared key");

    let disk_encryption_key = args.disk_key.as_bytes();
    let wrapped_disk_key = aead_enc(&shared_secret, nonce, disk_encryption_key);

    let wrapped_disk_key = WrappedDiskKey {
        wrapped_disk_key,
        client_public_key: client_public_key
            .as_ref()
            .try_into()
            .expect("failed to serialize pubkey"),
    };

    println!("sending wrapped key to server");
    client
        .post(&args.server_url)
        .json(&wrapped_disk_key)
        .send()
        .expect("failed to send wrapped disk key");

    Ok(())
}

///Parse the supplied data and also return a special representation
///that is usefull for checking the attestation report
fn parse_id_block_data(
    id_block_raw: &[u8],
    id_auth_block_raw: &[u8],
) -> Result<(IdBlock, IdAuth, IDBLockReportData), Whatever> {
    //decode id_block
    let id_block_raw = general_purpose::STANDARD
        .decode(&id_block_raw)
        .whatever_context("failed to decode id block as base64")?;
    let id_block: IdBlock =
        bincode::deserialize(&id_block_raw).whatever_context("failed to bindecode id block")?;

    //decode id_auth block
    let id_auth_block_raw = general_purpose::STANDARD
        .decode(&id_auth_block_raw)
        .whatever_context("failed to decode id auth block as base64")?;
    let id_auth_block: IdAuth = bincode::deserialize(&id_auth_block_raw)
        .whatever_context("failed to bindecode id auth block")?;

    let id_block_report_data: IDBLockReportData =
        (id_block.clone(), id_auth_block.clone()).try_into()?;

    Ok((id_block, id_auth_block, id_block_report_data))
}
