//! Helper that show information about the sev config on the host system

use sev::firmware::host::Firmware;
use snafu::{ResultExt, Whatever};

fn main() -> Result<(), Whatever> {
    let mut firmware: Firmware = Firmware::open().whatever_context("failed to talk to HW")?;

    let platform_status = firmware
        .snp_platform_status()
        .whatever_context("error getting platform status")?;

    println!("{:#?}", platform_status);

    Ok(())
}
