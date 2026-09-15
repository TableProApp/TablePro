use crate::query_result::QueryResult;
use crate::value::Value;

use super::{BrowsePage, BrowseSqlError, RowKeyLayout};

/// Take a page apart into what the user sees and what names each row.
///
/// The hidden row-id columns stop here. Everything downstream, the
/// grid, export, copy and the insert preview, only ever gets the
/// visible ones.
pub fn split_page(
    result: QueryResult,
    visible_columns: usize,
    layout: &RowKeyLayout,
) -> Result<BrowsePage, BrowseSqlError> {
    let expected = visible_columns + layout.hidden_count();
    if result.columns.len() != expected {
        return Err(BrowseSqlError::ShapeMismatch {
            expected,
            found: result.columns.len(),
        });
    }

    let columns = result.columns[..visible_columns].to_vec().into();
    let mut rows = Vec::with_capacity(result.rows.len());
    let mut keys = Vec::with_capacity(result.rows.len());
    for row in result.rows {
        if row.len() != expected {
            return Err(BrowseSqlError::ShapeMismatch {
                expected,
                found: row.len(),
            });
        }
        keys.push(key_of(&row, layout));
        let mut visible = row;
        visible.truncate(visible_columns);
        rows.push(visible);
    }

    Ok(BrowsePage {
        columns,
        rows,
        keys,
        truncated: result.truncated,
    })
}

/// The key for one row, or `None` when it cannot be used to name the
/// row again.
fn key_of(row: &[Value], layout: &RowKeyLayout) -> Option<Vec<Value>> {
    match layout {
        RowKeyLayout::ReadOnly => None,
        RowKeyLayout::Columns(positions) => positions
            .iter()
            .map(|position| row.get(*position).filter(|value| is_readable(value)).cloned())
            .collect(),
        RowKeyLayout::EngineRowId { first_hidden, parts } => (0..parts.len())
            .map(|part| {
                row.get(first_hidden + part)
                    // A null row address names nothing, and an
                    // unreadable one cannot go back to the server.
                    .filter(|value| is_readable(value) && !value.is_null())
                    .cloned()
            })
            .collect(),
    }
}

fn is_readable(value: &Value) -> bool {
    !matches!(value, Value::Undecodable(_))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::column::{CatalogType, ColumnKind, ColumnType, IntegerKind, ReadForm, ResultColumn, SqlTypeExpr};
    use crate::meta::EngineRowIdPart;
    use crate::value::{UndecodableReason, UndecodedValue};

    use super::*;

    fn column(name: &str) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType::new(
                SqlTypeExpr::from_catalog_text("integer"),
                ColumnKind::Integer(IntegerKind::I32),
                CatalogType::Oid(23),
                false,
                ReadForm::Native,
            ),
        )
    }

    fn result(names: &[&str], rows: Vec<Vec<Value>>) -> QueryResult {
        QueryResult {
            columns: names.iter().map(|name| column(name)).collect::<Vec<_>>().into(),
            rows,
            truncated: false,
        }
    }

    fn undecodable() -> Value {
        Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }))
    }

    #[test]
    fn split_page_strips_hidden_row_id_columns() {
        let page = result(
            &["name", "__tablepro_row_id"],
            vec![vec![Value::Text("a".to_owned()), Value::Int(11)]],
        );
        let layout = RowKeyLayout::EngineRowId {
            first_hidden: 1,
            parts: &[EngineRowIdPart::SqliteRowid],
        };

        let split = split_page(page, 1, &layout).expect("the page");

        assert_eq!(split.columns.len(), 1);
        assert_eq!(split.columns[0].name, "name");
        assert_eq!(split.rows, vec![vec![Value::Text("a".to_owned())]]);
        assert_eq!(split.key(0), Some(&vec![Value::Int(11)]));
    }

    #[test]
    fn split_page_keys_follow_unique_key_positions() {
        let page = result(
            &["tenant", "name", "id"],
            vec![vec![Value::Int(1), Value::Text("a".to_owned()), Value::Int(7)]],
        );

        // The key is (id, tenant), which is not the column order.
        let split = split_page(page, 3, &RowKeyLayout::Columns(vec![2, 0])).expect("the page");

        assert_eq!(split.key(0), Some(&vec![Value::Int(7), Value::Int(1)]));
        assert_eq!(split.columns.len(), 3, "a column-keyed page hid a column");
    }

    #[test]
    fn split_page_undecodable_key_is_not_editable() {
        let page = result(&["id", "name"], vec![vec![undecodable(), Value::Text("a".to_owned())]]);

        let split = split_page(page, 2, &RowKeyLayout::Columns(vec![0])).expect("the page");

        assert_eq!(split.key(0), None, "a row whose key could not be read looked editable");
        assert!(!split.has_editable_rows());
        assert_eq!(split.rows[0][0], undecodable(), "the cell itself was dropped");
    }

    #[test]
    fn a_null_engine_row_id_is_not_editable() {
        let page = result(
            &["name", "__tablepro_row_id"],
            vec![vec![Value::Text("a".to_owned()), Value::Null]],
        );
        let layout = RowKeyLayout::EngineRowId {
            first_hidden: 1,
            parts: &[EngineRowIdPart::SqliteRowid],
        };

        let split = split_page(page, 1, &layout).expect("the page");

        assert_eq!(split.key(0), None);
    }

    #[test]
    fn split_page_shape_mismatch_is_error() {
        let page = result(&["name"], vec![vec![Value::Text("a".to_owned())]]);
        let layout = RowKeyLayout::EngineRowId {
            first_hidden: 1,
            parts: &[EngineRowIdPart::SqliteRowid],
        };

        let error = split_page(page, 1, &layout).expect_err("a page missing its hidden column");

        assert_eq!(error, BrowseSqlError::ShapeMismatch { expected: 2, found: 1 });
    }

    #[test]
    fn a_read_only_page_keeps_every_column_and_no_keys() {
        let page = result(&["a", "b"], vec![vec![Value::Int(1), Value::Int(2)]]);

        let split = split_page(page, 2, &RowKeyLayout::ReadOnly).expect("the page");

        assert_eq!(split.columns.len(), 2);
        assert_eq!(split.row_count(), 1);
        assert!(!split.has_editable_rows());
    }

    #[test]
    fn the_shared_column_slice_is_not_the_one_the_query_returned() {
        let page = result(&["a", "hidden"], vec![]);
        let layout = RowKeyLayout::EngineRowId {
            first_hidden: 1,
            parts: &[EngineRowIdPart::SqliteRowid],
        };

        let split = split_page(page, 1, &layout).expect("the page");

        assert_eq!(Arc::strong_count(&split.columns), 1);
    }
}
