use std::{env, fs::File, io::Write};

use attestation_server::{
    calc_expected_ld::VMDescription,
    req_resp_ds::{aead_enc, AttestationRequest, WrappedDiskKey},
    snp_attestation::ReportData,
    snp_validate_report::{verify_report_signature, CachingVCEKDownloader, ProductName},
};

use clap::Parser;
use reqwest::blocking::Client;
use ring::{
    agreement,
    rand::{SecureRandom, SystemRandom},
};
use sev::{
    firmware::guest::AttestationReport,
    measurement::{
        gctx,
        snp::{snp_calc_launch_digest, SnpMeasurementArgs},
        vmsa::VMMType,
    },
};
use snafu::{ResultExt, Whatever};

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    disk_key: String,
    #[arg(long)]
    ///Config file used to compute the expected vm hash
    vm_definition: String,
    #[arg(long)]
    ///If set, we store the attestation report under this path
    dump_report: Option<String>,
}

fn compute_expected_hash(d: &VMDescription) -> Result<[u8; 384 / 8], Whatever> {
    let snp_measure_args = SnpMeasurementArgs {
        vcpus: d.vcpu_count,
        vcpu_type: "EPYC-v4".into(),
        ovmf_file: d.ovmf_file.clone().into(),
        guest_features: d.guest_features,
        kernel_file: Some(d.kernel_file.clone().into()),
        initrd_file: Some(d.initrd_file.clone().into()),
        append: if d.kernel_cmdline != "" {
            Some(&d.kernel_cmdline)
        } else {
            None
        },
        //if none, we calc ovmf hash based on ovmf file
        ovmf_hash_str: None,
        vmm_type: Some(VMMType::QEMU),
    };

    let ld = snp_calc_launch_digest(snp_measure_args)
        .whatever_context("failed to compute launch digest")?;
    Ok(ld)
}

fn main() {
    let args = Args::parse();
    let server_url = env::var("SERVER_URL").unwrap_or("http://localhost:8080".to_string());

    let vm_desc_file = File::open(args.vm_definition).expect("todo");
    let vm_descrition: VMDescription = serde_json::from_reader(vm_desc_file).expect("todo");
    let expected_ld = compute_expected_hash(&vm_descrition).expect("todo");
    println!(
        "Computed expected launch digest: {}",
        hex::encode(expected_ld)
    );

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
        .post(&server_url)
        .json(&att_req)
        .send()
        .expect("nonce request failed")
        .json()
        .expect("failed to deserialize");
    // println!("Got attestation report: {:x?}", resp);

    println!("Received report");

    if let Some(dump_path) = args.dump_report {
        let f = File::create(dump_path).expect("failed to create report dump file");
        serde_json::to_writer_pretty(f, &resp)
            .expect("failed to serialize attestation report to file");
    }

    println!("Verifying report signature");
    //TODO: make ProductName configurable once the code for the expected hashes is finished
    let vcek_resolver =
        CachingVCEKDownloader::new().expect("failed to instantiate vcek downloader");
    let vcek_cert = vcek_resolver
        .get_vceck_cert(resp.chip_id, ProductName::Milan, &resp.committed_tcb)
        .expect("failed to get vcek cert");

    verify_report_signature(ProductName::Milan, &resp, vcek_cert)
        .expect("Report signature invalid");

    println!("Report Signature is valid!");

    println!("Received Launch digest: {}", hex::encode(resp.measurement));
    assert_eq!(resp.measurement, expected_ld);
    let user_report_data: ReportData = resp.report_data.into();
    assert_eq!(user_report_data.nonce, nonce);

    //The attestation report is signed by the AMD-SP firmware using the VCEK.
    //TODO: verify report signatures etc
    println!("TODO:verify signatures");

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
        .post(&server_url)
        .json(&wrapped_disk_key)
        .send()
        .expect("failed to send wrapped disk key");
}
