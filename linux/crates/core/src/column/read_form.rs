/// How a driver got the value off the wire, which decides whether a
/// round-trip is lossless.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReadForm {
    /// Decoded into a typed Rust value with no precision lost.
    Native,
    /// Read as the server's own text. Exact, but the app cannot compute
    /// with it beyond what the text says.
    ServerText,
    /// Read as a numeric string the server formatted. Exact to the
    /// column's declared precision.
    ServerNumeric,
}

impl ReadForm {
    /// Whether the value is the server's text rather than a decoded
    /// value. Export writes those through unchanged.
    pub fn is_server_text(self) -> bool {
        matches!(self, Self::ServerText | Self::ServerNumeric)
    }
}
