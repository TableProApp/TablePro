use tablepro_core::column::{ColumnType, SqlExpression};
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, InsertConflict, KeysetDirection, LiteralError, Placeholder, SqlDialect,
};
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{ExpressionSyntaxError, HistoryRecording, SqlGrammar, TypeSyntaxError};
use tablepro_core::value::Value;

/// Redis has no SQL. The connection still hands out a dialect, because
/// the editor reads its grammar and its history check from one, and
/// every SQL builder refuses: the app never pages, filters or saves rows
/// of a key-value engine through them.
#[derive(Debug, Default, Clone, Copy)]
pub struct RedisDialect;

impl SqlDialect for RedisDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            exact_row_counts: true,
            insert_conflict: InsertConflict::Refused,
        }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::Redis
    }

    /// A key's name as one argument of a command: as it is where redis-cli
    /// would read it back whole, in double quotes otherwise.
    fn quote_identifier(&self, name: &str) -> String {
        if SqlGrammar::Redis.is_bare_identifier(name) || name.starts_with('"') {
            return name.to_owned();
        }
        crate::key_name::quoted_argument(name.as_bytes())
    }

    fn placeholder(&self, _ordinal: usize, value: Value, _target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        Err(BindError::Unrepresentable {
            expected: "a Redis command argument",
            found: value.variant_name(),
        })
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        Err(LiteralError::Unrepresentable {
            found: value.variant_name(),
        })
    }

    /// `MATCH` takes a glob, whose wildcards and escape a backslash
    /// escapes.
    fn escape_like_text(&self, text: &str) -> String {
        tablepro_core::keyspace::glob_escape(text)
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

    /// Redis values have no column types to write.
    fn parse_type(&self, _text: &str) -> Result<ColumnType, TypeSyntaxError> {
        Err(TypeSyntaxError::Invalid)
    }

    fn parse_expression(&self, _text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        Err(ExpressionSyntaxError::Invalid)
    }

    fn history_recording(&self, sql: &str) -> HistoryRecording {
        tablepro_core::sql_syntax::redis::history_recording(sql)
    }

    fn insert_default_row(&self, _table_sql: &str) -> Option<String> {
        None
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::WithholdReason;

    use super::*;

    #[test]
    fn a_key_is_quoted_only_where_redis_cli_would_split_it() {
        let dialect = RedisDialect;

        assert_eq!(dialect.quote_identifier("user:1"), "user:1");
        assert_eq!(dialect.quote_identifier("a key"), r#""a key""#);
        assert_eq!(dialect.quote_identifier("it's"), r#""it's""#);
        assert_eq!(dialect.quote_identifier(r#""\xff""#), r#""\xff""#);
    }

    #[test]
    fn a_glob_escapes_its_wildcards() {
        assert_eq!(RedisDialect.escape_like_text(r"50%_*?[a]\"), r"50%_\*\?\[a\]\\");
    }

    #[test]
    fn nothing_is_bound_or_parsed_as_sql() {
        let dialect = RedisDialect;

        assert!(dialect.literal(&Value::Int(1), &ColumnType::unknown()).is_err());
        assert!(dialect.parse_type("integer").is_err());
        assert!(dialect.parse_expression("1 + 1").is_err());
        assert_eq!(dialect.grammar(), SqlGrammar::Redis);
    }

    #[test]
    fn the_history_withholds_a_password() {
        assert_eq!(
            RedisDialect.history_recording("AUTH s3cret"),
            HistoryRecording::Withhold(WithholdReason::CredentialStatement)
        );
        assert_eq!(RedisDialect.history_recording("GET k"), HistoryRecording::Record);
    }
}
