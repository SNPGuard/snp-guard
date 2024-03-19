use serde::{Deserialize, Serialize};
use sev::{
    launch::snp::Policy,
    measurement::{
        idblock_types::{FamilyId, ImageId},
        snp::{snp_calc_launch_digest, SnpMeasurementArgs},
        vmsa::{GuestFeatures, VMMType},
    },
};
use snafu::{ResultExt, Whatever};

#[derive(Serialize, Deserialize)]
///User facing config struct to specify a VM.
///Used to compute the epxected launch measurment
pub struct VMDescription {
    pub vcpu_count: u32,
    pub ovmf_file: String,
    pub guest_features: GuestFeatures,
    pub kernel_file: String,
    pub initrd_file: String,
    pub kernel_cmdline: String,
    pub policy: Policy,
    pub family_id: FamilyId,
    pub image_id: ImageId,
}

impl VMDescription {
    pub fn compute_expected_hash(&self) -> Result<[u8; 384 / 8], Whatever> {
        let snp_measure_args = SnpMeasurementArgs {
            vcpus: self.vcpu_count,
            vcpu_type: "EPYC-v4".into(),
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
        Ok(ld)
    }
}
