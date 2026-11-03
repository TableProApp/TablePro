use std::borrow::Cow;

use futures_util::{StreamExt, TryStreamExt, stream::BoxStream};
use tiberius::{ColumnData, Command, CommandItem, IntoSql, QueryItem};

use crate::physical::MssqlClient;

// SQL Server 2022 with TDS 8 requires the leading @ on sp_executesql's parameter names.
pub(crate) fn command<'a>(sql: &'a str, params: &[ColumnData<'static>]) -> Command<'a> {
    let mut command = Command::new("sp_executesql");
    command.bind_param("@stmt", sql);
    if !params.is_empty() {
        command.bind_param("@params", declarations(params));
        for (index, value) in params.iter().enumerate() {
            command.bind_param(format!("@P{}", index + 1), Parameter(value.clone()));
        }
    }
    command
}

pub(crate) async fn query<'a>(
    client: &'a mut MssqlClient,
    sql: &str,
    params: &[ColumnData<'static>],
) -> Result<BoxStream<'a, Result<QueryItem, tiberius::error::Error>>, tiberius::error::Error> {
    let stream = command(sql, params).exec(client).await?;
    Ok(stream
        .try_filter_map(|item| async move {
            Ok(match item {
                CommandItem::Metadata(metadata) => Some(QueryItem::Metadata(metadata)),
                CommandItem::Row(row) => Some(QueryItem::Row(row)),
                _ => None,
            })
        })
        .boxed())
}

struct Parameter(ColumnData<'static>);

impl<'a> IntoSql<'a> for Parameter {
    fn into_sql(self) -> ColumnData<'a> {
        self.0
    }
}

fn declarations(params: &[ColumnData<'static>]) -> String {
    params
        .iter()
        .enumerate()
        .map(|(index, value)| format!("@P{} {}", index + 1, declaration(value)))
        .collect::<Vec<_>>()
        .join(", ")
}

// Values stay in RPC fields; only the encoded type supplies declaration text.
fn declaration(value: &ColumnData<'_>) -> Cow<'static, str> {
    match value {
        ColumnData::U8(_) => "tinyint".into(),
        ColumnData::I16(_) => "smallint".into(),
        ColumnData::I32(_) => "int".into(),
        ColumnData::I64(_) => "bigint".into(),
        ColumnData::F32(_) => "float(24)".into(),
        ColumnData::F64(_) => "float(53)".into(),
        ColumnData::Bit(_) => "bit".into(),
        ColumnData::String(_) => "nvarchar(max)".into(),
        ColumnData::Binary(_) => "varbinary(max)".into(),
        ColumnData::Guid(_) => "uniqueidentifier".into(),
        ColumnData::Numeric(Some(number)) => format!("numeric({},{})", number.precision(), number.scale()).into(),
        ColumnData::Numeric(None) => "numeric".into(),
        ColumnData::Xml(_) => "xml".into(),
        ColumnData::DateTime(_) => "datetime".into(),
        ColumnData::SmallDateTime(_) => "smalldatetime".into(),
        ColumnData::Time(_) => "time".into(),
        ColumnData::Date(_) => "date".into(),
        ColumnData::DateTime2(_) => "datetime2".into(),
        ColumnData::DateTimeOffset(_) => "datetimeoffset".into(),
    }
}

#[cfg(test)]
mod tests {
    use tiberius::numeric::Numeric;

    use super::*;

    #[test]
    fn declaration_keeps_null_types_and_decimal_scale_without_embedding_values() {
        let params = vec![
            ColumnData::String(Some("'; DROP TABLE t; --".into())),
            ColumnData::Binary(None),
            ColumnData::Numeric(Some(Numeric::new_with_scale(12345, 3))),
            ColumnData::DateTimeOffset(None),
        ];
        assert_eq!(
            declarations(&params),
            "@P1 nvarchar(max), @P2 varbinary(max), @P3 numeric(5,3), @P4 datetimeoffset"
        );
    }
}
