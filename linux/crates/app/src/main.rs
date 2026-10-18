use tablepro_app::StartupError;

fn main() -> glib::ExitCode {
    match tablepro_app::run() {
        Ok(code) => code,
        Err(StartupError::Logging(error)) => {
            // Nothing is journalling yet, so this is the one place that
            // has to reach the session log by another route.
            glib::g_critical!("tablepro", "{error}");
            glib::ExitCode::FAILURE
        }
        Err(error) => {
            tracing::error!(%error, "TablePro could not start");
            glib::ExitCode::FAILURE
        }
    }
}
