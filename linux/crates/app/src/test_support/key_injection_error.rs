#[derive(Debug, thiserror::Error)]
pub(crate) enum KeyInjectionError {
    #[error("could not connect to the X server: {0}")]
    Connect(#[from] x11rb::errors::ConnectError),
    #[error("the X connection failed: {0}")]
    Connection(#[from] x11rb::errors::ConnectionError),
    #[error("the X server refused a request: {0}")]
    Reply(#[from] x11rb::errors::ReplyError),
    #[error("could not allocate an X resource: {0}")]
    Resource(#[from] x11rb::errors::ReplyOrIdError),
    #[error("no keycode carries keysym {0:#x}")]
    KeysymNotMapped(u32),
    #[error("pointer target ({x}, {y}) is outside the {width} by {height} X screen")]
    PointerOutsideScreen { x: i16, y: i16, width: u16, height: u16 },
    #[error("the widget is not on screen")]
    NotShown,
    /// XTEST reaches GDK only through an X11 display; set GDK_BACKEND=x11.
    #[error("the display is {0}, not X11")]
    NotX11(String),
}
