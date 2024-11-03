//! Tool to generate and ID block and an auth block for usage with QEMU
use std::{
    fs::{self, File},
    io::Write,
    path::PathBuf,
};

use attestation_server::calc_expected_ld::VMDescription;
use base64::{engine::general_purpose, Engine};
use clap::Parser;
use snafu::{ResultExt, Whatever};

use sev::measurement::{
        idblock::snp_calculate_id,
        idblock_types::{FamilyId, IdMeasurements, ImageId},
        large_array::LargeArray, snp::SnpLaunchDigest,
    };
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    #[arg(long)]
    ///Path to config file that defines the VM. E.g. used to compute the expected launch digest
    vm_definition: String,
    /// ID_KEY from Table 75 in SNP Docs. Used to sign the identity block
    /// PEM encoded ECDSA P-384 private key.
    #[arg(long)]
    id_key_path: String,
    /// AUTHOR_KEY from Table 75 in SNP Docs
    /// PEM encoded ECDSA P-384 private key.
    #[arg(long)]
    auth_key_path: String,
    #[arg(long)]
    ///Override the content of "kernel_cmdline" from the config while
    ///Useful to test one-off changes
    override_kernel_cmdline: Option<String>,
    #[arg(long, default_value = "./")]
    ///Path where the base64 encoded id block and auth block are stored
    out_dir: String,
}

fn main() {
    let args = Args::parse();
    if let Err(e) = run(args) {
        println!("\nError: {:#?}\n", e);
    }
}

fn run(args: Args) -> Result<(), Whatever> {
    let mut vm_def: VMDescription = toml::from_str(
        &fs::read_to_string(&args.vm_definition).whatever_context(format!(
            "failed to read config from {}",
            &args.vm_definition
        ))?,
    )
    .whatever_context("failed to parse config as toml")?;
    if let Some(cmdline_override) = args.override_kernel_cmdline {
        vm_def.kernel_cmdline = cmdline_override;
    }

    let block_calculations = compute_id_block(&vm_def, &args.id_key_path, &args.auth_key_path)?;

    let id_block_string = general_purpose::STANDARD.encode(
        bincode::serialize(&block_calculations.id_block)
            .whatever_context("error serializing id_block to binary")?,
    );
    let id_key_digest_string = general_purpose::STANDARD.encode::<Vec<u8>>(
        block_calculations
            .id_key_digest
            .try_into()
            .whatever_context("error serializing id_key_digest to binary")?,
    );
    let auth_key_digest_string = general_purpose::STANDARD.encode::<Vec<u8>>(
        block_calculations
            .auth_key_digest
            .try_into()
            .whatever_context("error serializing auth_key_digest to binary")?,
    );
    //dont print as it is quite long
    let auth_block_string = general_purpose::STANDARD.encode(
        bincode::serialize(&block_calculations.id_auth)
            .whatever_context("error serializing id_auth to binary")?,
    );

    println!("id block: {}", id_block_string);
    println!("id key digest: {}", id_key_digest_string);
    println!("auth key digest: {}", auth_key_digest_string);
    println!("writing id auth data basee64 encoded to {}", &args.out_dir);

    let id_block_path = PathBuf::from(&args.out_dir).join("id-block.base64");
    let auth_block_path = PathBuf::from(&args.out_dir).join("auth-block.base64");

    let mut auth_block_file =
        File::create(&auth_block_path).whatever_context(format!("path {:?}", &auth_block_path))?;
    auth_block_file
        .write_all(auth_block_string.as_bytes())
        .whatever_context("")?;

    let mut id_block_file =
        File::create(&id_block_path).whatever_context(format!("path {:?}", &id_block_path))?;
    id_block_file
        .write_all(id_block_string.as_bytes())
        .whatever_context("")?;

    Ok(())
}

fn compute_id_block(
    vm_def: &VMDescription,
    id_key_path: &str,
    auth_key_path: &str,
) -> Result<IdMeasurements, Whatever> {
    //based on the unit test in https://github.com/virtee/sev/blob/main/tests/id-block.rs

    let expected_ld = vm_def.compute_expected_hash()?;
    let ld = SnpLaunchDigest::new(
        LargeArray::try_from(expected_ld)
            .whatever_context("converting to id block digest failed")?,
    );

    let family_id : FamilyId = bincode::deserialize(&vm_def.family_id).whatever_context(format!("failed to deserizalize family id {:x?}", &vm_def.family_id))?;
    let image_id : ImageId = bincode::deserialize(&vm_def.image_id).whatever_context(format!("failed to deserialize image id {:x?}", &vm_def.image_id))?;

    // let id_block = IdBlock::new(, , , , )
    let block_calculations = snp_calculate_id(
        Some(ld),
        Some(family_id),
        Some(image_id),
        None, //SVN is the "Security Version Number" of the PSP
        Some(vm_def.guest_policy),
        id_key_path.into(),
        auth_key_path.into(),
    )
    .whatever_context("idblock computation failed")?;

    Ok(block_calculations)
}
