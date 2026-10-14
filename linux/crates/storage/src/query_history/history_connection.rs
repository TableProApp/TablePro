use uuid::Uuid;

/// A connection the history holds entries for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryConnection {
    pub id: Uuid,
    /// The name it had when it last ran a query.
    pub name: String,
}
