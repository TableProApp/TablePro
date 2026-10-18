use gtk4 as gtk;

use super::WindowLaunch;

/// What a window may ask of the application that hosts it, so a window
/// reaches the others without holding the application.
pub trait WindowHost {
    /// False when no window has that id any more.
    fn present_window(&self, window_id: u32) -> bool;
    fn open_window(&self, launch: WindowLaunch);
    /// `None` once the application is gone.
    fn application(&self) -> Option<gtk::Application>;
}
