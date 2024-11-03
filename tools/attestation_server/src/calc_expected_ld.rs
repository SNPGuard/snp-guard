use serde::{Deserialize, Serialize};
use sev::firmware::guest::{GuestPolicy, PlatformInfo};
use sev::firmware::host::TcbVersion;
use sev::measurement::{
    snp::{snp_calc_launch_digest, SnpMeasurementArgs},
    vmsa::{GuestFeatures, VMMType},
    vcpu_types::CpuType
};
use snafu::{whatever, ResultExt, Whatever};

use crate::snp_validate_report::ProductName;
use hex_buffer_serde::{Hex as _, HexForm};

///Length fo the FamilyID and the ImageID data types in bytes
pub const IDBLOCK_ID_BYTES :usize = 16;

#[derive(Serialize, Deserialize, Default)]
///User facing config struct to specify a VM.
///Used to compute the epxected launch measurment
pub struct VMDescription {
    pub host_cpu_family: ProductName,
    pub vcpu_count: u32,
    pub ovmf_file: String,
    /// Security relevant SEV configuration/kernel features. Defined in the VMSA of the VM. Thus they affect the computation of the expected launch measurement. See `SEV_FEATURES` in Table B-4 in https://www.amd.com/content/dam/amd/en/documents/processor-tech-docs/programmer-references/24593.pdf
    ///TODO: implement nice way to detect which features are used on a given system
    pub guest_features: GuestFeatures,
    pub kernel_file: String,
    pub initrd_file: String,
    pub kernel_cmdline: String,
    pub platform_info: PlatformInfo,
    ///Mininum required committed version numbers
    ///Committed means that the platform cannot be rolled back to a prior
    ///version
    pub min_commited_tcb: TcbVersion,
    /// Policy passed to QEMU and reflected in the attestation report
    pub guest_policy: GuestPolicy,
    #[serde(with = "HexForm")]
    pub family_id: [u8; IDBLOCK_ID_BYTES],
    #[serde(with = "HexForm")]
    pub image_id: [u8; IDBLOCK_ID_BYTES],
}

impl VMDescription {
    pub fn compute_expected_hash(&self) -> Result<[u8; 384 / 8], Whatever> {
        let snp_measure_args = SnpMeasurementArgs {
            vcpus: self.vcpu_count,
            vcpu_type: CpuType::EpycV4,
            ovmf_file: self.ovmf_file.clone().into(),
            guest_features: self.guest_features,
            kernel_file: Some(self.kernel_file.clone().into()),
            initrd_file: Some(self.initrd_file.clone().into()),
            append: if self.kernel_cmdline != "" {
                Some(&self.kernel_cmdline)
            } else {
                None
            },
            //if none, we calc ovmf hash based on ovmf file
            ovmf_hash_str: None,
            vmm_type: Some(VMMType::QEMU),
        };

        let ld = snp_calc_launch_digest(snp_measure_args)
            .whatever_context("failed to compute launch digest")?;
        let ld_vec = bincode::serialize(&ld).whatever_context("failed to bincode serialized SnpLaunchDigest to Vec<u8>")?;
        let ld_arr : [u8; 384 / 8] = match ld_vec.try_into() {
            Ok(v) => v,
            Err(_) => whatever!("SnpLaunchDigest has unexpected length"),
        };
        Ok(ld_arr)
    }
}

#[cfg(test)]
mod test {
    use std::fs;

    use super::VMDescription;

    #[test]
    fn parse_toml() {
        println!(
            "Expected\n\n{}",
            toml::to_string_pretty(&VMDescription::default()).unwrap()
        );
        let _conf: VMDescription =
            toml::from_str(&fs::read_to_string("./examples/vm-config.toml").unwrap()).unwrap();
    }
}
