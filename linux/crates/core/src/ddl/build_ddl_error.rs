use thiserror::Error;

use super::{DdlOperation, DraftProblem, ReferentialAction, RefusalReason};
use crate::dialect::LiteralError;
use crate::sql_syntax::TypeSyntaxError;

/// Why a structure change could not be written as SQL.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BuildDdlError {
    #[error(transparent)]
    Draft(#[from] DraftProblem),
    #[error("{0} is not supported by this engine")]
    Unsupported(DdlOperation),
    #[error("column {column}: {operation} is refused because {reason}")]
    Refused {
        column: String,
        operation: DdlOperation,
        reason: RefusalReason,
    },
    #[error("column {column} has an invalid type: {error}")]
    InvalidType { column: String, error: TypeSyntaxError },
    #[error("column {column} has a default with no SQL form: {error}")]
    Literal { column: String, error: LiteralError },
    /// An existing column whose type the catalogue did not spell, so no
    /// statement can restate it.
    #[error("the catalogue gave no type declaration for column {0}")]
    MissingCatalogDeclaration(String),
    #[error("{} is not a referential action this engine accepts", .0.as_sql())]
    ReferentialAction(ReferentialAction),
    /// A table this engine keeps no CREATE statement for, where only the
    /// server's own text would recreate it faithfully.
    #[error("the server gave no CREATE statement for this table")]
    NoTableSource,
    /// A view, trigger or index a table rebuild makes again, whose stored
    /// statement cannot run as it is.
    #[error("the stored statement of {0}, which the rebuild makes again, cannot run as it is")]
    UnreplayableDependent(String),
    /// The statements a save would run are not the ones the user
    /// reviewed, because the draft or the connection changed meanwhile.
    #[error("the statements to run are not the ones reviewed")]
    NotAsReviewed,
}
