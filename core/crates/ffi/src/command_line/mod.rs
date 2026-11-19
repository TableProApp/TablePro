// The Windows package's console command, core/docs/decisions/0036-mcp-and-the-command-line-through-the-ffi.md.

#[cfg(any(windows, test))]
mod app_files;
#[cfg(windows)]
mod windows_host;

use std::process::ExitCode;

#[cfg(windows)]
pub fn main() -> ExitCode {
    use std::ffi::OsString;
    use std::io::Write;

    use tablepro_cli::Dispatch;

    let args: Vec<OsString> = std::env::args_os().collect();
    // Before anything else is read, so --help and completion work with no app and no settings.
    match tablepro_cli::classify(&args) {
        Dispatch::Command => {
            let host = windows_host::WindowsHost::current();
            let (stdout, stderr) = (std::io::stdout(), std::io::stderr());
            tablepro_cli::run(args, &host, &mut stdout.lock(), &mut stderr.lock()).into()
        }
        Dispatch::Invalid(message) => {
            // Nothing is left to report a failed write to.
            let _ = writeln!(std::io::stderr().lock(), "{message}");
            tablepro_cli::Exit::Usage.into()
        }
        Dispatch::Gui(args) => match open_in_app(args.into_iter().skip(1)) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                let _ = writeln!(std::io::stderr().lock(), "tablepro: Could not start TablePro: {error}");
                tablepro_cli::Exit::Failure.into()
            }
        },
    }
}

#[cfg(not(windows))]
pub fn main() -> ExitCode {
    use std::io::Write;

    let _ = writeln!(
        std::io::stderr().lock(),
        "tablepro-cli is the Windows app's command; the Linux app is its own tablepro command."
    );
    ExitCode::FAILURE
}

// Nothing of this console goes to the app, so a pipe the command writes to closes when the command ends.
#[cfg(windows)]
fn open_in_app(args: impl Iterator<Item = std::ffi::OsString>) -> std::io::Result<()> {
    use std::process::{Command, Stdio};

    let app = app_beside().ok_or_else(|| std::io::Error::other("TablePro.exe is not beside the command"))?;
    Command::new(app)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(drop)
}

#[cfg(windows)]
fn app_beside() -> Option<std::path::PathBuf> {
    let app = std::env::current_exe().ok()?.with_file_name("TablePro.exe");
    app.is_file().then_some(app)
}
