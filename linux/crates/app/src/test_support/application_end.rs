use gtk4::glib;
use gtk4::prelude::*;

/// End a registered application the way `g_application_run` ends one:
/// `shutdown`, then leaving the session bus, which GLib does only there.
///
/// GtkApplication holds itself from startup until shutdown, so a test
/// that registers one and drops it leaks it with every service it owns.
/// Destroy the windows first, as a quit closes them. The run would then
/// activate the application, which restores a session or opens a window
/// after the test is over, so `activate` stops before the application's
/// own handler, and the run quits at its first main loop iteration.
pub(crate) fn end_application(app: &impl IsA<gio::Application>) {
    let inert = app.connect_activate(|app| app.stop_signal_emission_by_name("activate"));
    let quitting = app.clone();
    glib::idle_add_local_once(move || {
        #[expect(
            clippy::disallowed_methods,
            reason = "ends the run this helper starts; the app quits through request_quit, which asks each window"
        )]
        quitting.quit();
    });
    app.run_with_args::<&str>(&[]);
    app.disconnect(inert);
}
