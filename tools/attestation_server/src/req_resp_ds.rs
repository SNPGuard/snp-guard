use ring::aead::Aad;
use ring::aead::BoundKey;
use ring::aead::Nonce;
use ring::aead::NonceSequence;
use ring::aead::OpeningKey;
use ring::aead::SealingKey;
use ring::aead::UnboundKey;
use ring::aead::AES_256_GCM;
use ring::aead::NONCE_LEN;
use ring::error::Unspecified;
use ring::hkdf::{Prk, Salt, HKDF_SHA512};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, Debug)]
pub struct AttestationRequest {
    pub nonce: u64,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct WrappedDiskKey {
    //was encrypted with aead_enc, need to decrypt with aead_dec
    pub wrapped_disk_key: Vec<u8>,
    pub client_public_key: [u8; 32],
}

struct CounterNonceSequence(u64);

impl NonceSequence for CounterNonceSequence {
    // called once for each seal operation
    fn advance(&mut self) -> Result<Nonce, Unspecified> {
        let mut nonce_bytes = vec![0; NONCE_LEN];

        let bytes = self.0.to_be_bytes();
        //TODO:this seems whack. investigate
        nonce_bytes[..8].copy_from_slice(&bytes);
        println!("nonce_bytes = {}", hex::encode(&nonce_bytes));

        self.0 += 1; // advance the counter
        Nonce::try_assume_unique_for_key(&nonce_bytes)
    }
}

fn derive_keys(shared_secret: &[u8], nonce_from_report: u64) -> Vec<u8> {
    let salt = Salt::new(HKDF_SHA512, &nonce_from_report.to_le_bytes());
    let pseudo_rand_key: Prk = salt.extract(shared_secret);
    let context_data = &["aes_key".as_bytes()];
    let mut aes_key = vec![0u8; AES_256_GCM.key_len()];
    pseudo_rand_key
        .expand(context_data, &AES_256_GCM)
        .expect("failed to instantiate aes key generator")
        .fill(&mut aes_key)
        .expect("failed to sample aes key");

    aes_key
}

///outputs ciphertext + tag
pub fn aead_enc(shared_secret: &[u8], nonce_from_report: u64, plaintext: &[u8]) -> Vec<u8> {
    let aes_key = derive_keys(shared_secret, nonce_from_report);

    let unbound_key = UnboundKey::new(&AES_256_GCM, &aes_key).expect("");

    let nonce_sequence = CounterNonceSequence(nonce_from_report);

    let mut sealing_key = SealingKey::new(unbound_key, nonce_sequence);
    let associated_data = Aad::empty();

    let mut ciphertext = Vec::from(plaintext);
    // Encrypt the data with AEAD using the AES_256_GCM algorithm
    let tag = sealing_key
        .seal_in_place_separate_tag(associated_data, &mut ciphertext)
        .expect("failed to encrypt");
    let cypher_text_with_tag = [&ciphertext, tag.as_ref()].concat();
    cypher_text_with_tag
}

///outputs plaintext
pub fn aead_dec(
    shared_secret: &[u8],
    nonce_from_report: u64,
    cipher_text_with_tag: Vec<u8>,
) -> Vec<u8> {
    let aes_key = derive_keys(shared_secret, nonce_from_report);

    let unbound_key = UnboundKey::new(&AES_256_GCM, &aes_key).expect("");

    let nonce_sequence = CounterNonceSequence(nonce_from_report);

    // Create a new AEAD key for decrypting and verifying the authentication tag
    let mut opening_key = OpeningKey::new(unbound_key, nonce_sequence);

    // Decrypt the data by passing in the associated data and the cypher text with the authentication tag appended
    let mut cypher_text_with_tag = cipher_text_with_tag.clone();
    let associated_data = Aad::empty();
    let decrypted_data = opening_key
        .open_in_place(associated_data, &mut cypher_text_with_tag)
        .expect("failed to derypt");

    Vec::from(decrypted_data)
}
