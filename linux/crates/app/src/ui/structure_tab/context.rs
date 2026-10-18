//! What the Structure tab knows about the table it edits: whether it
//! exists, the definition the last read returned, and the dialect whose
//! DDL rules decide which changes each row offers.

use std::sync::Arc;

use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::ddl::{
    ColumnCapabilities, DdlCapabilities, DdlDialect, DraftColumn, Permission, RefusalReason, TableDefinition,
    default_text, parse_default, primary_key_permission,
};
use tablepro_core::dialect::SqlDialect;

use super::StructureMode;

/// The lists build their rows from this while the tab changes their
/// stores, so it lives apart from the model the tab is changing.
pub(super) struct StructureContext {
    pub mode: StructureMode,
    /// The connection's dialect, which plans the DDL. `None` until the
    /// first read, and the SQL cannot be written before then.
    pub dialect: Option<Arc<dyn SqlDialect>>,
    /// The table as the last read returned it, which Save plans against
    /// and Discard restores. `None` for a new table.
    pub definition: Option<TableDefinition>,
}

impl StructureContext {
    pub(super) fn ddl(&self) -> Option<&dyn DdlDialect> {
        self.dialect.as_deref().and_then(|dialect| dialect.ddl())
    }

    /// The definition Save diffs the draft against: none for a new table.
    pub(super) fn original(&self) -> Option<&TableDefinition> {
        match self.mode {
            StructureMode::New => None,
            StructureMode::Edit => self.definition.as_ref(),
        }
    }

    pub(super) fn capabilities(&self) -> DdlCapabilities {
        let Some(ddl) = self.ddl() else {
            return DdlCapabilities::default();
        };
        match self.original() {
            Some(definition) => ddl.table_capabilities(definition),
            None => *ddl.capabilities(),
        }
    }

    pub(super) fn type_suggestions(&self) -> &'static [&'static str] {
        self.ddl().map(|ddl| ddl.type_suggestions()).unwrap_or_default()
    }

    /// Which changes the row of `column` offers. A column the user added
    /// in this tab is only a draft, so everything about it can change,
    /// apart from joining the primary key of a table whose key is held.
    pub(super) fn column_permissions(&self, column: &DraftColumn) -> ColumnCapabilities {
        let capabilities = self.capabilities();
        let (Some(ddl), Some(definition), Some(original)) = (self.ddl(), self.original(), column.original.as_ref())
        else {
            let primary_key = match self.original() {
                Some(definition) => primary_key_permission(&capabilities, definition),
                None => Permission::Allowed,
            };
            return ColumnCapabilities {
                rename: Permission::Allowed,
                drop: Permission::Allowed,
                alter_type: Permission::Allowed,
                alter_nullability: Permission::Allowed,
                alter_default: Permission::Allowed,
                alter_primary_key: primary_key,
                alter_auto_increment: Permission::Allowed,
                alter_comment: Permission::unless(capabilities.column_comments, RefusalReason::EngineUnsupported),
            };
        };
        ddl.column_capabilities(definition, original)
    }

    /// A draft's indexes and foreign keys are only entries in it, so the
    /// engine's limits apply to a table that exists.
    pub(super) fn table_permission(&self, allowed: bool) -> Permission {
        match self.mode {
            StructureMode::New => Permission::Allowed,
            StructureMode::Edit => Permission::unless(allowed, RefusalReason::EngineUnsupported),
        }
    }

    pub(super) fn can_add_column(&self) -> bool {
        match self.mode {
            StructureMode::New => true,
            StructureMode::Edit => self.capabilities().add_column,
        }
    }

    pub(super) fn can_add_index(&self) -> bool {
        self.capabilities().create_index
    }

    /// A new table declares its keys inside CREATE TABLE, which every
    /// engine that creates tables takes.
    pub(super) fn can_add_foreign_key(&self) -> bool {
        let capabilities = self.capabilities();
        let allowed = match self.mode {
            StructureMode::New => capabilities.create_table,
            StructureMode::Edit => capabilities.add_foreign_key,
        };
        allowed && self.ddl().is_some()
    }

    /// The type a default's literal is read against: the column's own, or
    /// the one the user typed once it parses.
    fn default_column_type(&self, column: &DraftColumn) -> Option<ColumnType> {
        let dialect = self.dialect.as_deref()?;
        column.column_type.column_type(dialect, &column.name).ok()
    }

    /// The default as SQL the user could type back in.
    pub(super) fn default_text(&self, column: &DraftColumn) -> String {
        match (self.dialect.as_deref(), self.default_column_type(column)) {
            (Some(dialect), Some(column_type)) => default_text(dialect, &column.default, &column_type),
            _ => match &column.default {
                ColumnDefault::None => String::new(),
                ColumnDefault::Literal(value) => tablepro_core::export::value_to_text(value).unwrap_or_default(),
                ColumnDefault::Expression(expression) => expression.as_sql().to_owned(),
            },
        }
    }

    /// The default the user typed, as the engine's parser reads it. The
    /// text the row showed for the loaded default gives that default
    /// back, so seeing it again is no edit.
    pub(super) fn parse_default(&self, column: &DraftColumn, text: &str) -> Result<ColumnDefault, String> {
        if let Some(original) = column.original.as_ref().filter(|original| {
            let loaded = DraftColumn::from_definition((*original).clone());
            self.default_text(&loaded) == text
        }) {
            return Ok(original.info.default.clone());
        }
        let Some(dialect) = self.dialect.as_deref() else {
            return Err(crate::i18n::gettext("Connect to a database to check the default."));
        };
        let column_type = self
            .default_column_type(column)
            .unwrap_or_else(|| ColumnType::untyped_text(column.column_type.text()));
        parse_default(dialect, text, &column_type).map_err(|error| error.to_string())
    }
}
