//! Server to run inside the VM to perform attestation and securely receive a (disk encryption) secret
use std::{env, fs::File, io::Write, str};

use attestation_server::{
    req_resp_ds::{aead_dec, AttestationRequest, WrappedDiskKey},
    snp_attestation::{MockSNPAttestation, QuerySNPAttestation, SNPAttestation},
};
use ring::{
    agreement::{self, UnparsedPublicKey},
    rand,
};
use tiny_http::{Header, Request, Response, Server};

fn wait_for_request(server: &Server) -> Request {
    loop {
        match server.recv() {
            Ok(rq) => return rq,
            Err(e) => {
                println!("error receiving request: {}", e);
            }
        };
    }
}

fn main() {
    let mock_mode = match env::var("MOCK") {
        Ok(_) => true,
        Err(_) => false,
    };
    let listen = env::var("LISTEN").unwrap_or("0.0.0.0:80".to_string());
    println!("Attestation server is listening on {}", listen);
    let server = tiny_http::Server::http(listen).expect("Failed to start webserver");

    //
    //Phase1 : Client requests attestation report. We send our public key agreement key
    //

    let mut req = wait_for_request(&server);

    println!("Request Meatadata: {:?}", req);
    let att_req: AttestationRequest =
        serde_json::from_reader(req.as_reader()).expect("failed to deserialize");
    println!("Request Body: {:?}", att_req);

    println!("Requesting attestation report");

    let rng = rand::SystemRandom::new();
    let server_private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
        .expect("failed to generate private server key");
    let server_public_key = server_private_key
        .compute_public_key()
        .expect("failed to compute public key")
        .as_ref()
        .try_into()
        .expect("unexpected public key length");

    let att_report = if mock_mode {
        MockSNPAttestation::get_report(att_req.nonce, server_public_key)
            .expect("failed to get mock attestation reort")
    } else {
        SNPAttestation::get_report(att_req.nonce, server_public_key)
            .expect("failed to get real attestation report")
    };

    println!("Got attestation report. Sending it to client");

    let att_report_json =
        serde_json::to_string(&att_report).expect("failed to serialize report as json");
    let header =
        tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
    let resp = Response::from_string(att_report_json).with_header(header);
    req.respond(resp).expect("failed to send response");

    //
    //Phase2: Client sends the encrypted disk encryption key as well as their public key agreement key
    //
    println!("Waiting for client to send wrapped disk encryption key");
    let mut req = wait_for_request(&server);
    println!("Received request");
    let wrapped_key: WrappedDiskKey =
        serde_json::from_reader(req.as_reader()).expect("failed to deserialize");

    let client_public_key =
        agreement::UnparsedPublicKey::new(&agreement::X25519, wrapped_key.client_public_key);
    let mut shared_secret = Vec::new();
    agreement::agree_ephemeral(server_private_key, &client_public_key, |key_material| {
        shared_secret
            .write_all(key_material)
            .expect("failed to store key material");
        // In a real application, we'd apply a KDF to the key material and the
        // public keys (as recommended in RFC 7748) and then derive session
        // keys from the result. We omit all that here.
    })
    .expect("failed to generate shared key");

    println!("Decrypted wrapped key");
    let unwrapped_disk_key = aead_dec(&shared_secret, att_req.nonce, wrapped_key.wrapped_disk_key);
    let unwrapped_disk_key =
        str::from_utf8(&unwrapped_disk_key).expect("failed to convert unwrapped key to string");
    println!("unwrapped_disk_key: {}", unwrapped_disk_key);
    let mut out_file = File::create("./disk_key.txt").expect("failed to create disk key");
    out_file
        .write_all(unwrapped_disk_key.as_bytes())
        .expect("failed to write to file");
}
