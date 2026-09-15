use super::{ColumnKind, ReadForm, SqlTypeExpr};

/// A column's type: what the app needs to render and edit it, plus the
/// server's own spelling for round-tripping it into DDL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnType {
    /// What the user sees, which is the server's spelling.
    name: SqlTypeExpr,
    kind: ColumnKind,
    catalog: CatalogType,
    /// Whether the server decides the stored width per row, so a
    /// declared length is a cap rather than a promise.
    dynamic_storage: bool,
    read_form: ReadForm,
}

/// The engine's own identification of the type, which the driver needs
/// to bind a parameter back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogType {
    /// No catalogue identifier: the type is known only by its name.
    Unknown,
    /// PostgreSQL pg_type.oid, and any engine that numbers its types.
    Oid(u32),
    /// A named catalogue entry, such as a MySQL column_type string or a
    /// ClickHouse type expression.
    Named(SqlTypeExpr),
}

impl ColumnType {
    pub fn new(
        name: SqlTypeExpr,
        kind: ColumnKind,
        catalog: CatalogType,
        dynamic_storage: bool,
        read_form: ReadForm,
    ) -> Self {
        Self {
            name,
            kind,
            catalog,
            dynamic_storage,
            read_form,
        }
    }

    /// The fallback for a type no driver placed: the value is the
    /// server's text and the grid treats it as such.
    pub fn untyped_text(name: SqlTypeExpr) -> Self {
        Self {
            name,
            kind: ColumnKind::Other,
            catalog: CatalogType::Unknown,
            dynamic_storage: true,
            read_form: ReadForm::ServerText,
        }
    }

    pub fn name(&self) -> &SqlTypeExpr {
        &self.name
    }

    pub fn kind(&self) -> ColumnKind {
        self.kind
    }

    pub fn catalog(&self) -> &CatalogType {
        &self.catalog
    }

    pub fn dynamic_storage(&self) -> bool {
        self.dynamic_storage
    }

    pub fn read_form(&self) -> ReadForm {
        self.read_form
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn untyped_text_reads_as_server_text() {
        let column = ColumnType::untyped_text(SqlTypeExpr::from_catalog_text("geography"));

        assert_eq!(column.kind(), ColumnKind::Other);
        assert_eq!(column.read_form(), ReadForm::ServerText);
        assert_eq!(column.catalog(), &CatalogType::Unknown);
        assert!(column.dynamic_storage());
        assert_eq!(column.name().as_sql(), "geography");
    }
}
