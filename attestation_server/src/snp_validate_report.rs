use std::{
    fmt::Display,
    fs::{self, File},
    io::{self, Read, Write},
    path::PathBuf,
};

use reqwest::{blocking, Url};
use sev::{
    certs::snp::{
        builtin::{genoa, milan},
        ca, Certificate, Chain, Verifiable,
    },
    firmware::{guest::AttestationReport, host::TcbVersion},
};
use snafu::{whatever, ResultExt, Whatever};

#[derive(Copy, Clone, Debug, PartialEq)]
pub enum ProductName {
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
        fs::create_dir(&temp_path).whatever_context(format!("path {:?}", temp_path))?;
        Ok(CachingVCEKDownloader {
            cache_folder_path: temp_path,
        })
    }

    ///helper function that maps each certificate to a unique filename
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

///verify that the signature on the report is valid
//using the static amd certificate chain for the given product family
//as well as the chip specific vcek_cert
pub fn verify_report_signature(
    product_name: ProductName,
    report: &AttestationReport,
    vcek_cert: Certificate,
) -> Result<bool, Whatever> {
    if product_name != ProductName::Milan {
        whatever!("for now only milan is implemented");
    }
    let ark;
    let ask;
    match product_name {
        ProductName::Milan => {
            ark = milan::ark().unwrap();
            ask = milan::ask().unwrap();
        }
        ProductName::Genoa => {
            ark = genoa::ark().unwrap();
            ask = genoa::ark().unwrap();
        }
    }

    let ca = ca::Chain { ark, ask };

    let chain = Chain { ca, vek: vcek_cert };

    (&chain, report)
        .verify()
        .expect("cert errror. itroduce error type");

    Ok(true)
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
