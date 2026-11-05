use super::catalog_plans::{catalog_name, check_database_draft, named, refuse_drop_options, refuse_options};
use super::{
    BuildDdlError, CatalogCapabilities, CatalogOption, ColumnCapabilities, ColumnDefinition, DatabaseDraft,
    DdlCapabilities, DdlOperation, DdlPlan, DropDatabaseOptions, DropSchemaOptions, DropTableOptions, Permission,
    ReferentialAction, SchemaDraft, TableChanges, TableDefinition, TableDraft, TruncateTableOptions,
};
use crate::dialect::SqlDialect;
use crate::meta::{IndexInfo, TableRef};

/// How one engine plans structure changes.
///
/// Reached through `SqlDialect::ddl`, which is `None` for an engine
/// whose structure the app does not edit. A plan is built against the
/// table's definition as one read returned it, so a statement that
/// restates a column, renames a key or drops a default by name has
/// everything it needs from the same moment.
///
/// Every plan refuses what `capabilities` and `column_capabilities`
/// refuse, with the same reasons the structure tab shows.
pub trait DdlDialect: Send + Sync + std::fmt::Debug {
    fn capabilities(&self) -> &DdlCapabilities;

    /// The dialect that quotes, binds and parses for this engine.
    fn sql_dialect(&self) -> &dyn SqlDialect;

    /// What the engine takes for this table, where that depends on more
    /// than the engine: the structure tab offers a table-wide control,
    /// such as adding a foreign key, only where this allows it.
    fn table_capabilities(&self, _table: &TableDefinition) -> DdlCapabilities {
        *self.capabilities()
    }

    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        ColumnCapabilities::standard(self.capabilities(), table, column)
    }

    /// Whether one of the table's indexes can be dropped, where the
    /// table's `drop_index` allows it: an index a constraint owns may
    /// not be.
    fn index_removal(&self, _table: &TableDefinition, _index: &IndexInfo) -> Permission {
        Permission::Allowed
    }

    /// Types offered in the structure tab, most common first. Each one
    /// parses through `SqlDialect::parse_type`, and any other type can
    /// still be typed.
    fn type_suggestions(&self) -> &'static [&'static str];

    /// The type a column added in the structure tab starts with.
    fn default_column_type(&self) -> &'static str;

    /// The actions a foreign key may take, in the order the UI offers
    /// them. The first is the SQL default.
    fn referential_actions(&self) -> &'static [ReferentialAction] {
        &ReferentialAction::ALL
    }

    /// Whether a foreign key can reference a table in another schema.
    /// Where it cannot, a key is offered only the tables of its own.
    fn references_other_schemas(&self) -> bool {
        true
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError>;

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError>;

    fn plan_drop_table(&self, table: &TableRef, options: DropTableOptions) -> Result<DdlPlan, BuildDdlError> {
        if options.cascade && !self.capabilities().drop_table_cascade {
            return Err(BuildDdlError::Unsupported(DdlOperation::DropTableCascade));
        }
        let if_exists = if options.if_exists { "IF EXISTS " } else { "" };
        let cascade = if options.cascade { " CASCADE" } else { "" };
        Ok(DdlPlan::from_sql([format!(
            "DROP TABLE {if_exists}{}{cascade}",
            self.sql_dialect().qualify(table)
        )]))
    }

    /// What the engine does to whole tables, schemas and databases. The
    /// plans below refuse what this leaves out.
    fn catalog_capabilities(&self) -> CatalogCapabilities {
        CatalogCapabilities::default()
    }

    /// Whether the engine keeps this database for itself, so it is never
    /// offered for a drop: the server's own, and any it refuses to drop.
    fn protects_database(&self, _name: &str) -> bool {
        false
    }

    /// Whether the engine keeps this schema for itself, as SQL Server
    /// keeps `dbo` and DuckDB `main`.
    fn protects_schema(&self, _name: &str) -> bool {
        false
    }

    /// Empty the table and keep its definition.
    fn plan_truncate_table(&self, table: &TableRef, options: &TruncateTableOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_options(&self.catalog_capabilities(), options)?;
        let restart = if options.restart_identity { " RESTART IDENTITY" } else { "" };
        let cascade = if options.cascade { " CASCADE" } else { "" };
        Ok(DdlPlan::from_sql([format!(
            "TRUNCATE TABLE {}{restart}{cascade}",
            self.sql_dialect().qualify(table)
        )]))
    }

    fn plan_create_schema(&self, draft: &SchemaDraft) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        if !capabilities.create_schema {
            return Err(BuildDdlError::Unsupported(DdlOperation::CreateSchema));
        }
        if draft.owner.is_some() && !capabilities.schema_owner {
            return Err(BuildDdlError::Unsupported(DdlOperation::CatalogOwner));
        }
        let dialect = self.sql_dialect();
        let mut sql = format!(
            "CREATE SCHEMA {}",
            dialect.quote_identifier(named(&capabilities, CatalogOption::Name, &draft.name)?)
        );
        if let Some(owner) = &draft.owner {
            sql.push_str(" AUTHORIZATION ");
            sql.push_str(&dialect.quote_identifier(catalog_name(CatalogOption::Owner, owner)?));
        }
        Ok(DdlPlan::from_sql([sql]))
    }

    fn plan_drop_schema(&self, schema: &str, options: DropSchemaOptions) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        if !capabilities.drop_schema {
            return Err(BuildDdlError::Unsupported(DdlOperation::DropSchema));
        }
        if options.cascade && !capabilities.drop_schema_cascade {
            return Err(BuildDdlError::Unsupported(DdlOperation::DropSchemaCascade));
        }
        let cascade = if options.cascade { " CASCADE" } else { "" };
        Ok(DdlPlan::from_sql([format!(
            "DROP SCHEMA {}{cascade}",
            self.sql_dialect()
                .quote_identifier(catalog_name(CatalogOption::Name, schema)?)
        )]))
    }

    /// A new database with only its name. An engine that offers options
    /// writes them in its own override.
    fn plan_create_database(&self, draft: &DatabaseDraft) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        check_database_draft(&capabilities, draft)?;
        Ok(DdlPlan::for_databases([format!(
            "CREATE DATABASE {}",
            self.sql_dialect()
                .quote_identifier(named(&capabilities, CatalogOption::Name, &draft.name)?)
        )]))
    }

    fn plan_drop_database(&self, database: &str, options: &DropDatabaseOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_drop_options(&self.catalog_capabilities(), options)?;
        Ok(DdlPlan::for_databases([format!(
            "DROP DATABASE {}",
            self.sql_dialect()
                .quote_identifier(catalog_name(CatalogOption::Name, database)?)
        )]))
    }

    /// Statements that create the table as it is defined now: the
    /// server's own text where the engine keeps one, otherwise written
    /// from the definition.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        let mut draft = TableDraft::from_definition(definition);
        // Keys alone lose an index's method, operator classes and storage.
        let (stated, written): (Vec<IndexInfo>, Vec<IndexInfo>) =
            draft.indexes.into_iter().partition(|index| index.definition.is_some());
        draft.indexes = written;
        let mut plan = self.plan_create_table(&draft)?;
        let stated = DdlPlan::from_sql(stated.into_iter().filter_map(|index| index.definition));
        plan.statements.extend(stated.statements);
        Ok(plan)
    }
}
