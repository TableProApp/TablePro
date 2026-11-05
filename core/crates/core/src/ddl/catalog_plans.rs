//! Emptying a table, and creating and dropping a schema or database, for
//! any engine: SQL through its `DdlDialect`, MongoDB through its shell.

use super::{
    BuildDdlError, CatalogCapabilities, CatalogOption, DatabaseDraft, DatabaseFields, DatabaseNoun, DdlOperation,
    DdlPlan, DropDatabaseOptions, DropSchemaOptions, SchemaDraft, TruncateTableOptions,
};
use crate::dialect::SqlDialect;
use crate::document;
use crate::meta::TableRef;
use crate::write_batch::WriteKind;

/// What the engine behind `dialect` does to whole tables, schemas and
/// databases.
pub fn catalog_capabilities(dialect: &dyn SqlDialect) -> CatalogCapabilities {
    if document::speaks_shell(dialect) {
        return CatalogCapabilities {
            truncate_table: true,
            create_database: true,
            drop_database: true,
            database_fields: DatabaseFields {
                first_collection: true,
                ..DatabaseFields::default()
            },
            database_noun: DatabaseNoun::Database,
            ..CatalogCapabilities::default()
        };
    }
    dialect
        .ddl()
        .map(|ddl| ddl.catalog_capabilities())
        .unwrap_or_default()
}

/// Whether the engine keeps the database `name` for itself.
pub fn protects_database(dialect: &dyn SqlDialect, name: &str) -> bool {
    if document::speaks_shell(dialect) {
        return MONGODB_DATABASES.contains(&name);
    }
    dialect.ddl().is_some_and(|ddl| ddl.protects_database(name))
}

/// Whether the engine keeps the schema `name` for itself.
pub fn protects_schema(dialect: &dyn SqlDialect, name: &str) -> bool {
    dialect.ddl().is_some_and(|ddl| ddl.protects_schema(name))
}

/// The databases a MongoDB server keeps for itself.
const MONGODB_DATABASES: [&str; 3] = ["admin", "config", "local"];

pub fn plan_truncate_table(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    options: &TruncateTableOptions,
) -> Result<DdlPlan, BuildDdlError> {
    if document::speaks_shell(dialect) {
        refuse_options(&catalog_capabilities(dialect), options)?;
        return Ok(DdlPlan::from_statements(vec![document::delete_all_documents(table)]));
    }
    ddl(dialect, DdlOperation::TruncateTable)?.plan_truncate_table(table, options)
}

pub fn plan_create_schema(dialect: &dyn SqlDialect, draft: &SchemaDraft) -> Result<DdlPlan, BuildDdlError> {
    ddl(dialect, DdlOperation::CreateSchema)?.plan_create_schema(draft)
}

pub fn plan_drop_schema(
    dialect: &dyn SqlDialect,
    schema: &str,
    options: DropSchemaOptions,
) -> Result<DdlPlan, BuildDdlError> {
    ddl(dialect, DdlOperation::DropSchema)?.plan_drop_schema(schema, options)
}

pub fn plan_create_database(dialect: &dyn SqlDialect, draft: &DatabaseDraft) -> Result<DdlPlan, BuildDdlError> {
    if document::speaks_shell(dialect) {
        check_database_draft(&catalog_capabilities(dialect), draft)?;
        let name = catalog_name(CatalogOption::Name, &draft.name)?;
        let collection = catalog_name(
            CatalogOption::Collection,
            draft.first_collection.as_deref().unwrap_or_default(),
        )?;
        return Ok(database_statement(document::create_database(name, collection)));
    }
    ddl(dialect, DdlOperation::CreateDatabase)?.plan_create_database(draft)
}

pub fn plan_drop_database(
    dialect: &dyn SqlDialect,
    database: &str,
    options: &DropDatabaseOptions,
) -> Result<DdlPlan, BuildDdlError> {
    if document::speaks_shell(dialect) {
        refuse_drop_options(&catalog_capabilities(dialect), options)?;
        let name = catalog_name(CatalogOption::Name, database)?;
        return Ok(database_statement(document::drop_database(name)));
    }
    ddl(dialect, DdlOperation::DropDatabase)?.plan_drop_database(database, options)
}

fn database_statement(statement: crate::statement::Statement) -> DdlPlan {
    DdlPlan {
        kind: WriteKind::DatabaseChanges,
        ..DdlPlan::from_statements(vec![statement])
    }
}

fn ddl(dialect: &dyn SqlDialect, operation: DdlOperation) -> Result<&dyn super::DdlDialect, BuildDdlError> {
    dialect.ddl().ok_or(BuildDdlError::Unsupported(operation))
}

/// A schema, database or collection name: anything the quoting can
/// carry, but not nothing.
pub fn catalog_name(option: CatalogOption, name: &str) -> Result<&str, BuildDdlError> {
    match name.trim().is_empty() || name.contains('\0') {
        true => Err(BuildDdlError::InvalidOption {
            option,
            value: name.to_owned(),
        }),
        false => Ok(name),
    }
}

/// A schema or database name, refused when empty or longer than the
/// server keeps.
pub fn named<'a>(
    capabilities: &CatalogCapabilities,
    option: CatalogOption,
    name: &'a str,
) -> Result<&'a str, BuildDdlError> {
    let name = catalog_name(option, name)?;
    match capabilities.name_limit.is_none_or(|limit| limit.admits(name)) {
        true => Ok(name),
        false => Err(BuildDdlError::InvalidOption {
            option,
            value: name.to_owned(),
        }),
    }
}

/// A value an engine takes only bare, such as a MySQL character set or
/// a SQL Server collation: letters, digits and underscores, so nothing
/// else can reach the statement.
pub fn bare_word(option: CatalogOption, value: &str) -> Result<&str, BuildDdlError> {
    let bare = !value.is_empty() && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    match bare {
        true => Ok(value),
        false => Err(BuildDdlError::InvalidOption {
            option,
            value: value.to_owned(),
        }),
    }
}

/// Refuse a truncate option the engine does not take, before any SQL.
pub fn refuse_options(capabilities: &CatalogCapabilities, options: &TruncateTableOptions) -> Result<(), BuildDdlError> {
    let refused = [
        (!capabilities.truncate_table, DdlOperation::TruncateTable),
        (
            options.cascade && !capabilities.truncate_cascade,
            DdlOperation::TruncateTableCascade,
        ),
        (
            options.restart_identity && !capabilities.truncate_restart_identity,
            DdlOperation::TruncateRestartIdentity,
        ),
        (
            options.cluster.is_some() && !capabilities.on_cluster,
            DdlOperation::OnCluster,
        ),
    ];
    refuse_first(&refused)
}

/// Refuse a drop option the engine does not take, before any SQL.
pub fn refuse_drop_options(
    capabilities: &CatalogCapabilities,
    options: &DropDatabaseOptions,
) -> Result<(), BuildDdlError> {
    let refused = [
        (!capabilities.drop_database, DdlOperation::DropDatabase),
        (
            options.force && !capabilities.drop_database_force,
            DdlOperation::DropDatabaseForce,
        ),
        (
            options.cluster.is_some() && !capabilities.on_cluster,
            DdlOperation::OnCluster,
        ),
    ];
    refuse_first(&refused)
}

/// Refuse a new database whose options the engine has no place for, so
/// a caller that skips the dialog gets an error rather than a statement
/// that leaves an option out.
pub fn check_database_draft(capabilities: &CatalogCapabilities, draft: &DatabaseDraft) -> Result<(), BuildDdlError> {
    let fields = capabilities.database_fields;
    let refused = [
        (!capabilities.create_database, DdlOperation::CreateDatabase),
        (draft.owner.is_some() && !fields.owner, DdlOperation::CatalogOwner),
        (draft.cluster.is_some() && !capabilities.on_cluster, DdlOperation::OnCluster),
    ];
    refuse_first(&refused)?;
    let unplaced = [
        (draft.template.is_some() && !fields.template, CatalogOption::Template),
        (draft.encoding.is_some() && !fields.encoding, CatalogOption::Encoding),
        (draft.locale.is_some() && !fields.locale, CatalogOption::Locale),
        (
            draft.character_set.is_some() && !fields.character_set,
            CatalogOption::CharacterSet,
        ),
        (draft.collation.is_some() && !fields.collation, CatalogOption::Collation),
        (
            draft.replication.is_some() && !fields.replication,
            CatalogOption::ReplicationFactor,
        ),
        (draft.tablets.is_some() && !fields.tablets, CatalogOption::ReplicationFactor),
        (
            draft.first_collection.is_some() && !fields.first_collection,
            CatalogOption::Collection,
        ),
    ];
    match unplaced.iter().find(|(set, _)| *set) {
        Some((_, option)) => Err(BuildDdlError::InvalidOption {
            option: *option,
            value: String::new(),
        }),
        None => Ok(()),
    }
}

fn refuse_first(refused: &[(bool, DdlOperation)]) -> Result<(), BuildDdlError> {
    match refused.iter().find(|(refuses, _)| *refuses) {
        Some((_, operation)) => Err(BuildDdlError::Unsupported(*operation)),
        None => Ok(()),
    }
}
