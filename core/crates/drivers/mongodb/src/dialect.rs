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

    /// A saved document's field given back to the server is removed with
    /// `$unset`, as a new document leaves it out.
    fn update_sets_default(&self) -> bool {
        true
    }

    fn reads_missing_as_null(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ResultColumn;
    use tablepro_core::dml::build_update;
    use tablepro_core::edit::CellInput;
    use tablepro_core::export::render_sql_insert;
    use tablepro_core::meta::{RowIdentity, TableRef};
    use tablepro_core::sql_syntax::WithholdReason;
    use tablepro_core::sql_syntax::mongo::{ShellStatement, parse_statement, parse_value};
    use tablepro_core::statement::ParamType;
    use tablepro_core::value::JsonText;

    use super::*;
    use crate::extended_json::extended_json;
    use crate::to_bson::to_bson;

    #[test]
    fn an_import_writes_a_document_a_step() {
        assert_eq!(MongoDialect.insert_batch_limits().rows, 1);
    }

    #[test]
    fn an_exported_insert_writes_a_null_field_as_null() {
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
            "db.getSiblingDB(\"shop\").getCollection(\"users\").insertOne({\"_id\": 1, \"name\": \"ann\", \"email\": null});\n"
        );
    }

    #[test]
    fn an_exported_json_cell_runs_back_as_the_bson_it_names() {
        let cells = [
            r#"{"$numberLong": "7"}"#,
            r#"{"$numberInt": "7"}"#,
            r#"{"$numberDecimal": "9.990"}"#,
            r#"{"$numberDouble": "NaN"}"#,
            r#"{"$numberDouble": "-Infinity"}"#,
            r#"{"$date": "2024-01-02T03:04:05.006Z"}"#,
            r#"{"$date": {"$numberLong": "-315619200000"}}"#,
            r#"{"$date": {"$numberLong": "253402300800000"}}"#,
            r#"{"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}"#,
            r#"{"$binary": {"base64": "VQ6EAOKbQdSnFkRmVUQAAA==", "subType": "04"}}"#,
            r#"{"$binary": {"base64": "aGkh", "subType": "00"}}"#,
            r#"{"$binary": {"base64": "aGkh", "subType": "80"}}"#,
            r#"{"$timestamp": {"t": 1700000000, "i": 3}}"#,
            r#"{"$regularExpression": {"pattern": "^a\\.b", "options": "im"}}"#,
            r#"{"$regularExpression": {"pattern": "a/b", "options": "s"}}"#,
            r#"{"$regularExpression": {"pattern": "(?i)a\\Z", "options": "lsx"}}"#,
            "2.0",
            "-0.0",
            "-2147483648.0",
            "2147483648.0",
            "0.5",
            r#"{"$numberDouble": "1e300"}"#,
            r#"{"$minKey": 1}"#,
            r#"{"$maxKey": 1}"#,
            r#"{"a": [{"$numberLong": "1"}, {"b": {"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}}], "c": 1.5}"#,
            r#"{"whole": 2.0, "zero": -0.0, "n": 2}"#,
        ];
        let column = crate::field_types::field_column("v", &["long", "string"].into_iter().collect());
        let columns = [ResultColumn::new("v", column.column_type)];
        let rows: Vec<Vec<Value>> = cells
            .iter()
            .map(|cell| vec![Value::Json(JsonText::parse((*cell).to_owned()).expect("JSON"))])
            .collect();

        let script = render_sql_insert(&MongoDialect, &TableRef::unqualified("t"), &columns, &[], &[], &rows);

        assert_eq!(script.lines().count(), cells.len());
        for (line, cell) in script.lines().zip(cells) {
            let Ok(ShellStatement::Call(call)) = parse_statement(line.trim_end_matches(';')) else {
                panic!("{line} does not parse");
            };
            let written = call
                .operation()
                .and_then(|insert| insert.arg(0))
                .and_then(|document| document.field("v"))
                .expect("the field");
            let named = parse_value(cell).expect("the cell");

            assert_eq!(
                to_bson(written, &[]).map(|bson| extended_json(&bson)),
                to_bson(&named, &[]).map(|bson| extended_json(&bson)),
                "{line}"
            );
            assert!(!written.keys().iter().any(|key| key.starts_with('$')), "{line}");
        }
    }

    #[test]
    fn a_whole_double_runs_back_as_a_double() {
        let column = crate::field_types::field_column("price", &["double"].into_iter().collect());
        let columns = [ResultColumn::new("price", column.column_type)];
        let rows = [2.0, -0.0, 2.5].map(|number| vec![Value::Float64(number)]);

        let script = render_sql_insert(&MongoDialect, &TableRef::unqualified("t"), &columns, &[], &[], &rows);

        assert!(
            script.contains("Double(2)") && script.contains("Double(-0)"),
            "{script}"
        );
        let read: Vec<String> = script
            .lines()
            .map(|line| {
                let Ok(ShellStatement::Call(call)) = parse_statement(line.trim_end_matches(';')) else {
                    panic!("{line} does not parse");
                };
                let written = call
                    .operation()
                    .and_then(|insert| insert.arg(0))
                    .and_then(|document| document.field("price"))
                    .expect("the field");
                to_bson(written, &[]).map(|bson| extended_json(&bson)).expect("BSON")
            })
            .collect();
        assert_eq!(read, ["2.0", "-0.0", "2.5"]);
    }

    #[test]
    fn a_saved_field_given_back_to_the_server_is_unset() {
        let columns = [
            crate::field_types::field_column("_id", &["int"].into_iter().collect()),
            crate::field_types::field_column("email", &["string"].into_iter().collect()),
        ];
        let identity = RowIdentity::UniqueKey {
            columns: vec!["_id".to_owned()],
        };
        let update = |cell: CellInput| {
            build_update(
                &MongoDialect,
                &TableRef::new(Some("shop".to_owned()), "users"),
                &columns,
                &identity,
                &[Value::Int(1)],
                &[(1, cell)],
                &[],
            )
            .expect("an update")
        };

        assert!(MongoDialect.update_sets_default());
        assert_eq!(
            update(CellInput::Default).sql(),
            r#"db.getSiblingDB("shop").getCollection("users").updateOne({"_id": $1}, {"$unset": {"email": ""}})"#
        );
        assert_eq!(
            update(CellInput::Value(Value::Null)).sql(),
            r#"db.getSiblingDB("shop").getCollection("users").updateOne({"_id": $2}, {"$set": {"email": $1}})"#
        );
    }

    #[test]
    fn a_field_of_ints_and_doubles_keeps_the_comparisons_and_no_pattern() {
        let price = crate::field_types::field_column("price", &["int", "double"].into_iter().collect());
        let qty = crate::field_types::field_column("qty", &["int"].into_iter().collect());
        let mixed = crate::field_types::field_column("code", &["int", "string"].into_iter().collect());

        let offered = MongoDialect.filter_operators(&price);
        for op in [FilterOp::Lt, FilterOp::GtEq, FilterOp::Between, FilterOp::IsNull] {
            assert!(offered.contains(&op), "{op:?} in {offered:?}");
        }
        assert!(!offered.contains(&FilterOp::Contains), "{offered:?}");
        assert!(MongoDialect.filter_operators(&mixed).contains(&FilterOp::Contains));
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
