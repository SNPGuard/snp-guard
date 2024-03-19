use std::io::Write;

use ring::agreement::{self, UnparsedPublicKey};
use sev::{
    error::UserApiError,
    firmware::guest::{AttestationReport, Firmware},
};

pub struct ReportData {
    pub nonce: u64,
    pub server_public_key: UnparsedPublicKey<[u8; 32]>,
}

impl ReportData {
    pub fn new(nonce: u64, public_key: [u8; 32]) -> Self {
        let pk = agreement::UnparsedPublicKey::new(&agreement::X25519, public_key);
        ReportData {
            nonce,
            server_public_key: pk,
        }
    }
}

impl Into<[u8; 64]> for ReportData {
    fn into(self) -> [u8; 64] {
        let mut in_data = Vec::new();
        in_data
            .write_all(&self.nonce.to_le_bytes())
            .expect("failed to write nonce");
        in_data
            .write_all(self.server_public_key.as_ref())
            .expect("failed to write pubkey");
        const OUT_LEN: usize = 64;
        assert!(in_data.len() < OUT_LEN);
        in_data.resize(OUT_LEN, 0);
        in_data
            .try_into()
            .expect("failed to convert user data to fixed size slice")
    }
}

impl From<[u8; 64]> for ReportData {
    fn from(value: [u8; 64]) -> Self {
        let mut raw_le_nonce = [0u8; 8];
        let mut raw_pubkey = [0u8; 32];
        raw_le_nonce.copy_from_slice(&value[..8]);
        raw_pubkey.copy_from_slice(&value[8..(8 + 32)]);
        let nonce = u64::from_le_bytes(raw_le_nonce);
        let server_public_key = agreement::UnparsedPublicKey::new(&agreement::X25519, raw_pubkey);
        ReportData {
            nonce,
            server_public_key,
        }
    }
}

pub trait QuerySNPAttestation {
    fn get_report(
        nonce: u64,
        server_public_key: [u8; 32],
    ) -> Result<AttestationReport, UserApiError>;
}

pub struct MockSNPAttestation {}

impl QuerySNPAttestation for MockSNPAttestation {
    fn get_report(
        nonce: u64,
        server_public_key: [u8; 32],
    ) -> Result<AttestationReport, UserApiError> {
        let mut report = AttestationReport::default();
        report.report_data = ReportData::new(nonce, server_public_key).into();
        Ok(report)
    }
}

pub struct SNPAttestation {}

impl QuerySNPAttestation for SNPAttestation {
    fn get_report(
        nonce: u64,
        server_public_key: [u8; 32],
    ) -> Result<AttestationReport, UserApiError> {
        let mut fw = Firmware::open()?;
        let report_data = ReportData::new(nonce, server_public_key);
        fw.get_report(None, Some(report_data.into()), None)
    }
}
