//! Server to run inside the VM to perform attestation and securely receive a (disk encryption) secret
use std::{env, fs::File, io::Write, str};

use attestation_server::{
    req_resp_ds::{aead_dec, AttestationRequest, WrappedDiskKey},
    snp_attestation::{MockSNPAttestation, QuerySNPAttestation, SNPAttestation},
};
use ring::{
    agreement::{self, EphemeralPrivateKey},
    rand,
};
use snafu::{whatever, ResultExt, Whatever};
use tiny_http::{Request, Response, Server};

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

struct Config {
    no_secret_injection: bool,
    mock_mode: bool,
    listen : String,
}

struct SecretInjectionParams {
    nonce: u64,
    eph_server_dh_key: EphemeralPrivateKey,
}
enum ServerState {
    ///Ready to handle attestation report requests
    Ready,
    ///Send attestation report + public DH to client, waiting for response
    WaitingForSecretInjection(SecretInjectionParams),
}

///Fetch attestation report and generate key material the DH key deriviation used for secret injection
fn send_report(mut req:  Request, config: &Config) -> Result<SecretInjectionParams, Whatever> {
    let att_req: AttestationRequest =
        serde_json::from_reader(req.as_reader()).whatever_context("failed to deserialize")?;
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

    let att_report = if config.mock_mode {
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

    Ok(SecretInjectionParams{
        nonce: att_req.nonce,
        eph_server_dh_key: server_private_key,
    })
}

///Process secret injection request and write derived key to disk
/// # Arguments
/// - `req`: http request with the raw data
/// - `key_material` : nonce from client + 
fn process_injected_secret(mut req: Request, key_material: SecretInjectionParams) -> Result<(), Whatever> {
    
    let wrapped_key: WrappedDiskKey =
        serde_json::from_reader(req.as_reader()).whatever_context("failed to deserialize")?;

    let client_public_key =
        agreement::UnparsedPublicKey::new(&agreement::X25519, wrapped_key.client_public_key);
    let mut shared_secret = Vec::new();
    agreement::agree_ephemeral(key_material.eph_server_dh_key, &client_public_key, |key_material| {
        shared_secret
            .write_all(key_material)
            .expect("failed to store key material");
        // In a real application, we'd apply a KDF to the key material and the
        // public keys (as recommended in RFC 7748) and then derive session
        // keys from the result. We omit all that here.
    })
    .expect("failed to generate shared key");

    println!("Decrypted wrapped key");
    let unwrapped_disk_key = aead_dec(&shared_secret, key_material.nonce, wrapped_key.wrapped_disk_key);
    let unwrapped_disk_key =
        str::from_utf8(&unwrapped_disk_key).expect("failed to convert unwrapped key to string");
    let mut out_file = File::create("./disk_key.txt").expect("failed to create disk key");
    out_file
        .write_all(unwrapped_disk_key.as_bytes())
        .expect("failed to write to file");

    Ok(())
}

fn run(config: &Config) -> Result<(), Whatever> {
    let mut state = ServerState::Ready;
    let server = match tiny_http::Server::http(&config.listen) {
        Ok(v) => v,
        Err(e) => {whatever!("failed to start http server: {:#?}", e)},
    };
    loop {
        let req = wait_for_request(&server);
        match state {
            ServerState::Ready => match send_report(req, config) {
                Ok(secret_injectin_params) => {
                    if !config.no_secret_injection {
                        state = ServerState::WaitingForSecretInjection(secret_injectin_params)
                    }
                }
                Err(e) => eprintln!("Error while serving attestation report: {:#?}", e),
            },
            ServerState::WaitingForSecretInjection(params) => {
                match process_injected_secret(req, params) {
                    Ok(_) => {
                        eprintln!("Secret injection succeeded! Shutting down attestation server...");
                        return Ok(());
                    },
                    Err(e) => {
                        eprintln!("Error processing injected secret : {:#?}", e);
                        eprintln!("Send another attestation report request to try again");
                        state = ServerState::Ready;
                    }
                }
            }
        }
    }
}

fn main() -> Result<(), Whatever>{
    let config = Config{
        no_secret_injection: env::var("NO_SECRET_INJECTION").is_ok(),
        mock_mode: env::var("MOCK").is_ok(),
        listen: env::var("LISTEN").unwrap_or("0.0.0.0:80".to_string()),
    };
    println!("Starting attestation server on {}",&config.listen);
    run(&config)
}
