#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TlsFailure {
    UnknownIssuer,
    NameMismatch,
    Expired,
    NotYetValid,
    Revoked,
    ServerRefusedTls,
    ServerRequiresTls,
    HandshakeRejected,
    CaFileInvalid,
    ClientIdentityInvalid,
    Other,
}
