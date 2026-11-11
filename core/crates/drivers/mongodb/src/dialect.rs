use tablepro_core::column::{ColumnInfo, ColumnType, SqlExpression};
use tablepro_core::dialect::{
    BindError, BindTarget, DatabaseLayout, DialectCapabilities, InsertBatchLimits, InsertConflict, KeysetDirection,
    LiteralError, Placeholder, SqlDialect,
};
use tablepro_core::filter::FilterOp;
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{ExpressionSyntaxError, HistoryRecording, SqlGrammar, TypeSyntaxError};
use tablepro_core::value::Value;

/// MongoDB speaks its shell language. A collection's page, count,
/// export and saves are written as shell calls by `tablepro_core::document`,
/// which the builders hand a collection to on seeing this grammar, so the
/// SQL fragments below (a row window, a keyset comparison, a row address,
/// a type) are never reached and write nothing. Names, placeholders and
/// literals are shell text, for a copy or an export to run again.
#[derive(Debug, Default, Clone, Copy)]
pub struct MongoDialect;

impl SqlDialect for MongoDialect {
    fn database_layout(&self) -> DatabaseLayout {
        DatabaseLayout::AsSchemas
    }

    /// A write reports how many documents it matched, and `_id` is
    /// unique, so a count proves a save touched the document it meant to,
    /// and an insert with an `_id` already taken fails with E11000.
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            exact_row_counts: true,
            insert_conflict: InsertConflict::Refused,
        }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::Mongo
    }

    /// A field or collection name as a shell string.
    fn quote_identifier(&self, name: &str) -> String {
        tablepro_core::sql_syntax::mongo::ShellValue::string(name).to_string()
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let column = match target {
            BindTarget::Column(column) => Some(column),
            BindTarget::Pattern | BindTarget::EngineRowId(_) => None,
        };
        let param = tablepro_core::document::bind_param(value, column, None)?;
        Ok(Placeholder::bound(format!("${}", ordinal + 1), param))
    }

    /// A value as shell text, for Copy As INSERT and an export of
    /// statements.
    fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
        tablepro_core::document::shell_literal(value, column)
    }

    fn escape_like_text(&self, text: &str) -> String {
        text.to_owned()
    }

    /// The operators `tablepro_core::document` builds a rule with, so the
    /// filter strip offers no rule the filter would refuse.
    fn filter_operators(&self, column: &ColumnInfo) -> &'static [FilterOp] {
        tablepro_core::document::filter_operators(column)
    }

    fn row_window(&self, _order_by: Option<&str>, _limit: u64, _offset: u64) -> String {
        String::new()
    }

    fn row_value_after(&self, _key_sql: &[String], _markers: &[String], _direction: KeysetDirection) -> String {
        String::new()
    }

    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    /// A field's type is each document's own, so no type is written.
    fn parse_type(&self, _text: &str) -> Result<ColumnType, TypeSyntaxError> {
        Err(TypeSyntaxError::Invalid)
    }

    fn parse_expression(&self, _text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        Err(ExpressionSyntaxError::Invalid)
    }

    fn history_recording(&self, sql: &str) -> HistoryRecording {
        tablepro_core::sql_syntax::mongo::history_recording(sql)
    }

    /// A document a step. An `insertMany` that fails partway keeps the
    /// documents before the failure, which one step's outcome cannot
    /// say, so an import names exactly the rows that did not land.
    fn insert_batch_limits(&self) -> InsertBatchLimits {
        InsertBatchLimits {
            rows: 1,
            ..InsertBatchLimits::DEFAULT
        }
    }

    fn insert_default_row(&self, _table_sql: &str) -> Option<String> {
        None
    }

    /// A page reads a missing field as NULL, so a NULL cell is a field the
    /// document leaves out, as `tablepro_core::document` inserts it.
    fn insert_names_null_cells(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ResultColumn;
    use tablepro_core::export::render_sql_insert;
    use tablepro_core::meta::TableRef;
    use tablepro_core::sql_syntax::WithholdReason;
    use tablepro_core::statement::ParamType;

    use super::*;

    #[test]
    fn an_import_writes_a_document_a_step() {
        assert_eq!(MongoDialect.insert_batch_limits().rows, 1);
    }

    #[test]
    fn an_exported_insert_leaves_a_null_field_out() {
        let columns = ["_id", "name", "email"].map(|name| ResultColumn::new(name, ColumnType::unknown()));
        let rows = [vec![Value::Int32(1), Value::Text("ann".to_owned()), Value::Null]];

        let sql = render_sql_insert(
            &MongoDialect,
            &TableRef::new(Some("shop".to_owned()), "users"),
            &columns,
            &[],
            &[],
            &rows,
        );

        assert_eq!(
            sql,
            "db.getSiblingDB(\"shop\").getCollection(\"users\").insertOne({\"_id\": 1, \"name\": \"ann\"});\n"
        );
    }

    #[test]
    fn a_field_of_ints_and_doubles_keeps_the_comparisons() {
        let price = crate::field_types::field_column("price", &["int", "double"].into_iter().collect());
        let qty = crate::field_types::field_column("qty", &["int"].into_iter().collect());

        let offered = MongoDialect.filter_operators(&price);
        for op in [
            FilterOp::Lt,
            FilterOp::GtEq,
            FilterOp::Between,
            FilterOp::Contains,
            FilterOp::IsNull,
        ] {
            assert!(offered.contains(&op), "{op:?} in {offered:?}");
        }
        assert_eq!(
            MongoDialect.filter_operators(&qty),
            tablepro_core::filter::operators_for(&qty.column_type.kind)
        );
    }

    #[test]
    fn a_name_is_a_shell_string_and_a_value_binds_by_its_ordinal() {
        let dialect = MongoDialect;

        assert_eq!(dialect.quote_identifier("order \"items\""), r#""order \"items\"""#);
        let placeholder = dialect
            .placeholder(2, Value::Int(7), BindTarget::Pattern)
            .expect("a parameter");
        assert_eq!(placeholder.sql, "$3");
        assert_eq!(
            placeholder.param.map(|param| param.param_type().clone()),
            Some(ParamType::Int64)
        );
    }

    #[test]
    fn nothing_is_written_as_sql() {
        let dialect = MongoDialect;

        assert_eq!(
            dialect.literal(&Value::Int32(1), &ColumnType::unknown()).as_deref(),
            Ok("1")
        );
        assert_eq!(
            dialect.literal(&Value::Int(1), &ColumnType::unknown()).as_deref(),
            Ok(r#"NumberLong("1")"#)
        );
        assert!(dialect.parse_type("int").is_err());
        assert!(dialect.parse_expression("1 + 1").is_err());
        assert_eq!(dialect.grammar(), SqlGrammar::Mongo);
    }

    #[test]
    fn the_history_withholds_a_password() {
        assert_eq!(
            MongoDialect.history_recording("db.createUser({user: 'a', pwd: 'b', roles: []})"),
            HistoryRecording::Withhold(WithholdReason::CredentialStatement)
        );
        assert_eq!(
            MongoDialect.history_recording("db.users.find()"),
            HistoryRecording::Record
        );
    }
}
