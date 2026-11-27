use uuid::Uuid;

// What the user is asking to keep. With no connection, the query is in every connection.
#[derive(Debug, Clone)]
pub struct NewSavedQuery {
    pub name: String,
    pub query: String,
    pub connection_id: Option<Uuid>,
    pub connection_name: String,
}
