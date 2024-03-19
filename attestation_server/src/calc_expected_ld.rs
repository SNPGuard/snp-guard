use serde::{Deserialize, Serialize};
use sev::{
    firmware::guest::GuestFieldSelect,
    measurement::{snp::SnpMeasurementArgs, vmsa::GuestFeatures},
};

#[derive(Serialize, Deserialize, Debug)]
///User facing config struct to specify a VM.
///Used to compute the epxected launch measurment
pub struct VMDescription {
    pub vcpu_count: u32,
    pub ovmf_file: String,
    pub guest_features: GuestFeatures,
    pub kernel_file: String,
    pub initrd_file: String,
    pub kernel_cmdline: String,
}

// pub fn dummy() {
//     let a = SnpMeasurementArgs{
//         vcpus: todo!(),
//         vcpu_type: todo!(),
//         ovmf_file: todo!(),
//         guest_features: todo!(),
//         kernel_file: todo!(),
//         initrd_file: todo!(),
//         append: todo!(),
//         ovmf_hash_str: todo!(),
//         vmm_type: todo!(),
//     }
// }
