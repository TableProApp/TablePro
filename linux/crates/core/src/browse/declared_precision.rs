use crate::column::{ColumnInfo, ColumnKind, ResultColumn};
use crate::query_result::QueryResult;

/// The page's columns, with the fractional digits and bit lengths their
/// catalogue entries declare where the result's own metadata names
/// none.
///
/// MySQL's result metadata, as sqlx exposes it, carries neither a
/// DATETIME(6)'s digits nor a BIT(10)'s length, and the grid writes a
/// value at what its column declares. Only a column of the same kind is
/// refined: one the page projected as another type keeps the result's.
pub(super) fn with_declared_precision(result: QueryResult, catalog: &[ColumnInfo]) -> QueryResult {
    let refined: Vec<(usize, ColumnKind)> = result
        .columns
        .iter()
        .zip(catalog)
        .enumerate()
        .filter(|(_, (column, info))| column.name == info.name)
        .filter_map(|(index, (column, info))| {
            refined(&column.column_type.kind, &info.column_type.kind).map(|kind| (index, kind))
        })
        .collect();
    if refined.is_empty() {
        return result;
    }
    let mut columns: Vec<ResultColumn> = result.columns.to_vec();
    for (index, kind) in refined {
        if let Some(column) = columns.get_mut(index) {
            column.column_type.kind = kind;
        }
    }
    QueryResult {
        columns: columns.into(),
        ..result
    }
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
}
