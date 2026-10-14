/// A host key the user reviewed from a parked session and chose to
/// trust: the host ssh named and the key it showed for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewedHostKey {
    pub host: String,
    pub fingerprint: String,
}
