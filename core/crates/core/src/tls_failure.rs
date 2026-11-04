#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TlsFailure {
    UnknownIssuer,
    NameMismatch,
    Expired,
    NotYetValid,
    Revoked,
    ServerRefusedTls,
    ServerRequiresTls,
    /// The server closed a strict connection before answering it: it does
    /// not speak strict TLS, or has no certificate set up for it.
    ServerRefusedStrict,
    /// The server closed a connection that did not start with TLS before
    /// answering it, as a server that allows only strict TLS does.
    ServerRequiresStrict,
    HandshakeRejected,
    CaFileInvalid,
    ClientIdentityInvalid,
    Other,
}
