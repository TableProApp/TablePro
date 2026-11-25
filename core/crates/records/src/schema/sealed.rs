// Envelopes and history entries carry only ciphertext and the key version the server checks (0051, Key object bodies;
// 0056, Envelopes and history).

use super::Class::Inert;
use super::Role::Content;
use super::{Field, Type};
use crate::kind::Kind;

const fn field(key: &'static str, ty: Type) -> Field {
    Field {
        key,
        ty,
        class: Inert,
        role: Content,
    }
}

pub const SEALED: &[Field] = &[
    field("suite", Type::Text),
    field("kv", Type::Integer),
    field("nonce", Type::Bytes(Some(12))),
    field("ct", Type::Bytes(None)),
];

const SOURCES: &[&str] = &[
    "editor",
    "explain",
    "table_browse",
    "row_edit",
    "structure_ddl",
    "import",
    "mcp",
    "script",
    "shortcuts",
    "command_line",
];

const STATEMENT_TYPES: &[&str] = &["select", "insert", "update", "delete", "ddl", "other"];

// The `entry` a history entry's plaintext holds (0056, History entry). Which rows a device pins stays on the device
// (0052, History).
pub const HISTORY_ENTRY: &[Field] = &[
    field("query", Type::Text),
    field("connection_id", Type::Reference(Kind::Connection)),
    field("connection_name", Type::Text),
    field("database_type", Type::Text),
    field("database", Type::Text),
    field("schema", Type::Text),
    field("source", Type::Enum(SOURCES)),
    field("statement_type", Type::Enum(STATEMENT_TYPES)),
    field("executed_at", Type::Millis),
    field("duration_ms", Type::Integer),
    field("first_row_ms", Type::Integer),
    field("server_ms", Type::Integer),
    field("row_count", Type::Integer),
    field("succeeded", Type::Boolean),
    field("cancelled", Type::Boolean),
    field("error", Type::Text),
];
