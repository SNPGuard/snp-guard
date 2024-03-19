use attestation_server::calc_expected_ld::VMDescription;
use sev::measurement::vmsa::GuestFeatures;

fn main() {
    let desc = VMDescription {
        vcpu_count: 1,
        ovmf_file: "path to OVMF.fd file used by QEMU".to_string(),
        guest_features: GuestFeatures(0x21), //Qemu shoudl default to this
        kernel_file: "path to kernel file that gets passed to QMEU".to_string(),
        initrd_file: "path to initramdisk file that gets passed to QEMU".to_string(),
        kernel_cmdline: "kernel commandline arguments, as passed to QEMU in the \"-append\"  arg"
            .to_string(),
    };
    let out = serde_json::to_string_pretty(&desc).expect("failed to generate example config");

    let guest_features_doc = r#"Kernel features that when enabled could affect the VMSA.
| Bit(s) | Name
|--------|------|
| 0 | SNPActive |
| 1 | vTOM |
| 2 | ReflectVC |
| 3 | RestrictedInjection |
| 4 | AlternateInjection |
| 5 | DebugSwap |
| 6 | PreventHostIBS |
| 7 | BTBIsolation |
| 8 | VmplSSS |
| 9 | SecureTSC |
| 10 | VmgexitParameter |
| 11 | Reserved, SBZ |
| 12 | IbsVirtualization |
| 13 | Reserved, SBZ |
| 14 | VmsaRegProt |
| 15 | SmtProtection |
| 63:16 | Reserved, SBZ |"#;

    println!("Example Config:\n{}\n", out);
    println!(
        "Guest Features Explanation:\n{}\n The provided value of 0x21 is the usual QEMU default",
        guest_features_doc
    );
}
