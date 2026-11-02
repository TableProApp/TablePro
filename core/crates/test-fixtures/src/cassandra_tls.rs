/// What a `CassandraFixture`'s native port accepts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CassandraTls {
    /// Plaintext only.
    #[default]
    Off,
    /// TLS only, with no client certificate asked for.
    Required,
    /// TLS only, from a client whose certificate the test CA signed. The
    /// requirement is the whole server's: neither engine can ask one
    /// role for a certificate and another not.
    ClientCertificate,
}

impl CassandraTls {
    pub fn is_on(self) -> bool {
        self != Self::Off
    }
}
