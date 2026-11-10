mod linux_host;

use std::ffi::OsString;
use std::io::Write;
use std::process::ExitCode;

pub use linux_host::LinuxHost;

pub fn run(args: Vec<OsString>) -> ExitCode {
    let host = LinuxHost;
    let (stdout, stderr) = (std::io::stdout(), std::io::stderr());
    tablepro_cli::run(args, &host, &mut stdout.lock(), &mut stderr.lock()).into()
}

pub fn refuse(message: &str) -> ExitCode {
    // Nothing is left to report a failed write to.
    let _ = writeln!(std::io::stderr().lock(), "{message}");
    tablepro_cli::Exit::Usage.into()
}
