use std::sync::Arc;

use async_trait::async_trait;

use crate::column::{ColumnInfo, ColumnKind, ResultColumn};
use crate::query_result::QueryResult;
use crate::result_event::ResultEvent;
use crate::result_sink::{ResultSink, SinkFlow};

/// The page, with the fractional digits and bit lengths its columns'
/// catalogue entries declare where the result's own metadata names
/// none.
///
/// MySQL's result metadata, as sqlx exposes it, carries neither a
/// DATETIME(6)'s digits nor a BIT(10)'s length, and the grid writes a
/// value at what its column declares. Only a column of the same kind is
/// refined: one the page projected as another type keeps the result's.
pub(super) fn with_declared_precision(result: QueryResult, catalog: &[ColumnInfo]) -> QueryResult {
    match declared_columns(&result.columns, catalog) {
        Some(columns) => QueryResult { columns, ..result },
        None => result,
    }
}

/// A table export's sink. Its columns take what the catalogue declares,
/// as a page's do, so the file holds what the grid showed.
pub struct DeclaredPrecisionSink {
    inner: Box<dyn ResultSink>,
    catalog: Arc<[ColumnInfo]>,
}

impl DeclaredPrecisionSink {
    pub fn new(inner: Box<dyn ResultSink>, catalog: Arc<[ColumnInfo]>) -> Self {
        Self { inner, catalog }
    }
}

#[async_trait]
impl ResultSink for DeclaredPrecisionSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let event = match event {
            ResultEvent::ResultSetStarted { columns } => ResultEvent::ResultSetStarted {
                columns: declared_columns(&columns, &self.catalog).unwrap_or(columns),
            },
            ResultEvent::ColumnsResolved { set_index, columns } => ResultEvent::ColumnsResolved {
                set_index,
                columns: declared_columns(&columns, &self.catalog).unwrap_or(columns),
            },
            other => other,
        };
        self.inner.accept(event).await
    }
}

/// `None` when no column takes anything from the catalogue.
fn declared_columns(columns: &[ResultColumn], catalog: &[ColumnInfo]) -> Option<Arc<[ResultColumn]>> {
    let refined: Vec<(usize, ColumnKind)> = columns
        .iter()
        .zip(catalog)
        .enumerate()
        .filter(|(_, (column, info))| column.name == info.name)
        .filter_map(|(index, (column, info))| {
            refined(&column.column_type.kind, &info.column_type.kind).map(|kind| (index, kind))
        })
        .collect();
    if refined.is_empty() {
        return None;
    }
    let mut columns = columns.to_vec();
    for (index, kind) in refined {
        if let Some(column) = columns.get_mut(index) {
            column.column_type.kind = kind;
        }
    }
    Some(columns.into())
}

fn refined(result: &ColumnKind, declared: &ColumnKind) -> Option<ColumnKind> {
    match (result, declared) {
        (
            ColumnKind::Timestamp {
                fractional_digits: None,
                zone,
            },
            ColumnKind::Timestamp {
                fractional_digits: Some(digits),
                ..
            },
        ) => Some(ColumnKind::Timestamp {
            fractional_digits: Some(*digits),
            zone: zone.clone(),
        }),
        (
            ColumnKind::Time {
                fractional_digits: None,
                with_offset,
                range,
            },
            ColumnKind::Time {
                fractional_digits: Some(digits),
                ..
            },
        ) => Some(ColumnKind::Time {
            fractional_digits: Some(*digits),
            with_offset: *with_offset,
            range: *range,
        }),
        (
            ColumnKind::BitString { length: None, varying },
            ColumnKind::BitString {
                length: Some(length), ..
            },
        ) => Some(ColumnKind::BitString {
            length: Some(*length),
            varying: *varying,
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::column::{ColumnDefault, ColumnType, ReadForm, TemporalZone, TextLength, TimeRange};
    use crate::value::Value;

    fn typed(kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    fn info(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: typed(kind),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn stamp(fractional_digits: Option<u8>, zone: TemporalZone) -> ColumnKind {
        ColumnKind::Timestamp {
            fractional_digits,
            zone,
        }
    }

    fn bits(length: Option<u32>) -> ColumnKind {
        ColumnKind::BitString { length, varying: false }
    }

    fn result(columns: &[(&str, ColumnKind)]) -> QueryResult {
        let columns: Vec<ResultColumn> = columns
            .iter()
            .map(|(name, kind)| ResultColumn::new(*name, typed(kind.clone())))
            .collect();
        QueryResult::new(columns, vec![vec![Value::Null; 2]])
    }

    fn kinds(result: &QueryResult) -> Vec<ColumnKind> {
        result
            .columns
            .iter()
            .map(|column| column.column_type.kind.clone())
            .collect()
    }

    #[test]
    fn a_result_without_digits_or_a_length_takes_the_catalogues() {
        let read = result(&[("at", stamp(None, TemporalZone::Offset)), ("flag", bits(None))]);
        let catalog = [
            info("at", stamp(Some(3), TemporalZone::Naive)),
            info("flag", bits(Some(1))),
        ];

        let refined = with_declared_precision(read, &catalog);

        assert_eq!(kinds(&refined), [stamp(Some(3), TemporalZone::Offset), bits(Some(1))]);
        assert_eq!(refined.rows, [vec![Value::Null; 2]]);
    }

    #[test]
    fn a_time_takes_the_digits_and_keeps_its_range() {
        let time = |fractional_digits| ColumnKind::Time {
            fractional_digits,
            with_offset: false,
            range: TimeRange::Duration,
        };

        let refined = with_declared_precision(result(&[("t", time(None))]), &[info("t", time(Some(6)))]);

        assert_eq!(kinds(&refined), [time(Some(6))]);
    }

    #[test]
    fn what_the_result_declares_or_projected_as_another_type_stays() {
        let text = ColumnKind::Text {
            length: TextLength::Unbounded,
        };
        let enumeration = ColumnKind::Enum {
            labels: vec!["a".to_owned()],
            multiple: false,
        };
        let read = result(&[("at", stamp(Some(6), TemporalZone::Naive)), ("mood", text.clone())]);
        let catalog = [
            info("at", stamp(Some(3), TemporalZone::Naive)),
            info("mood", enumeration),
        ];

        let refined = with_declared_precision(read, &catalog);

        assert_eq!(kinds(&refined), [stamp(Some(6), TemporalZone::Naive), text]);
    }

    #[test]
    fn a_column_under_another_name_is_not_the_catalogues() {
        let read = result(&[("other", bits(None))]);

        let refined = with_declared_precision(read, &[info("flag", bits(Some(1)))]);

        assert_eq!(kinds(&refined), [bits(None)]);
    }

    #[derive(Clone, Default)]
    struct Seen(Arc<Mutex<Vec<ResultEvent>>>);

    #[async_trait]
    impl ResultSink for Seen {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.0.lock().expect("the events").push(event);
            SinkFlow::Continue
        }
    }

    #[tokio::test]
    async fn an_export_takes_the_catalogues_digits_for_every_result_set() {
        let seen = Seen::default();
        let mut sink = DeclaredPrecisionSink::new(Box::new(seen.clone()), vec![info("flag", bits(Some(1)))].into());
        let read: Arc<[ResultColumn]> = vec![ResultColumn::new("flag", typed(bits(None)))].into();

        sink.accept(ResultEvent::ResultSetStarted { columns: read.clone() })
            .await;
        sink.accept(ResultEvent::ColumnsResolved {
            set_index: 0,
            columns: read,
        })
        .await;
        sink.accept(ResultEvent::Rows(vec![vec![Value::Null]])).await;

        let events = seen.0.lock().expect("the events");
        let columns: Vec<ColumnKind> = events
            .iter()
            .filter_map(|event| match event {
                ResultEvent::ResultSetStarted { columns } | ResultEvent::ColumnsResolved { columns, .. } => {
                    Some(columns[0].column_type.kind.clone())
                }
                _ => None,
            })
            .collect();
        assert_eq!(columns, [bits(Some(1)), bits(Some(1))]);
        assert!(matches!(events.last(), Some(ResultEvent::Rows(_))));
    }
}
