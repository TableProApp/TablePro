#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ServerNameOverride {
    AnyRoute,
    SshForwardOnly,
    Unsupported,
}
