use uuid::Uuid;

/// What is closing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseScope {
    /// Every tab the window holds: the window closing, or the workspace
    /// going with a disconnect or a switch to another connection.
    Window,
    Tab(Uuid),
}

impl CloseScope {
    pub fn covers(self, tab: Uuid) -> bool {
        match self {
            Self::Window => true,
            Self::Tab(id) => id == tab,
        }
    }
}
