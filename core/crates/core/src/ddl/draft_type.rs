use super::BuildDdlError;
use crate::column::ColumnType;
use crate::dialect::SqlDialect;

/// A draft column's type: the catalogue's own, or text the user typed.
///
/// The catalogue's declaration is spliced as the server gave it and is
/// never parsed again. Typed text goes through the engine's parser when
/// it is planned, and is spliced exactly as typed once it passes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DraftType {
    Catalog(ColumnType),
    Typed(String),
}

/// A draft type ready to splice, with what the engine says it holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedType {
    pub sql: String,
    pub column_type: ColumnType,
}

impl DraftType {
    /// The text the user sees and edits. Empty for a catalogue type the
    /// server did not spell.
    pub fn text(&self) -> &str {
        match self {
            Self::Catalog(column_type) => column_type
                .catalog
                .as_ref()
                .map_or("", |catalog| catalog.declaration.as_sql()),
            Self::Typed(text) => text.trim(),
        }
    }

    /// What the column holds, for writing a default in its literal form.
    /// A catalogue type needs no declaration for that.
    pub fn column_type(&self, dialect: &dyn SqlDialect, column: &str) -> Result<ColumnType, BuildDdlError> {
        match self {
            Self::Catalog(column_type) => Ok(column_type.clone()),
            Self::Typed(_) => self.resolve(dialect, column).map(|resolved| resolved.column_type),
        }
    }

    pub fn resolve(&self, dialect: &dyn SqlDialect, column: &str) -> Result<ResolvedType, BuildDdlError> {
        match self {
            Self::Catalog(column_type) => {
                let catalog = column_type
                    .catalog
                    .as_ref()
                    .ok_or_else(|| BuildDdlError::MissingCatalogDeclaration(column.to_owned()))?;
                Ok(ResolvedType {
                    sql: catalog.declaration.as_sql().to_owned(),
                    column_type: column_type.clone(),
                })
            }
            Self::Typed(text) => {
                let column_type = dialect.parse_type(text).map_err(|error| BuildDdlError::InvalidType {
                    column: column.to_owned(),
                    error,
                })?;
                Ok(ResolvedType {
                    sql: text.trim().to_owned(),
                    column_type,
                })
            }
        }
    }
}
