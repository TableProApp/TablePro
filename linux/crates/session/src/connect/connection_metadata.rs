use uuid::Uuid;

/// What names a session, for titles, logs and keyring labels.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionMetadata {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
}
