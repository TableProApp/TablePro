use std::sync::Arc;

use crate::ColumnInfo;
use crate::meta::{ObjectInfo, SchemaInfo, TableRef};

// What a session's catalog holds for one completion; a list it could not read is None or left out.
#[derive(Debug, Default)]
pub struct CatalogAnswer {
    pub schemas: Option<Arc<[SchemaInfo]>>,
    pub objects: Option<Arc<[ObjectInfo]>>,
    pub columns: Vec<(TableRef, Arc<[ColumnInfo]>)>,
}

// Where an unqualified name resolves for an editor that may run in another of the server's databases.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum CatalogHome {
    // The connection's default schema.
    #[default]
    Connection,
    // Another of the server's databases, which the catalog lists as a schema (MySQL).
    Schema(String),
    // A database the connection's catalog does not describe, so nothing read from it would be right.
    Elsewhere(String),
}
