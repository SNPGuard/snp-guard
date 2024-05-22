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
use sev::firmware::guest::AttestationReport;
use snafu::{whatever, FromString, ResultExt, Whatever};
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
        serde_json::from_reader(req.as_reader()).whatever_context("failed to parse request body as json")?;

    println!("Requesting attestation report");

    let rng = rand::SystemRandom::new();
    let server_private_key = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng)
    .map_err(|_| Whatever::without_source("failed to generate private DH key".to_string())).whatever_context("failed to generate private DH key for server")?;
    let server_public_key = server_private_key
        .compute_public_key()
        .map_err(|_| Whatever::without_source("failed to derive public dh key from private key".to_string())).whatever_context("failed to generate public DH key for server")?
        .as_ref()
        .try_into()
        .whatever_context("generated public dh key has unexpected length, expected 32 bytes")?;

    let att_report: AttestationReport = if config.mock_mode {
        MockSNPAttestation::get_report(att_req.nonce, server_public_key)
            .whatever_context("failed to get mock attestation reort")?
    } else {
        SNPAttestation::get_report(att_req.nonce, server_public_key)
            .whatever_context("failed to request attestation report from secure processor")?
    };

    println!("Got attestation report. Sending it to client");

    let att_report_json =
        serde_json::to_string(&att_report).whatever_context("failed to serialize attestation report as json")?;
    let header =
        tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).expect("should never happen");
    let resp = Response::from_string(att_report_json).with_header(header);
    req.respond(resp).whatever_context("failed to send attestation report to client")?;

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
    agreement::agree_ephemeral(
        key_material.eph_server_dh_key, &client_public_key,
        |key_material| -> Result<(),Whatever>{
            shared_secret
                .write_all(key_material).whatever_context("failed to store derived shared secret in buffer")
        },
    ).map_err(|_| Whatever::without_source("failed to compute shared secret from DH keys".to_string())).whatever_context("failed to derive shared secret")?.whatever_context("internal error")?;

    let unwrapped_disk_key = aead_dec(&shared_secret, key_material.nonce, wrapped_key.wrapped_disk_key).whatever_context("failed to decrypt wrapped disk encryption key")?;
    println!("Decrypted wrapped key");
    let unwrapped_disk_key =
        str::from_utf8(&unwrapped_disk_key).whatever_context("failed to convert unwrapped disk encryption key to string")?;
    const OUT_KEY_FILE: &'static str = "./disk_key.txt";
    let mut out_file = File::create(OUT_KEY_FILE).whatever_context(format!("failed to create output file for disk encryption key at {}",OUT_KEY_FILE))?;
    out_file
        .write_all(unwrapped_disk_key.as_bytes())
        .whatever_context(format!("failed to write disk encrpytion key to file {}", OUT_KEY_FILE))?;

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
        println!("Req URL: {}", req.url());
        if "/reset" == req.url() {
            state = ServerState::Ready;
            println!("Resetting attestation server state");
            req.respond(Response::from_string("Ok")).whatever_context("failed to ack reset request")?;
            continue;
        }
        match state {
            ServerState::Ready => match send_report(req, config) {
                Ok(secret_injectin_params) => {
                    if !config.no_secret_injection {
                        state = ServerState::WaitingForSecretInjection(secret_injectin_params)
                    }
                }
                Err(e) => eprintln!("Error while serving attestation report request: {:#?}", e),
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
