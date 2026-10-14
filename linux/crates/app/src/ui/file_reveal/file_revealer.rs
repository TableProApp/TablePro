use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use gtk4::{gio, glib};

/// Shows a file in the file manager. A trait so a test can see what
/// would have been shown without starting one.
pub(crate) trait FileRevealer {
    fn reveal(&self, file: gio::File, parent: Option<gtk::Window>) -> LocalBoxFuture<'static, Result<(), glib::Error>>;
}
