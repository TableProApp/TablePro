use tablepro_session::SessionKey;

/// What a window may ask of the application that hosts it, so a window
/// reaches the others without holding the application.
pub trait WindowHost {
    /// Bring the window forward with the session under `key` in front
    /// of the others it holds. False when no window has that id.
    fn present_session(&self, window_id: u32, key: &SessionKey) -> bool;
}
