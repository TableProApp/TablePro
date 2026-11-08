use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{EncodeError, JsonArrayEncoder, RowEncoder};

use super::{DataGrid, GridRow, ShownColumns};
use crate::services::grid::RowSnapshot;

const MAX_ROWS: usize = 1_000;
const MAX_BYTES: usize = 256 * 1024;
const MAX_DEPTH: usize = 64;

pub(crate) struct JsonPreviewRequest {
    columns: Arc<[ResultColumn]>,
    indices: Vec<usize>,
    rows: Vec<RowSnapshot>,
    total: usize,
    deleted: usize,
}

pub(crate) struct JsonPreview {
    pub(crate) text: String,
    pub(crate) shown: usize,
    pub(crate) total: usize,
    pub(crate) deleted: usize,
}

pub(crate) fn json_preview(grid: &DataGrid) -> JsonPreviewRequest {
    let columns = ShownColumns::of(grid);
    let tracked = grid.tracked();
    let model = grid.selection();
    let mut rows = Vec::new();
    let mut total = 0;
    let mut deleted = 0;
    for position in 0..model.n_items() {
        let Some(row) = model.item(position).and_downcast::<GridRow>() else {
            continue;
        };
        if tracked.mark(&row, 0).row_deleted {
            deleted += 1;
            continue;
        }
        total += 1;
        if rows.len() < MAX_ROWS {
            rows.push(tracked.snapshot(&row));
        }
    }
    JsonPreviewRequest {
        columns: columns.columns,
        indices: columns.indices,
        rows,
        total,
        deleted,
    }
}

impl JsonPreviewRequest {
    pub(crate) fn render(self) -> Result<JsonPreview, EncodeError> {
        let mut name_budget = MAX_BYTES;
        let names_fit = self
            .columns
            .iter()
            .all(|column| spend(&mut name_budget, column.name.len().saturating_add(16)));
        if !names_fit {
            return Ok(self.empty());
        }
        let mut encoder = JsonArrayEncoder::new(self.columns.clone());
        let mut bytes = Vec::new();
        let mut shown = 0;
        encoder.begin(&mut bytes);
        for row in &self.rows {
            let mut budget = name_budget;
            // Refuse huge values before the core serializer allocates their escaped representation.
            if !self.indices.iter().all(|index| fits(row.value(*index), &mut budget, 0)) {
                break;
            }
            for (column, index) in self.columns.iter().zip(&self.indices) {
                if unreadable(row.value(*index)) {
                    return Err(EncodeError::Undecodable {
                        column: column.name.clone(),
                    });
                }
            }
            let start = bytes.len();
            let mut values = self.indices.iter().map(|index| row.value(*index));
            encoder.row(&mut bytes, &mut values)?;
            if bytes.len().saturating_add(2) > MAX_BYTES {
                bytes.truncate(start);
                break;
            }
            shown += 1;
        }
        encoder.finish(&mut bytes);
        Ok(JsonPreview {
            text: String::from_utf8_lossy(&bytes).into_owned(),
            shown,
            total: self.total,
            deleted: self.deleted,
        })
    }

    fn empty(&self) -> JsonPreview {
        JsonPreview {
            text: "[]".into(),
            shown: 0,
            total: self.total,
            deleted: self.deleted,
        }
    }
}

fn unreadable(value: &Value) -> bool {
    match value {
        Value::Undecodable(_) => true,
        Value::Array(values) => values.iter().any(unreadable),
        _ => false,
    }
}

fn spend(budget: &mut usize, bytes: usize) -> bool {
    match budget.checked_sub(bytes) {
        Some(left) => {
            *budget = left;
            true
        }
        None => false,
    }
}

fn fits(value: &Value, budget: &mut usize, depth: usize) -> bool {
    let bytes = match value {
        Value::Text(text) => text.len(),
        Value::Json(json) => json.as_str().len(),
        Value::Other(other) => other.text.len(),
        Value::Bytes(bytes) => bytes.len().saturating_mul(2),
        Value::Bits(bits) => bits.bit_len() as usize,
        Value::Decimal(decimal) => decimal.precision().unwrap_or(8) as usize + 3,
        Value::Array(values) => {
            return depth < MAX_DEPTH
                && spend(budget, values.len().saturating_add(2))
                && values.iter().all(|value| fits(value, budget, depth + 1));
        }
        _ => 80,
    };
    spend(budget, bytes.saturating_add(2))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnType;
    use tablepro_core::value::{UndecodableReason, UndecodedValue};

    use super::*;

    fn request(values: Vec<Value>) -> JsonPreviewRequest {
        let total = values.len();
        JsonPreviewRequest {
            columns: vec![ResultColumn::new("value", ColumnType::untyped_text("text"))].into(),
            indices: vec![0],
            rows: values
                .into_iter()
                .take(MAX_ROWS)
                .map(|value| RowSnapshot::new(vec![value].into(), Vec::new()))
                .collect(),
            total,
            deleted: 0,
        }
    }

    #[test]
    fn preview_reports_rows_beyond_the_limit_and_stays_a_complete_array() {
        let preview = request((0..1_005).map(Value::Int).collect()).render().unwrap();
        assert_eq!((preview.shown, preview.total), (1_000, 1_005));
        let json: serde_json::Value = serde_json::from_str(&preview.text).unwrap();
        assert_eq!(json.as_array().unwrap().len(), 1_000);
        assert_eq!(json[999]["value"], 999);
    }

    #[test]
    fn preview_bounds_escaped_text_at_a_whole_row() {
        let preview = request(vec![
            Value::Text("kept".into()),
            Value::Text("\u{0001}".repeat(100_000)),
            Value::Text("later".into()),
        ])
        .render()
        .unwrap();
        assert!(preview.text.len() <= MAX_BYTES);
        assert_eq!((preview.shown, preview.total), (1, 3));
        let json: serde_json::Value = serde_json::from_str(&preview.text).unwrap();
        assert_eq!(json, serde_json::json!([{"value": "kept"}]));
    }

    #[test]
    fn preview_refuses_a_huge_value_before_encoding_it() {
        let preview = request(vec![Value::Bytes(vec![0; MAX_BYTES])]).render().unwrap();
        assert_eq!((preview.shown, preview.total), (0, 1));
        assert_eq!(preview.text, "[]");
    }

    #[test]
    fn preview_refuses_unreadable_values_instead_of_inventing_null() {
        let value = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "custom".into(),
            reason: UndecodableReason::UnsupportedType,
        }));
        for value in [value.clone(), Value::Array(vec![value])] {
            assert_eq!(
                request(vec![value]).render().err(),
                Some(EncodeError::Undecodable { column: "value".into() })
            );
        }
    }

    #[test]
    fn preview_snapshot_can_leave_the_gtk_thread() {
        fn sendable<T: Send>() {}
        sendable::<JsonPreviewRequest>();
        sendable::<JsonPreview>();
    }
}
