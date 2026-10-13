use super::{
    BuildDdlError, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlOperation, DdlPlan, DropTableOptions,
    ReferentialAction, TableChanges, TableDefinition, TableDraft,
};
use crate::dialect::SqlDialect;
use crate::meta::TableRef;

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

    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        ColumnCapabilities::standard(self.capabilities(), table, column)
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

    /// Statements that create the table as it is defined now: the
    /// server's own text where the engine keeps one, otherwise written
    /// from the definition.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        self.plan_create_table(&TableDraft::from_definition(definition))
    }
}
