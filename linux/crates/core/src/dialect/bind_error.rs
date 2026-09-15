use thiserror::Error;

use crate::column::SqlTypeExpr;

/// Why a value could not become a bound parameter.
///
/// Binding is where a wrong type is caught, before the SQL reaches the
/// server. An undecodable value is refused outright: the driver could
/// not read it, so writing it back would replace bytes it never
/// understood.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BindError {
    #[error("a {expected} parameter cannot hold a {found} value")]
    ValueTypeMismatch {
        expected: &'static str,
        found: &'static str,
    },
    #[error("binding to {type_name} needs the column's catalogue type, which is not known here")]
    MissingCatalogType { type_name: SqlTypeExpr },
    #[error("this value could not be read from the server, so it cannot be written back: {reason}")]
    Undecodable { reason: String },
    #[error("{found} cannot be represented as {expected}")]
    Unrepresentable {
        expected: &'static str,
        found: &'static str,
    },
}
