use super::{ColumnDefinition, DdlCapabilities, IdentityStyle, Permission, RefusalReason, TableDefinition};

/// Which changes one existing column takes, each with the reason when
/// it does not.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ColumnCapabilities {
    pub rename: Permission,
    pub drop: Permission,
    pub alter_type: Permission,
    pub alter_nullability: Permission,
    pub alter_default: Permission,
    pub alter_primary_key: Permission,
    pub alter_auto_increment: Permission,
}

impl ColumnCapabilities {
    /// What every engine refuses on top of its own capabilities: a
    /// restatement that would drop a generated expression or an
    /// attribute this build cannot restate, a default on a numbered
    /// column, and anything foreign keys elsewhere depend on.
    pub fn standard(capabilities: &DdlCapabilities, table: &TableDefinition, column: &ColumnDefinition) -> Self {
        let attributes = &column.attributes;
        let engine = |allowed: bool| Permission::unless(allowed, RefusalReason::EngineUnsupported);
        let not_generated = || {
            Permission::unless(
                !column.info.is_generated && attributes.generated.is_none(),
                RefusalReason::GeneratedColumn,
            )
        };
        let modeled = || match attributes.unmodeled.first() {
            Some(attribute) => Permission::Refused(RefusalReason::UnmodeledAttribute(attribute.name.clone())),
            None => Permission::Allowed,
        };
        let not_numbered = || {
            Permission::unless(
                attributes.identity == IdentityStyle::None && !column.info.is_auto_increment,
                RefusalReason::IdentityColumn,
            )
        };
        let referencing: Vec<String> = table
            .inbound_foreign_keys
            .iter()
            .filter(|key| key.referenced_columns.iter().any(|name| name == column.name()))
            .map(|key| key.name.clone())
            .collect();
        Self {
            rename: engine(capabilities.rename_column),
            drop: engine(capabilities.drop_column).and(|| {
                Permission::unless(
                    referencing.is_empty(),
                    RefusalReason::ReferencedByForeignKeys(referencing),
                )
            }),
            alter_type: engine(capabilities.alter_column_type).and(not_generated).and(modeled),
            alter_nullability: engine(capabilities.alter_column_nullability)
                .and(not_generated)
                .and(modeled),
            alter_default: engine(capabilities.alter_column_default)
                .and(not_generated)
                .and(not_numbered)
                .and(modeled),
            alter_primary_key: primary_key_permission(capabilities, table),
            alter_auto_increment: engine(capabilities.alter_auto_increment)
                .and(not_generated)
                .and(modeled),
        }
    }
}

/// Whether the table's primary key can move. A foreign key elsewhere
/// that points at the key holds its constraint in place: PostgreSQL
/// needs CASCADE to drop it, and MySQL, SQL Server and SQLite refuse
/// the change or leave the reference dangling.
pub fn primary_key_permission(capabilities: &DdlCapabilities, table: &TableDefinition) -> Permission {
    let key_columns: Vec<&str> = match &table.primary_key {
        Some(key) => key.columns.iter().map(String::as_str).collect(),
        None => table
            .columns
            .iter()
            .filter(|column| column.info.primary_key)
            .map(ColumnDefinition::name)
            .collect(),
    };
    let referencing: Vec<String> = table
        .inbound_foreign_keys
        .iter()
        .filter(|key| {
            key.referenced_columns
                .iter()
                .any(|name| key_columns.contains(&name.as_str()))
        })
        .map(|key| key.name.clone())
        .collect();
    // The references come first: they hold the key on every engine, and
    // naming them tells the user what to change.
    Permission::unless(
        referencing.is_empty(),
        RefusalReason::ReferencedByForeignKeys(referencing),
    )
    .and(|| Permission::unless(capabilities.alter_primary_key, RefusalReason::EngineUnsupported))
}
