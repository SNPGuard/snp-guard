use std::{
    fmt::Display,
    fs::{self, File},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use base64::{engine::general_purpose, Engine};
use openssl::sha::sha384;
use reqwest::{blocking, Url};
use serde::{Deserialize, Serialize};
use sev::{
    certs::snp::{
        builtin::{genoa, milan},
        ca, Certificate, Chain, Verifiable,
    },
    firmware::{
        guest::{AttestationReport, GuestPolicy, PlatformInfo},
        host::TcbVersion,
    },
    measurement::idblock_types::{IdAuth, IdBlock, SevEcdsaPubKey},
};
use snafu::{whatever, ResultExt, Whatever,prelude::*,FromString};

use crate::calc_expected_ld::IDBLOCK_ID_BYTES;




///Parse the supplied data and also return a special representation
///that is usefull for checking the attestation report
pub fn parse_id_block_data(
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


#[derive(Copy, Clone, Debug, PartialEq, Serialize, Deserialize, Default)]
///Describes the CPU generation
pub enum ProductName {
    #[default]
    Milan,
    Genoa,
}

impl Display for ProductName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            ProductName::Milan => "Milan",
            ProductName::Genoa => "Genoa",
        };
        write!(f, "{}", s)
    }
}

///Downloads VCEK files and caches them to disk to avoid
//running into rate limits
pub struct CachingVCEKDownloader {
    cache_folder_path: PathBuf,
}

impl CachingVCEKDownloader {
    pub fn new() -> Result<Self, Whatever> {
        let temp_path = std::env::temp_dir().join("snp-vcek-cache");
        if !Path::new(&temp_path).exists() {
            fs::create_dir(&temp_path).whatever_context(format!("path {:?}", temp_path))?;
        }
        Ok(CachingVCEKDownloader {
            cache_folder_path: temp_path,
        })
    }

    ///helper function that maps certificates to a filenames
    fn filename_for_vcek(chip_id: [u8; 64], product_name: ProductName, tcb: &TcbVersion) -> String {
        format!(
            "{}-{}-bl-{}-tee-{}-snp-{}-ucode-{}.crt",
            product_name,
            hex::encode(chip_id),
            tcb.bootloader,
            tcb.tee,
            tcb.snp,
            tcb.microcode
        )
    }

    ///First looks for file on disk. Otherwise downloads the certificate
    pub fn get_vceck_cert(
        &self,
        chip_id: [u8; 64],
        product_name: ProductName,
        tcb: &TcbVersion,
    ) -> Result<Certificate, Whatever> {
        //Try to load from cache dir
        let cert_cache_path =
            self.cache_folder_path
                .join(Self::filename_for_vcek(chip_id, product_name, tcb));
        let f = File::open(&cert_cache_path);
        let mut cert_bytes = Vec::new();

        //try to read certificate from cache directory
        //If file exists but cannot be read, return an error
        //else try to download the file
        match f {
            Ok(mut f) => {
                f.read_to_end(&mut cert_bytes)
                    .whatever_context("failed to read certificate file content")?;
            }
            Err(e) => {
                if e.kind() != io::ErrorKind::NotFound {
                    Err(e).whatever_context(format!("file path {:?}", cert_cache_path))?;
                }
                cert_bytes = download_vceck_cert(chip_id, product_name, &tcb)
                    .whatever_context("failed to download certificate")?;
                let mut out_file = File::create(&cert_cache_path)
                    .whatever_context(format!("file path {:?}", cert_cache_path))?;
                out_file
                    .write_all(&cert_bytes)
                    .whatever_context("failed to write certificate")?;
            }
        }
        //if we are here, cert_bytes contains the certificate and we created the file
        //for caching
        let cert =
            Certificate::from_bytes(&cert_bytes).whatever_context("failed to parse certificate")?;
        Ok(cert)
    }
}

///Downloads the VCEK for the specified parameters from the AMD backend
pub fn download_vceck_cert(
    chip_id: [u8; 64],
    product_name: ProductName,
    tcb: &TcbVersion,
) -> Result<Vec<u8>, Whatever> {
    //See 4.1 in https://www.amd.com/content/dam/amd/en/documents/epyc-technical-docs/specifications/57230.pdf
    let hw_id = hex::encode(chip_id);
    let mut req_url = Url::parse(&format!(
        "https://kdsintf.amd.com/vcek/v1/{product_name}/{hw_id}",
    ))
    .whatever_context("failed to assemble base url")?;

    req_url
        .query_pairs_mut()
        .append_pair("blSPL", &tcb.bootloader.to_string());
    req_url
        .query_pairs_mut()
        .append_pair("teeSPL", &tcb.tee.to_string());
    req_url
        .query_pairs_mut()
        .append_pair("snpSPL", &tcb.snp.to_string());
    req_url
        .query_pairs_mut()
        .append_pair("ucodeSPL", &tcb.microcode.to_string());

    let cert_bytes = blocking::get(req_url.clone())
        .whatever_context("failed to send request")?
        .error_for_status()
        .whatever_context(format!("request to \"{}\" returned error code", req_url))?
        .bytes()
        .whatever_context("failed to download body bytes")?;

    Ok(Vec::from(cert_bytes))
}

/// Data from the ID Block and ID Authentication Information Structure (shorthand ID Auth Block)
/// that is relevant for veryfing the attestation report
pub struct IDBLockReportData {
    ///Vm owner defined data to identify the VM
    guest_svn: u32,
    ///Vm owner defined data to identify the VM
    f_id: [u8; 16],
    ///Vm owner defined data to identify the VM
    i_id: [u8; 16],
    /// Digest of the identiy key used to sign the ID BLock
    id_key_digest: [u8; 48],
    /// Digest of the author key used to sign the identity key
    author_key_digest: [u8; 48],
}

///Convert a public key a sha384 digest
fn pubkey_to_id_block_digest(p: &SevEcdsaPubKey) -> Result<[u8; 48], Whatever> {
    sha384(
        bincode::serialize(p)
            .whatever_context("faild to serialize pubkey with bincode")?
            .as_slice(),
    )
    .try_into()
    .whatever_context("public key hash has incorrect size")
}

impl TryFrom<(IdBlock, IdAuth)> for IDBLockReportData {
    type Error = Whatever;

    fn try_from((id, auth): (IdBlock, IdAuth)) -> Result<Self, Self::Error> {
        let family_id_bytes : Vec<u8> = bincode::serialize(&id.family_id).whatever_context("failed to serialize family id to bytes")?;
        let family_id_bytes : [u8;IDBLOCK_ID_BYTES] = family_id_bytes.try_into().map_err(|v| Whatever::without_source(format!("family id serialized to {:x?} but expected {} bytes", &v, IDBLOCK_ID_BYTES )))?;

        let image_id_bytes : Vec<u8> = bincode::serialize(&id.image_id).whatever_context("failed to serialize image id to bytes")?;
        let image_id_bytes : [u8;IDBLOCK_ID_BYTES] = image_id_bytes.try_into().map_err(|v| Whatever::without_source(format!("image id serialized to {:x?} but expected {} bytes", &v, IDBLOCK_ID_BYTES )))?;
        Ok(Self {
            guest_svn: id.guest_svn,
            f_id: family_id_bytes,
            i_id: image_id_bytes,
            id_key_digest: pubkey_to_id_block_digest(&auth.id_pubkey)
                .whatever_context("failed to convert id pubkey to digest")?,
            author_key_digest: pubkey_to_id_block_digest(&auth.author_pub_key)
                .whatever_context("failed to convert author pubkey digest")?,
        })
    }
}

impl IDBLockReportData {
    ///Check that the data in the report matches the data specified in self
    pub fn check(&self, report: &AttestationReport) -> Result<(), Whatever> {
        if report.guest_svn != self.guest_svn {
            whatever!(
                "guest svn does not match, expected {:x?} got {:x?}",
                self.guest_svn,
                report.guest_svn
            );
        }

        if report.family_id != self.f_id {
            whatever!(
                "family id does not match, expected {:x?} got {:?}",
                self.f_id,
                report.family_id
            );
        }

        if report.image_id != self.i_id {
            whatever!(
                "image id does not match, expected {:x?} got {:x?}",
                self.i_id,
                report.image_id
            );
        }

        if report.id_key_digest != self.id_key_digest {
            whatever!(
                "id key digest does not match, expected {:x?} got {:x?}",
                self.id_key_digest,
                report.id_key_digest
            );
        }

        if report.author_key_digest != self.author_key_digest {
            whatever!(
                "author key digest does not match, expected {:x?} got {:x?}",
                self.author_key_digest,
                report.author_key_digest
            );
        }

        Ok(())
    }
}

/// Ensures that the given information matches the information specified in the report.
/// *DOES NOT* check the report signature
/// # Arguments
/// - `report` : The report that we want to check
/// - `idblock_data` : Information from the optional id block and id auth block that is relevant for the report verification. Both are optional data structures passed to QEMU. They are checked before the VM is launched
/// - `policy` : The Guest policy from Table 9 in [1]. We specify this in VM description and pass it to QEMU at start
/// - `tcb`    : Minimal required software versions for TCB components. The report defines three variants: comitted, launch and current. Commited is the minimum, rollback protected version. We check against this version. Launch is the tcb version at VM launch and current is the tcb version at time of report.
/// - `plat_info` : Selected information about the status of security relevant hardware features. In constract to `policy` these features affect the platform as a whole and cannot be toggled per VM. Most features are not configured through SEV APIs but through regular CPU config options like BIOS settings. Specified in Table 23 of [1]
/// - `report_data_validator` : Function that checks if the report data is valid. The report data is guest defined data provided when requesting the attestation report. We currently use it to return a nonce send by the guest owner as well as the public DH key generated by the VM at runtime
/// - `host_data` : Optional VM owner defined data that was passed as HOST_DATA to QEMU during VM launch
/// - `ld` : The expected launch digest of the guest. Use e.g. `compute_expected_hash` to compute this
/// [1] https://www.amd.com/content/dam/amd/en/documents/epyc-technical-docs/specifications/56860.pdf
pub fn check_report_data<F>(
    report: &AttestationReport,
    idblock_data: Option<IDBLockReportData>,
    policy: Option<GuestPolicy>,
    tcb: Option<TcbVersion>,
    plat_info: Option<PlatformInfo>,
    report_data_validator: Option<F>,
    host_data: Option<[u8; 32]>,
    ld: Option<[u8; 48]>,
) -> Result<(), ReportVerificationError>
where
    F: Fn([u8; 64]) -> Result<(), ReportVerificationError>,
{
    if let Some(p) = policy {
        ensure!(report.policy.0 == p.0, PolicyMismatchSnafu{
            expected: p,
            got: report.policy,
        });
    }

    if let Some(idblock_data) = idblock_data {
        idblock_data
            .check(&report).context(InvalidIdBlockSnafu{})?
    }

    if let Some(tcb) = tcb {
        let got = &report.committed_tcb;
        if got.bootloader < tcb.bootloader
            || got.tee < tcb.tee
            || got.snp < tcb.snp
            || got.microcode < tcb.microcode
        {
            return TcbVersionMismatchSnafu{required_minimum:tcb, got:report.committed_tcb}.fail();
        }
    }

    if let Some(pinfo) = plat_info {
        if report.plat_info.0 != pinfo.0 {
            return PlatformInfoMismatchSnafu{
                expected: pinfo,
                got: report.plat_info,
            }.fail();
        }
    }

    if let Some(report_data_validator) = report_data_validator {
        report_data_validator(report.report_data)?;
    }

    if let Some(host_data) = host_data {
        if report.host_data != host_data {
            return HostDataMismatchSnafu{
                expected: host_data,
                got: report.host_data,
            }.fail();
        }
    }

    if let Some(ld) = ld {
        if !report.measurement.eq(&ld) {
            return LaunchDigestMismatchSnafu{
                expected: ld,
                got: report.measurement
            }.fail();
        }
    }

    Ok(())
}

///verify that the signature on the report is valid
///using the static amd certificate chain for the given product family
///as well as the chip specific vcek_cert
/// *DOES NOT* check the data contained in the report
/// Returns Ok on success
pub fn verify_report_signature(
    product_name: ProductName,
    report: &AttestationReport,
    vcek_cert: Certificate,
) -> Result<(), Whatever> {
    let ark;
    let ask;
    match product_name {
        ProductName::Milan => {
            ark = milan::ark().whatever_context("failed to parse ARK certificate")?;
            ask = milan::ask().whatever_context("failed to parse ASK certificate")?;
        }
        ProductName::Genoa => {
            ark = genoa::ark().whatever_context("failed to parse ARK certificate")?;
            ask = genoa::ask().whatever_context("failed to parse ASK certificate")?;
        }
    }

    let ca = ca::Chain { ark, ask };

    let chain = Chain { ca, vek: vcek_cert };

    (&chain, report)
        .verify().whatever_context("invalid attestation report signature")?;
    Ok(())
}
#[derive(Debug, Snafu)]
#[snafu(visibility(pub))]
pub enum ReportVerificationError {
    #[snafu(display("Invalid attestation report signature"))]
    InvalidSignature{source: Whatever},

    #[snafu(display("Invalid policy, expected {:x?} got {:x?}",expected,got))]
    PolicyMismatch{
        expected: GuestPolicy,
        got: GuestPolicy
    },

    #[snafu(display("Invalid ID block data : {}", source.to_string()))]
    InvalidIdBlock{
        source: Whatever
    },

    #[snafu(display("TCB version does not match mininum required version, want at least {:x?} but got {:x?}", required_minimum, got))]
    TcbVersionMismatch{
        required_minimum: TcbVersion,
        got: TcbVersion,
    },

    #[snafu(display("Invalid PlatformInfo, expected {} got {}", expected, got))]
    PlatformInfoMismatch{
        expected: PlatformInfo,
        got: PlatformInfo,
    },

    #[snafu(display("Invalid HostData, expected 0x{} got 0x{}", hex::encode(expected), hex::encode(got)))]
    HostDataMismatch{
        expected: [u8; 32],
        got: [u8; 32],
    },

    #[snafu(display("Invalid launch digest, expected 0x{} got 0x{}", hex::encode(expected), hex::encode(got)))]
    LaunchDigestMismatch{
        expected: [u8; 48],
        got: [u8; 48],
    },

    #[snafu(display("Invalid report data, expected {} got {}",expected, got))]
    ReportDataMismatch{
        expected: String,
        got: String,
    }

}

///Verify the report signature and check that the given data fields match
///See `verify_report_signature` and `check_report_data` for additiona
///documentation
pub fn verify_and_check_report<F>(
    report: &AttestationReport,
    product_name: ProductName,
    vcek_cert: Certificate,
    idblock_data: Option<IDBLockReportData>,
    policy: Option<GuestPolicy>,
    tcb: Option<TcbVersion>,
    plat_info: Option<PlatformInfo>,
    report_data_validator: Option<F>,
    host_data: Option<[u8; 32]>,
    ld: Option<[u8; 48]>,
) -> Result<(), ReportVerificationError>
where
    F: Fn([u8; 64]) -> Result<(), ReportVerificationError>,
{
    //checking the data before checking the signature makes it easier to find the root-cause for errors.
    //If we check the signature first, it could be invalid because of mismatching data or because
    //of an actually invalid signature/signature key
    check_report_data(
        report,
        idblock_data,
        policy,
        tcb,
        plat_info,
        report_data_validator,
        host_data,
        ld,
    )?;
    verify_report_signature(product_name, report, vcek_cert).context(InvalidSignatureSnafu{})
}

#[cfg(test)]
mod tests {
    use std::{fs::File, io::Read};

    use sev::{certs::snp::Certificate, firmware::guest::AttestationReport};
    use snafu::{ResultExt, Whatever};

    use crate::snp_validate_report::{verify_report_signature, ProductName};

    const TEST_REPORT_PATH: &'static str = "./test-data/benign-report.json";
    const TEST_VCEK_CERT_PATH: &'static str = "./test-data/vcek.crt";

    ///helper function that loads the testdata attestation report
    fn load_report() -> Result<AttestationReport, Whatever> {
        let f = File::open(TEST_REPORT_PATH).whatever_context(format!(
            "failed to open test report file at {}",
            TEST_REPORT_PATH
        ))?;
        let report: AttestationReport =
            serde_json::from_reader(f).whatever_context("failed to parse report as json")?;
        Ok(report)
    }

    //Ratelimiting is quite restrictive which makes this test transientliy fail
    // #[test]
    // fn test_get_vceck() -> Result<(), Whatever> {
    //     let report = load_report()?;
    //     println!("Chip ID: {}", hex::encode(report.chip_id));
    //     let cert = download_vceck_cert(report.chip_id, ProductName::Milan, &report.committed_tcb)
    //         .whatever_context("failed to download VCEK")?;
    //     let cert = Certificate::from_bytes(cert.as_slice())
    //         .whatever_context("failed to parse cert bytes")?;
    //     println!("Certificate: {:#?}", cert);

    //     Ok(())
    // }

    #[test]
    fn test_verify() -> Result<(), Whatever> {
        let report = load_report()?;
        let mut cert_file =
            File::open(TEST_VCEK_CERT_PATH).whatever_context("failed to open test cert file")?;
        let mut cert_bytes = Vec::new();
        cert_file
            .read_to_end(&mut cert_bytes)
            .whatever_context("failed to read test cert files")?;
        let cert =
            Certificate::from_bytes(&cert_bytes).whatever_context("failed to parse test cert")?;
        verify_report_signature(ProductName::Milan, &report, cert)?;

        Ok(())
    }
}
