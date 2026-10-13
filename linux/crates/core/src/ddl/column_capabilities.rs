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
    pub alter_comment: Permission,
}

impl ColumnCapabilities {
    /// What every engine refuses on top of its own capabilities: a
    /// restatement that would drop a generated expression or an
    /// attribute this build cannot restate, a default on a numbered
    /// column, and anything foreign keys elsewhere depend on.
    ///
    /// A comment is set apart from the definition on most engines, so
    /// only an engine that restates the column for it refuses it here.
    pub fn standard(capabilities: &DdlCapabilities, table: &TableDefinition, column: &ColumnDefinition) -> Self {
        let engine = |allowed: bool| Permission::unless(allowed, RefusalReason::EngineUnsupported);
        let restatement = || Self::restatement(column);
        let not_numbered = || {
            Permission::unless(
                column.attributes.identity == IdentityStyle::None && !column.info.is_auto_increment,
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
            alter_type: engine(capabilities.alter_column_type).and(restatement),
            alter_nullability: engine(capabilities.alter_column_nullability).and(restatement),
            alter_default: engine(capabilities.alter_column_default)
                .and(|| not_generated(column))
                .and(not_numbered)
                .and(|| modeled(column)),
            alter_primary_key: primary_key_permission(capabilities, table),
            alter_auto_increment: engine(capabilities.alter_auto_increment).and(restatement),
            alter_comment: engine(capabilities.column_comments),
        }
    }

    /// Whether the column can be written out again whole: a generated
    /// one would lose its expression, and one with an attribute this
    /// build does not model would lose that.
    pub fn restatement(column: &ColumnDefinition) -> Permission {
        not_generated(column).and(|| modeled(column))
    }
}

fn not_generated(column: &ColumnDefinition) -> Permission {
    Permission::unless(
        !column.info.is_generated && column.attributes.generated.is_none(),
        RefusalReason::GeneratedColumn,
    )
}

fn modeled(column: &ColumnDefinition) -> Permission {
    match column.attributes.unmodeled.first() {
        Some(attribute) => Permission::Refused(RefusalReason::UnmodeledAttribute(attribute.name.clone())),
        None => Permission::Allowed,
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
