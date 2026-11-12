use std::ffi::OsString;
use std::process::ExitCode;

use tablepro_app::StartupError;
use tablepro_cli::Dispatch;

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().collect();
    // Before any of the GUI's setup, so a command runs with no display and no installed schema.
    match tablepro_cli::classify(&args) {
        Dispatch::Command => tablepro_app::command_line::run(args),
        Dispatch::Invalid(message) => tablepro_app::command_line::refuse(&message),
        Dispatch::Gui(args) => gui(args),
    }
}

fn gui(args: Vec<OsString>) -> ExitCode {
    match tablepro_app::run(args) {
        Ok(code) => code.into(),
        Err(StartupError::Logging(error)) => {
            // Nothing is journalling yet, so this is the one place that
            // has to reach the session log by another route.
            glib::g_critical!("tablepro", "{error}");
            ExitCode::FAILURE
        }
        Err(error) => {
            tracing::error!(%error, "TablePro could not start");
            ExitCode::FAILURE
        }
    }
}
