use std::sync::Mutex;

use crate::column::{ColumnInfo, ColumnType, SqlExpression, SqlTypeExpr};
use crate::meta::{EngineRowId, EngineRowIdPart};
use crate::sql_syntax::{ExpressionSyntaxError, SqlGrammar, TypeSyntaxError, parse_expression, parse_type};
use crate::statement::{BoundParam, ParamType};
use crate::value::Value;

use super::{BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, SqlDialect};

/// The one ANSI dialect the core builders' own tests share.
///
/// It records every bind it is asked for, so a test can check which
/// target each value was bound for and in what order, and it can switch
/// marker style to prove a builder keeps positional markers in bind
/// order.
#[derive(Debug)]
pub struct TestDialect {
    exact_row_counts: bool,
    markers: TestMarkers,
    row_ids: bool,
    default_row: bool,
    count_all: &'static str,
    grammar: SqlGrammar,
    binds: Mutex<Vec<RecordedBind>>,
}

/// How the test dialect spells a marker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TestMarkers {
    /// `$1`, `$2`: the style whose ordinals can disagree with the list.
    #[default]
    Numbered,
    /// `?`, where only the position in the text names the parameter.
    Positional,
    /// `{p0:Type}`, a server-side parameter named by its index.
    ServerNamed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecordedTarget {
    Column(String),
    Pattern,
    EngineRowId(EngineRowIdPart),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RecordedBind {
    ordinal: usize,
    target: RecordedTarget,
}

impl Default for TestDialect {
    fn default() -> Self {
        Self {
            exact_row_counts: false,
            markers: TestMarkers::Numbered,
            row_ids: true,
            default_row: true,
            count_all: "COUNT(*)",
            grammar: SqlGrammar::PostgreSql,
            binds: Mutex::new(Vec::new()),
        }
    }
}

impl TestDialect {
    pub fn exact() -> Self {
        Self {
            exact_row_counts: true,
            ..Self::default()
        }
    }

    pub fn estimated() -> Self {
        Self::default()
    }

    pub fn with_markers(self, markers: TestMarkers) -> Self {
        Self { markers, ..self }
    }

    pub fn without_row_ids(self) -> Self {
        Self { row_ids: false, ..self }
    }

    pub fn without_default_row(self) -> Self {
        Self {
            default_row: false,
            ..self
        }
    }

    pub fn counting_with(self, count_all: &'static str) -> Self {
        Self { count_all, ..self }
    }

    pub fn parsing_as(self, grammar: SqlGrammar) -> Self {
        Self { grammar, ..self }
    }

    pub fn targets(&self) -> Vec<RecordedTarget> {
        self.recorded().into_iter().map(|bind| bind.target).collect()
    }

    pub fn ordinals(&self) -> Vec<usize> {
        self.recorded().into_iter().map(|bind| bind.ordinal).collect()
    }

    fn recorded(&self) -> Vec<RecordedBind> {
        self.binds.lock().map(|binds| binds.clone()).unwrap_or_default()
    }

    fn record(&self, ordinal: usize, target: RecordedTarget) {
        if let Ok(mut binds) = self.binds.lock() {
            binds.push(RecordedBind { ordinal, target });
        }
    }

    fn marker(&self, ordinal: usize, declaration: &str) -> String {
        match self.markers {
            TestMarkers::Numbered => format!("${}", ordinal + 1),
            TestMarkers::Positional => "?".to_owned(),
            TestMarkers::ServerNamed => format!("{{p{ordinal}:{declaration}}}"),
        }
    }
}

impl SqlDialect for TestDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            exact_row_counts: self.exact_row_counts,
        }
    }

    fn grammar(&self) -> SqlGrammar {
        self.grammar
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let (param_type, declaration, recorded) = match target {
            BindTarget::Pattern => (ParamType::Text, "String".to_owned(), RecordedTarget::Pattern),
            BindTarget::EngineRowId(part) => (
                row_id_param_type(part),
                row_id_type(part).to_owned(),
                RecordedTarget::EngineRowId(part),
            ),
            BindTarget::Column(column) => (
                param_type_for(column),
                column
                    .column_type
                    .catalog
                    .as_ref()
                    .map(|catalog| catalog.declaration.as_sql().to_owned())
                    .unwrap_or_else(|| column.column_type.name.clone()),
                RecordedTarget::Column(column.name.clone()),
            ),
        };
        let param = BoundParam::new(value, param_type)?;
        self.record(ordinal, recorded);
        Ok(Placeholder::bound(self.marker(ordinal, &declaration), param))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            Value::Bool(flag) => Ok(flag.to_string()),
            Value::Int(number) => Ok(number.to_string()),
            Value::UInt(number) => Ok(number.to_string()),
            Value::Text(text) => Ok(format!("'{}'", text.replace('\'', "''"))),
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            other => Err(LiteralError::Unrepresentable {
                found: other.variant_name(),
            }),
        }
    }

    fn escape_like_text(&self, text: &str) -> String {
        text.replace('!', "!!").replace('%', "!%").replace('_', "!_")
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        let order = order_by.map(|order| format!(" ORDER BY {order}")).unwrap_or_default();
        match offset {
            0 => format!("{order} LIMIT {limit}"),
            _ => format!("{order} LIMIT {limit} OFFSET {offset}"),
        }
    }

    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        format!(
            "({}) {} ({})",
            key_sql.join(", "),
            direction.comparison(),
            markers.join(", ")
        )
    }

    fn engine_row_id(&self, id: EngineRowId) -> Option<String> {
        let projections: Option<Vec<String>> = id
            .parts()
            .iter()
            .map(|part| {
                let column = self.engine_row_id_column(*part)?;
                Some(format!(
                    "{column} AS {}",
                    self.quote_identifier(part.projection_alias())
                ))
            })
            .collect();
        projections.map(|projections| projections.join(", "))
    }

    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
        if !self.row_ids {
            return None;
        }
        Some(
            match part {
                EngineRowIdPart::PostgresTableOid => "tableoid",
                EngineRowIdPart::PostgresCtid => "ctid",
                EngineRowIdPart::PostgresXmin => "xmin",
                EngineRowIdPart::SqliteRowid => "rowid",
            }
            .to_owned(),
        )
    }

    fn count_all(&self) -> &'static str {
        self.count_all
    }

    fn insert_default_row(&self, table_sql: &str) -> Option<String> {
        self.default_row
            .then(|| format!("INSERT INTO {table_sql} DEFAULT VALUES"))
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(self.grammar, text, crate::sql_syntax::MAX_TYPE_LEN)?;
        Ok(ColumnType::untyped_text(parsed.text))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(self.grammar, text, crate::sql_syntax::MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }
}

fn row_id_type(part: EngineRowIdPart) -> &'static str {
    match part {
        EngineRowIdPart::PostgresTableOid => "oid",
        EngineRowIdPart::PostgresCtid => "tid",
        EngineRowIdPart::PostgresXmin => "xid",
        EngineRowIdPart::SqliteRowid => "Int64",
    }
}

fn row_id_param_type(part: EngineRowIdPart) -> ParamType {
    match part {
        EngineRowIdPart::SqliteRowid => ParamType::Int64,
        other => ParamType::ServerText(SqlTypeExpr::from_catalog_text(row_id_type(other))),
    }
}

/// The parameter type a column takes, reduced to what the tests need.
fn param_type_for(column: &ColumnInfo) -> ParamType {
    use crate::column::{BoolStorage, ColumnKind, FloatWidth, IntegerWidth, TemporalZone};

    match &column.column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => ParamType::Bool,
        ColumnKind::Bool(BoolStorage::Integer) => ParamType::Int64,
        ColumnKind::Integer(kind) => match (kind.width, kind.signed) {
            (IntegerWidth::W8 | IntegerWidth::W16, true) | (IntegerWidth::W8, false) => ParamType::Int16,
            (IntegerWidth::W24 | IntegerWidth::W32, true) | (IntegerWidth::W16 | IntegerWidth::W24, false) => {
                ParamType::Int32
            }
            (IntegerWidth::W64 | IntegerWidth::W128 | IntegerWidth::W256, false) => ParamType::UInt64,
            _ => ParamType::Int64,
        },
        ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => ParamType::Decimal,
        ColumnKind::Float(FloatWidth::F32) => ParamType::Float32,
        ColumnKind::Float(FloatWidth::F64) => ParamType::Float64,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Json { .. } => ParamType::Json,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time { with_offset: false, .. } => ParamType::Time,
        ColumnKind::Time { with_offset: true, .. } => ParamType::TimeTz,
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => ParamType::TimestampTz,
        ColumnKind::Timestamp { .. } => ParamType::Timestamp,
        ColumnKind::Interval => ParamType::Interval,
        ColumnKind::Bytes { .. } => ParamType::Bytes,
        ColumnKind::BitString { .. } => ParamType::Bits,
        _ => ParamType::Text,
    }
}
