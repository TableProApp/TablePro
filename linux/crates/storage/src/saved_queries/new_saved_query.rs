use uuid::Uuid;

/// What the user is asking to keep.
#[derive(Debug, Clone)]
pub struct NewSavedQuery {
    pub name: String,
    pub query: String,
    pub connection_id: Uuid,
    pub connection_name: String,
}
