use super::{
    CollationName, ColumnCompression, ColumnKeyRoles, ColumnStorage, ColumnVisibility, GeneratedColumn, IdentityStyle,
    UnmodeledAttribute,
};
use crate::column::SqlExpression;

/// What a column definition says beyond its name, type, nullability and
/// default.
///
/// MySQL and SQL Server redefine a column as a whole, so anything left
/// out of the new definition is lost. Each attribute here is one a
/// redefinition has to restate to keep the column as it was.
///
/// The comment is not here: `ColumnInfo` carries it, because browse and
/// the structure tab read it from `fetch_columns` too.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ColumnAttributes {
    /// Set only when it differs from the type's or table's default, so a
    /// restated definition does not pin a collation nobody chose.
    pub collation: Option<CollationName>,
    pub character_set: Option<String>,
    /// MySQL `ON UPDATE`, which sets the column on every row update.
    pub on_update: Option<SqlExpression>,
    pub generated: Option<GeneratedColumn>,
    pub visibility: ColumnVisibility,
    /// MySQL `SRID` on a spatial column.
    pub spatial_reference: Option<u32>,
    /// SQL Server `SPARSE`.
    pub sparse: bool,
    /// The function a SQL Server dynamic data mask applies, as in
    /// `email()`. ALTER COLUMN drops the mask, which shows the data to
    /// every user without UNMASK.
    pub masking_function: Option<String>,
    /// A CHECK constraint MariaDB keeps on the column itself. MODIFY
    /// drops it unless the definition restates it; every other engine
    /// keeps a CHECK on the table, where a redefinition leaves it alone.
    pub check: Option<SqlExpression>,
    /// PostgreSQL `SET STORAGE`, set only when it differs from the
    /// type's own.
    pub storage: Option<ColumnStorage>,
    /// PostgreSQL `SET COMPRESSION`, set only when the column names a
    /// method rather than following the server's default.
    pub compression: Option<ColumnCompression>,
    pub identity: IdentityStyle,
    /// The SQL Server constraint that holds the default. A type change
    /// has to drop it by name first and add it back afterwards.
    pub default_constraint_name: Option<String>,
    pub key_roles: ColumnKeyRoles,
    pub unmodeled: Vec<UnmodeledAttribute>,
}
