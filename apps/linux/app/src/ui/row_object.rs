use std::cell::{Cell, RefCell};
use std::sync::{Arc, Weak};

use gtk4::glib;
use gtk4::subclass::prelude::*;

use tablepro_core::{QueryResult, Value};

const PREVIEW_BYTES: usize = 8 * 1024;

#[derive(Clone)]
pub struct SharedRow {
    result: Weak<QueryResult>,
    source_index: usize,
    projection: Option<Vec<usize>>,
}

impl SharedRow {
    fn cell<'a>(&self, result: &'a QueryResult, index: usize) -> Option<&'a Value> {
        let row = result.rows.get(self.source_index)?;
        let source_index = match &self.projection {
            Some(indices) => indices.iter().position(|mapped| *mapped == index)?,
            None => index,
        };
        row.get(source_index)
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct RowObject {
        pub cells: RefCell<Vec<Option<Value>>>,
        pub previews: RefCell<Vec<Option<CellPreview>>>,
        pub source: RefCell<Option<SharedRow>>,
        /// Local id for draft (uninserted) rows added via the
        /// inline-Insert flow. `None` for persisted rows fetched
        /// from the database. Lets `connect_bind` distinguish a
        /// draft (which needs the green-border CSS + RowKey::Draft
        /// tracker lookup) from a persisted row whose PK columns
        /// happen to be NULL.
        pub draft_id: Cell<Option<u64>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for RowObject {
        const NAME: &str = "TableProRowObject";
        type Type = super::RowObject;
    }

    impl ObjectImpl for RowObject {}
}

glib::wrapper! {
    pub struct RowObject(ObjectSubclass<imp::RowObject>);
}

#[derive(Debug, Clone, PartialEq)]
pub struct CellPreview {
    pub value: Value,
    pub byte_count: usize,
}

impl RowObject {
    pub fn new(cells: Vec<Value>) -> Self {
        let obj: Self = glib::Object::new();
        *obj.imp().cells.borrow_mut() = cells.into_iter().map(Some).collect();
        *obj.imp().previews.borrow_mut() = vec![None; obj.imp().cells.borrow().len()];
        obj
    }

    pub fn new_projected(cells: Vec<Value>, indices: &[usize], width: usize) -> Option<Self> {
        if cells.len() != indices.len() {
            return None;
        }
        let mut values = vec![None; width];
        for (index, value) in indices.iter().copied().zip(cells) {
            if index >= width || values[index].is_some() {
                return None;
            }
            values[index] = Some(value);
        }
        let obj: Self = glib::Object::new();
        *obj.imp().cells.borrow_mut() = values;
        *obj.imp().previews.borrow_mut() = vec![None; width];
        Some(obj)
    }

    pub(crate) fn from_shared(
        result: &Arc<QueryResult>,
        source_index: usize,
        projection: Option<(Vec<usize>, usize)>,
    ) -> Option<Self> {
        let source_row = result.rows.get(source_index)?;
        let (indices, width) = match projection {
            Some((indices, width)) => (Some(indices), width),
            None => (None, source_row.len()),
        };
        let row: Self = glib::Object::new();
        *row.imp().cells.borrow_mut() = vec![None; width];
        *row.imp().previews.borrow_mut() = vec![None; width];
        *row.imp().source.borrow_mut() = Some(SharedRow {
            result: Arc::downgrade(result),
            source_index,
            projection: indices,
        });
        Some(row)
    }

    pub fn new_draft(draft_id: u64, cells: Vec<Value>) -> Self {
        let obj = Self::new(cells);
        obj.imp().draft_id.set(Some(draft_id));
        obj
    }

    pub fn draft_id(&self) -> Option<u64> {
        self.imp().draft_id.get()
    }

    pub fn cell_value(&self, idx: usize) -> Value {
        self.with_cell_value(idx, Clone::clone)
            .unwrap_or_else(|| Value::Undecodable("not fetched".into()))
    }

    pub fn cell_is_loaded(&self, idx: usize) -> bool {
        self.with_cell_value(idx, |_| ()).is_some()
    }

    pub(crate) fn with_cell_value<R>(&self, idx: usize, f: impl FnOnce(&Value) -> R) -> Option<R> {
        let cells = self.imp().cells.borrow();
        if let Some(value) = cells.get(idx)?.as_ref() {
            return Some(f(value));
        }
        drop(cells);
        let source = self.imp().source.borrow();
        let shared = source.as_ref()?;
        let result = shared.result.upgrade()?;
        shared.cell(&result, idx).map(f)
    }

    pub(crate) fn detach_shared(&self) {
        let source = self.imp().source.borrow().clone();
        let Some(shared) = source else { return };
        let Some(result) = shared.result.upgrade() else { return };
        let mut cells = self.imp().cells.borrow_mut();
        for index in 0..cells.len() {
            if cells[index].is_none() {
                cells[index] = shared.cell(&result, index).cloned();
            }
        }
        self.imp().source.borrow_mut().take();
    }

    pub fn cell_preview(&self, idx: usize) -> Option<CellPreview> {
        self.imp().previews.borrow().get(idx).cloned().flatten()
    }

    pub fn preview_long_values(&self, key_indices: &[usize]) {
        if key_indices.is_empty()
            || key_indices.iter().any(|&index| {
                self.with_cell_value(index, |value| matches!(value, Value::Undecodable(_)))
                    .unwrap_or(true)
            })
        {
            return;
        }
        self.update_previews(|index| !key_indices.contains(&index));
    }

    pub fn preview_values_from_result(&self) {
        self.update_previews(|_| true);
    }

    fn update_previews(&self, should_preview: impl Fn(usize) -> bool) {
        let len = self.imp().cells.borrow().len();
        let updates = (0..len)
            .filter(|index| should_preview(*index))
            .map(|index| (index, self.with_cell_value(index, preview_value).flatten()))
            .collect::<Vec<_>>();
        let mut previews = self.imp().previews.borrow_mut();
        for (index, preview) in updates {
            previews[index] = preview;
        }
    }

    pub fn preview_long_redis_string_values(&self, key_indices: &[usize]) {
        if self.with_cell_value(1, |value| value == &Value::Text("string".into())) == Some(true) {
            self.preview_long_values(key_indices);
        }
    }

    pub fn cells_are_complete(&self) -> bool {
        let len = self.imp().cells.borrow().len();
        (0..len).all(|index| self.cell_is_loaded(index))
    }

    pub fn complete_cells(&self) -> Option<Vec<Value>> {
        let len = self.imp().cells.borrow().len();
        (0..len)
            .map(|index| self.with_cell_value(index, Clone::clone))
            .collect()
    }

    pub fn loaded_cells(&self) -> Vec<Option<Value>> {
        let len = self.imp().cells.borrow().len();
        (0..len)
            .map(|index| self.with_cell_value(index, Clone::clone))
            .collect()
    }

    pub fn clone_preserving_loading_state(&self) -> Self {
        let row: Self = glib::Object::new();
        *row.imp().cells.borrow_mut() = self.imp().cells.borrow().clone();
        *row.imp().previews.borrow_mut() = self.imp().previews.borrow().clone();
        *row.imp().source.borrow_mut() = self.imp().source.borrow().clone();
        row.imp().draft_id.set(self.draft_id());
        row
    }

    pub fn cells_clone(&self) -> Vec<Value> {
        let len = self.imp().cells.borrow().len();
        (0..len)
            .map(|index| {
                self.with_cell_value(index, Clone::clone)
                    .unwrap_or_else(|| Value::Undecodable("not fetched".into()))
            })
            .collect()
    }

    pub fn with_cells<R>(&self, f: impl FnOnce(&[Value]) -> R) -> R {
        let cells = self.cells_clone();
        f(&cells)
    }

    /// In-place cell mutation. Used by the inline-edit flow on draft
    /// rows so the grid renders the user's typed value immediately
    /// instead of waiting for a re-fetch.
    pub fn set_cell(&self, idx: usize, value: Value) {
        let mut cells = self.imp().cells.borrow_mut();
        if idx < cells.len() {
            cells[idx] = Some(value);
            self.imp().previews.borrow_mut()[idx] = None;
        }
    }
}

fn preview_value(value: &Value) -> Option<CellPreview> {
    match value {
        Value::Text(text) if text.len() > PREVIEW_BYTES => Some(CellPreview {
            value: Value::Text(text[..text.floor_char_boundary(PREVIEW_BYTES)].to_owned()),
            byte_count: text.len(),
        }),
        Value::Json(json) if json_exceeds(json, PREVIEW_BYTES) => json_preview(json),
        Value::JsonText(json) if json.len() > PREVIEW_BYTES => Some(CellPreview {
            value: Value::JsonText(json[..json.floor_char_boundary(PREVIEW_BYTES)].to_owned()),
            byte_count: json.len(),
        }),
        Value::Bytes(bytes) if bytes.len() > PREVIEW_BYTES => Some(CellPreview {
            value: Value::Bytes(bytes[..PREVIEW_BYTES].to_vec()),
            byte_count: bytes.len(),
        }),
        _ => None,
    }
}

struct JsonPreviewWriter {
    prefix: Vec<u8>,
    byte_count: usize,
}

impl std::io::Write for JsonPreviewWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.byte_count = self
            .byte_count
            .checked_add(bytes.len())
            .ok_or(std::io::ErrorKind::InvalidData)?;
        let retained = bytes.len().min(PREVIEW_BYTES.saturating_sub(self.prefix.len()));
        self.prefix.extend_from_slice(&bytes[..retained]);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn json_preview(json: &serde_json::Value) -> Option<CellPreview> {
    let mut writer = JsonPreviewWriter {
        prefix: Vec::with_capacity(PREVIEW_BYTES),
        byte_count: 0,
    };
    serde_json::to_writer(&mut writer, json).ok()?;
    let end = std::str::from_utf8(&writer.prefix).map_or_else(|error| error.valid_up_to(), str::len);
    writer.prefix.truncate(end);
    Some(CellPreview {
        value: Value::Text(String::from_utf8(writer.prefix).ok()?),
        byte_count: writer.byte_count,
    })
}

fn json_exceeds(json: &serde_json::Value, limit: usize) -> bool {
    struct Budget(usize);
    impl std::io::Write for Budget {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 = self.0.checked_sub(bytes.len()).ok_or(std::io::ErrorKind::WriteZero)?;
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    serde_json::to_writer(Budget(limit), json).is_err()
}

#[cfg(test)]
mod tests {
    use super::*;
    use gtk4::glib::object::CastNone;
    use gtk4::prelude::ListModelExt;
    use std::sync::Arc;
    use tablepro_core::{ColumnInfo, QueryResult};

    #[test]
    fn json_preview_writer_counts_all_bytes_without_growing_past_its_sample() {
        let mut writer = JsonPreviewWriter {
            prefix: Vec::with_capacity(PREVIEW_BYTES),
            byte_count: 0,
        };
        let chunk = vec![b'x'; PREVIEW_BYTES * 8];
        std::io::Write::write_all(&mut writer, &chunk).unwrap();
        std::io::Write::write_all(&mut writer, &chunk).unwrap();
        assert_eq!(writer.byte_count, PREVIEW_BYTES * 16);
        assert_eq!(writer.prefix, vec![b'x'; PREVIEW_BYTES]);
        assert_eq!(writer.prefix.capacity(), PREVIEW_BYTES);
    }

    #[test]
    fn json_preview_writer_refuses_an_overflowing_byte_count() {
        let mut writer = JsonPreviewWriter {
            prefix: Vec::new(),
            byte_count: usize::MAX,
        };
        let error = std::io::Write::write(&mut writer, b"x").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(writer.byte_count, usize::MAX);
        assert!(writer.prefix.is_empty());
    }

    #[test]
    fn a_large_parsed_json_preview_keeps_its_sample_and_exact_serialized_byte_count() {
        let value = Value::Json(Box::new(serde_json::Value::String("x".repeat(8 * 1024 * 1024))));
        let preview = preview_value(&value).unwrap();
        assert_eq!(preview.byte_count, 8 * 1024 * 1024 + 2);
        assert_eq!(preview.value, Value::Text(format!("\"{}", "x".repeat(8191))));
        assert!(
            matches!(&value, Value::Json(json) if matches!(json.as_ref(), serde_json::Value::String(text) if text.len() == 8 * 1024 * 1024))
        );
    }

    #[test]
    fn parsed_json_preview_matches_serialized_escapes_and_utf8_boundaries() {
        let json = serde_json::json!({"payload": "é😀\0\\\"".repeat(2000)});
        let serialized = json.to_string();
        let preview = preview_value(&Value::Json(Box::new(json))).unwrap();
        let end = serialized.floor_char_boundary(8192);
        assert_eq!(preview.byte_count, serialized.len());
        assert_eq!(preview.value, Value::Text(serialized[..end].to_owned()));
    }

    #[test]
    fn parsed_json_uses_its_serialized_size_at_the_preview_boundary() {
        assert!(preview_value(&Value::Json(Box::new(serde_json::Value::String("x".repeat(8190))))).is_none());
        let preview = preview_value(&Value::Json(Box::new(serde_json::Value::String("x".repeat(8191))))).unwrap();
        assert_eq!(preview.byte_count, 8193);
    }

    #[test]
    fn a_json_value_is_measured_without_serialising_small_documents_twice() {
        assert!(!json_exceeds(&serde_json::json!({"a": 1}), 8));
        assert!(json_exceeds(&serde_json::json!({"payload": "x".repeat(20)}), 8));
        assert!(!json_exceeds(&serde_json::json!("12345"), 7));
    }

    #[test]
    fn shared_result_rows_do_not_clone_large_cell_payloads_into_row_objects() {
        let payload = "x".repeat(1_000_000);
        let result = Arc::new(QueryResult {
            columns: vec![ColumnInfo {
                name: "payload".into(),
                data_type: "TEXT".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Text(payload.clone())]],
            truncated: false,
        });
        let source_pointer = match &result.rows[0][0] {
            Value::Text(text) => text.as_ptr() as usize,
            _ => 0,
        };
        let store = crate::ui::row_store::RowStore::from_shared_with_result_previews(result.clone());
        let row = store.item(0).and_downcast::<RowObject>().unwrap();

        let row_pointer = row
            .with_cell_value(0, |value| match value {
                Value::Text(text) => text.as_ptr() as usize,
                _ => 0,
            })
            .unwrap();
        assert_eq!(row_pointer, source_pointer);
        assert_eq!(row.cell_value(0), Value::Text(payload.clone()));
        assert_eq!(row.cell_preview(0).unwrap().byte_count, payload.len());
    }

    #[test]
    fn projected_cells_distinguish_unfetched_values_from_sql_null() {
        let row = RowObject::new_projected(vec![Value::Null, Value::Text("shown".into())], &[0, 2], 3).unwrap();

        assert!(row.cell_is_loaded(0));
        assert_eq!(row.cell_value(0), Value::Null);
        assert!(!row.cell_is_loaded(1));
        assert_eq!(row.cell_value(1), Value::Undecodable("not fetched".into()));
        assert!(!row.cells_are_complete());
        assert_eq!(row.complete_cells(), None);
    }

    #[test]
    fn projected_cells_refuse_mismatched_or_duplicate_mappings() {
        assert!(RowObject::new_projected(vec![Value::Int(1)], &[], 1).is_none());
        assert!(RowObject::new_projected(vec![Value::Int(1), Value::Int(2)], &[0, 0], 1).is_none());
    }

    #[test]
    fn cloning_a_projected_row_keeps_unfetched_cells_unloaded() {
        let row = RowObject::new_projected(vec![Value::Int(1)], &[0], 2).unwrap();
        let clone = row.clone_preserving_loading_state();

        assert_eq!(clone.cell_value(0), Value::Int(1));
        assert!(!clone.cell_is_loaded(1));
        assert!(clone.complete_cells().is_none());
    }

    #[test]
    fn long_cells_keep_an_eight_kib_preview_and_primary_keys_remain_loaded() {
        let text = format!("{}é", "x".repeat(8191));
        let row = RowObject::new(vec![Value::Int(7), Value::Text(text.clone())]);
        row.preview_long_values(&[0]);

        assert_eq!(row.cell_value(0), Value::Int(7));
        assert_eq!(row.cell_value(1), Value::Text(text.clone()));
        let preview = row.cell_preview(1).unwrap();
        assert_eq!(preview.value, Value::Text("x".repeat(8191)));
        assert_eq!(preview.byte_count, text.len());
        assert_eq!(row.complete_cells(), Some(vec![Value::Int(7), Value::Text(text)]));
    }

    #[test]
    fn previews_keep_the_byte_boundary_and_cover_json_and_binary_values() {
        let exact = RowObject::new(vec![Value::Int(1), Value::Text("x".repeat(8192))]);
        exact.preview_long_values(&[0]);
        assert!(exact.cell_is_loaded(1));

        let bytes = vec![0xA5; 8193];
        let row = RowObject::new(vec![
            Value::Int(1),
            Value::Bytes(bytes.clone()),
            Value::Json(Box::new(serde_json::json!("x".repeat(8192)))),
        ]);
        row.preview_long_values(&[0]);
        assert_eq!(row.cell_preview(1).unwrap().value, Value::Bytes(bytes[..8192].to_vec()));
        assert_eq!(row.cell_preview(1).unwrap().byte_count, 8193);
        assert!(row.cell_preview(2).is_some());
    }
}
