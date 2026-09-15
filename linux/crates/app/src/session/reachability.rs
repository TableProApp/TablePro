/// Whether the network can currently reach this session's endpoint.
///
/// Per-endpoint rather than a global default-route flag: a laptop with
/// a working link but no route to one bastion is offline for that
/// session and online for the SQLite file open next to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Reachability {
    #[default]
    Reachable,
    Unreachable,
}

impl Reachability {
    pub fn is_reachable(self) -> bool {
        matches!(self, Self::Reachable)
    }
}
