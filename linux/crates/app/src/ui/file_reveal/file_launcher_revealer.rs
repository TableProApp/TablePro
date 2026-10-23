use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use gtk4::{gio, glib};

use super::FileRevealer;

/// Opens the folder with the file selected, or a folder itself, through
/// the file manager or, inside Flatpak, the OpenURI portal.
pub(crate) struct FileLauncherRevealer;

impl FileRevealer for FileLauncherRevealer {
    fn reveal(&self, file: gio::File, parent: Option<gtk::Window>) -> LocalBoxFuture<'static, Result<(), glib::Error>> {
        gtk::FileLauncher::new(Some(&file)).open_containing_folder_future(parent.as_ref())
    }

    fn open_folder(
        &self,
        folder: gio::File,
        parent: Option<gtk::Window>,
    ) -> LocalBoxFuture<'static, Result<(), glib::Error>> {
        gtk::FileLauncher::new(Some(&folder)).launch_future(parent.as_ref())
    }
}
