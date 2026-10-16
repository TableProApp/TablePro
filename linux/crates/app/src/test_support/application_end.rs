use gtk4::glib;
use gtk4::prelude::*;

/// End a registered application the way `g_application_run` ends one:
/// `shutdown`, then leaving the session bus, which GLib does only there.
///
/// GtkApplication holds itself from startup until shutdown, so a test
/// that registers one and drops it leaks it with every service it owns.
/// The run activates the application once, which presents a window it
/// still has or opens one, and quits at its first main loop iteration.
pub(crate) fn end_application(app: &impl IsA<gio::Application>) {
    let quitting = app.clone();
    glib::idle_add_local_once(move || {
        #[expect(
            clippy::disallowed_methods,
            reason = "ends the run this helper starts; the app quits through request_quit, which asks each window"
        )]
        quitting.quit();
    });
    app.run_with_args::<&str>(&[]);
}
