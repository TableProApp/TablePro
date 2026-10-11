use std::borrow::Cow;
use std::marker::PhantomData;
use std::sync::OnceLock;

use gtk4::glib;
use gtk4::prelude::*;

use tablepro_core::{ColumnInfo, Value};

const DISPLAY_TEXT_MAX_CHARS: usize = 10_000;
const DISPLAY_TEXT_BYTES_THRESHOLD: usize = DISPLAY_TEXT_MAX_CHARS * 4;

pub fn editable_null_sentinel() -> String {
    crate::tr!("<NULL>")
}

pub(crate) fn readonly_null_sentinel() -> String {
    crate::tr!("NULL")
}

pub(crate) fn auto_filled_sentinel() -> String {
    crate::tr!("(auto)")
}

#[derive(Debug, Clone)]
pub(super) struct CellView {
    pub(super) display_text: String,
    pub(super) is_null: bool,
    pub(super) inline_editable: bool,
    pub(super) auto_filled: bool,
    pub(super) checked: Option<bool>,
}

impl CellView {
    pub(super) fn text_for_bind(&self, editing_available: bool) -> Cow<'_, str> {
        if self.is_null && !self.auto_filled && editing_available && self.inline_editable {
            Cow::Owned(editable_null_sentinel())
        } else {
            Cow::Borrowed(&self.display_text)
        }
    }

    pub(super) fn from_preview(preview: &crate::ui::row_object::CellPreview) -> Self {
        Self {
            display_text: preview_to_display_text(preview),
            is_null: false,
            inline_editable: false,
            auto_filled: false,
            checked: None,
        }
    }
}

pub(super) fn cell_view(value: &Value, column: &ColumnInfo) -> CellView {
    let is_null = matches!(value, Value::Null);
    let auto_filled = column.is_auto_increment || column.is_generated;
    CellView {
        display_text: if is_null && auto_filled {
            auto_filled_sentinel()
        } else {
            value_to_display_text(value)
        },
        is_null,
        inline_editable: super::presentation::cell_allows_inline_edit(column, value),
        auto_filled,
        checked: match value {
            Value::Bool(checked) => Some(*checked),
            Value::Int(1) if column.data_type.eq_ignore_ascii_case("bit(1)") => Some(true),
            Value::Int(0) if column.data_type.eq_ignore_ascii_case("bit(1)") => Some(false),
            _ => None,
        },
    }
}

fn value_to_text(value: &Value, cap: impl Fn(&str) -> String) -> String {
    match value {
        Value::Null => readonly_null_sentinel(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Text(s) => cap(s),
        // A NUL byte survives UTF-8 decoding (it's a valid codepoint)
        // but is a strong signal the column really is binary, not
        // text that happens to be stored as bytes -- keep the byte
        // count for that case instead of displaying invisible NULs.
        Value::Bytes(b) => match std::str::from_utf8(b) {
            Ok(s) if !s.contains('\0') => cap(s),
            _ => format!("<{} bytes>", b.len()),
        },
        Value::Date(d) => d.format("%Y-%m-%d").to_string(),
        Value::Time(t) => t.format("%H:%M:%S").to_string(),
        Value::DateTime(dt) => dt.format("%Y-%m-%d %H:%M:%S%.f").to_string(),
        Value::TimestampTz(ts) => ts.format("%Y-%m-%d %H:%M:%S%:z").to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Uuid(u) => u.to_string(),
        Value::Json(j) => cap(&j.to_string()),
        Value::Undecodable(type_name) => format!("<undecodable {type_name}>"),
    }
}

pub fn value_to_display_text(value: &Value) -> String {
    value_to_text(value, truncate_for_display)
}

pub(crate) fn preview_to_display_text(preview: &crate::ui::row_object::CellPreview) -> String {
    let total = crate::tr!("{n} bytes total").replace("{n}", &preview.byte_count.to_string());
    match &preview.value {
        Value::Text(text) => format!("{text}… ({total})"),
        Value::Bytes(bytes) => {
            let head = bytes
                .iter()
                .take(16)
                .map(|byte| format!("{byte:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            format!("{head}… ({total})")
        }
        other => value_to_display_text(other),
    }
}

pub(crate) fn value_to_full_edit_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        other => value_to_text(other, ToString::to_string),
    }
}

pub(super) fn value_is_inline_editable(value: &Value) -> bool {
    !matches!(value, Value::Bytes(_) | Value::Undecodable(_))
}

pub(super) fn truncate_for_display(s: &str) -> String {
    if s.len() < DISPLAY_TEXT_BYTES_THRESHOLD {
        return s.to_string();
    }
    let mut cut = s.len();
    for (i, (byte_idx, _)) in s.char_indices().enumerate() {
        if i >= DISPLAY_TEXT_MAX_CHARS {
            cut = byte_idx;
            break;
        }
    }
    if cut >= s.len() {
        return s.to_string();
    }
    let head = &s[..cut];
    let remaining = s[cut..].chars().count();
    format!("{head}… (+{remaining} more chars)")
}

#[derive(Debug)]
pub(super) struct EditSnapshot {
    pub position: u32,
    pub original: String,
    /// Primary-key values of the row the editor opened on. A refresh or
    /// a sort replaces the store's contents, so the position alone stops
    /// identifying that row and a commit would land on whichever row now
    /// sits there.
    pub row_key: Vec<Value>,
}

pub(super) trait WidgetDataKey: 'static {
    type Value: 'static;

    fn quark() -> glib::Quark;
}

pub(super) struct WidgetSlot<K: WidgetDataKey> {
    _key: PhantomData<K>,
}

impl<K: WidgetDataKey> WidgetSlot<K> {
    const fn new() -> Self {
        Self { _key: PhantomData }
    }

    pub(super) fn set(&self, widget: &impl IsA<gtk4::Widget>, value: K::Value) {
        unsafe { widget.set_qdata(K::quark(), value) };
    }

    pub(super) fn take(&self, widget: &impl IsA<gtk4::Widget>) -> Option<K::Value> {
        unsafe { widget.steal_qdata::<K::Value>(K::quark()) }
    }
}

impl<K: WidgetDataKey> WidgetSlot<K>
where
    K::Value: Clone,
{
    pub(super) fn cloned(&self, widget: &impl IsA<gtk4::Widget>) -> Option<K::Value> {
        unsafe { widget.qdata::<K::Value>(K::quark()).map(|p| p.as_ref().clone()) }
    }
}

impl<K: WidgetDataKey> WidgetSlot<K>
where
    K::Value: Copy,
{
    pub(super) fn get(&self, widget: &impl IsA<gtk4::Widget>) -> Option<K::Value> {
        unsafe { widget.qdata::<K::Value>(K::quark()).map(|p| *p.as_ref()) }
    }
}

macro_rules! define_widget_slot {
    ($slot:ident, $key:ident, $value:ty, $quark:literal) => {
        pub(super) enum $key {}

        impl WidgetDataKey for $key {
            type Value = $value;

            fn quark() -> glib::Quark {
                static QUARK: OnceLock<glib::Quark> = OnceLock::new();
                *QUARK.get_or_init(|| glib::Quark::from_str($quark))
            }
        }

        pub(super) const $slot: WidgetSlot<$key> = WidgetSlot::new();
    };
}

define_widget_slot!(POSITION_SLOT, PositionKey, u32, "tp-position");
define_widget_slot!(SNAPSHOT_SLOT, SnapshotKey, EditSnapshot, "tp-snapshot");
define_widget_slot!(ROW_KEY_SLOT, RowKeyKey, Vec<Value>, "tp-row-key");
define_widget_slot!(COLUMN_SLOT, ColumnKey, usize, "tp-column");
define_widget_slot!(SUPPRESS_SLOT, SuppressKey, bool, "tp-suppress-toggle");
define_widget_slot!(POPOVER_SLOT, PopoverKey, gtk4::Popover, "tp-popover");
define_widget_slot!(PREEDIT_SLOT, PreeditKey, bool, "tp-preedit-active");
define_widget_slot!(FULL_EDIT_TEXT_SLOT, FullEditTextKey, String, "tp-full-edit-text");
define_widget_slot!(IS_NULL_SLOT, IsNullKey, bool, "tp-cell-is-null");

pub fn focused_cell_identity(widget: &impl IsA<gtk4::Widget>) -> Option<(u32, usize, Vec<Value>)> {
    let root = widget.root()?;
    let window = root.dynamic_cast::<gtk4::Window>().ok()?;
    let focused = gtk4::prelude::GtkWindowExt::focus(&window)?;
    let position = POSITION_SLOT.get(&focused)?;
    let column = COLUMN_SLOT.get(&focused)?;
    let row_key = ROW_KEY_SLOT.cloned(&focused).unwrap_or_default();
    Some((position, column, row_key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata(data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: "value".into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn display_text_primitive_variants() {
        assert_eq!(value_to_display_text(&Value::Null), "NULL");
        assert_eq!(value_to_display_text(&Value::Bool(true)), "true");
        assert_eq!(value_to_display_text(&Value::Int(42)), "42");
        assert_eq!(value_to_display_text(&Value::Text("hello".into())), "hello");
        assert_eq!(value_to_display_text(&Value::Bytes(vec![0u8; 16])), "<16 bytes>");
    }

    #[test]
    fn display_text_shows_valid_utf8_bytes_as_text() {
        assert_eq!(
            value_to_display_text(&Value::Bytes(b"hello world".to_vec())),
            "hello world"
        );
    }

    #[test]
    fn display_text_keeps_invalid_utf8_bytes_as_a_byte_count() {
        assert_eq!(
            value_to_display_text(&Value::Bytes(vec![0xFF, 0xFE, 0x00, 0x01])),
            "<4 bytes>"
        );
    }

    #[test]
    fn display_text_keeps_bytes_with_an_embedded_nul_as_a_byte_count() {
        assert_eq!(value_to_display_text(&Value::Bytes(b"ab\0cd".to_vec())), "<5 bytes>");
    }

    #[test]
    fn display_text_shows_empty_bytes_as_empty_text() {
        assert_eq!(value_to_display_text(&Value::Bytes(Vec::new())), "");
    }

    #[test]
    fn binary_bytes_are_not_inline_editable() {
        assert!(!value_is_inline_editable(&Value::Bytes(vec![0xFF, 0xFE, 0x00, 0x01])));
        assert!(!value_is_inline_editable(&Value::Bytes(b"hello world".to_vec())));
        assert!(!value_is_inline_editable(&Value::Bytes(Vec::new())));
        assert!(value_is_inline_editable(&Value::Text("hello".into())));
        assert!(value_is_inline_editable(&Value::Null));
        assert!(value_is_inline_editable(&Value::Int(1)));
    }

    #[test]
    fn an_undecodable_cell_is_shown_distinctly_from_null_and_is_not_editable() {
        let value = Value::Undecodable("NUMERIC".into());
        assert_eq!(value_to_display_text(&value), "<undecodable NUMERIC>");
        assert_ne!(value_to_display_text(&value), value_to_display_text(&Value::Null));
        assert!(!value_is_inline_editable(&value));
    }

    #[test]
    fn bind_text_for_an_undecodable_cell_in_an_editable_column_stays_display_text() {
        let value = Value::Undecodable("NUMERIC".into());
        let view = cell_view(&value, &metadata("NUMERIC"));
        assert!(!view.inline_editable);
        assert_eq!(view.text_for_bind(true), "<undecodable NUMERIC>");
        assert_ne!(view.text_for_bind(true), editable_null_sentinel());
    }

    #[test]
    fn a_text_value_that_looks_like_the_null_marker_is_text_and_not_null() {
        let text = Value::Text(editable_null_sentinel());
        let view = cell_view(&text, &metadata("text"));
        assert!(!view.is_null);
        assert!(view.inline_editable);
        assert_eq!(view.text_for_bind(true), editable_null_sentinel());
        assert!(cell_view(&Value::Null, &metadata("text")).is_null);
    }

    #[test]
    fn bind_text_for_bytes_in_an_editable_column_stays_display_text() {
        let binary = Value::Bytes(vec![0xFF, 0xFE, 0x00, 0x01]);
        assert_eq!(cell_view(&binary, &metadata("text")).text_for_bind(true), "<4 bytes>");
        let utf8 = Value::Bytes(b"hello world".to_vec());
        assert_eq!(cell_view(&utf8, &metadata("text")).text_for_bind(true), "hello world");
        assert_eq!(
            cell_view(&Value::Text("hello".into()), &metadata("text")).text_for_bind(true),
            "hello"
        );
    }

    #[test]
    fn cell_view_keeps_null_distinct_from_text_and_obeys_column_editability() {
        let text_column = metadata("text");
        let null = cell_view(&Value::Null, &text_column);
        assert!(null.is_null);
        assert!(null.inline_editable);
        assert_eq!(null.text_for_bind(true), "<NULL>");
        assert_eq!(null.text_for_bind(false), "NULL");
        let text_null = cell_view(&Value::Text("NULL".into()), &text_column);
        assert!(!text_null.is_null);
        assert_eq!(text_null.text_for_bind(true), "NULL");

        let mut protected_column = text_column;
        protected_column.primary_key = true;
        assert!(!cell_view(&Value::Null, &protected_column).inline_editable);
    }

    #[test]
    fn cell_view_keeps_server_generated_null_and_preview_display_semantics() {
        let mut generated_column = metadata("text");
        generated_column.is_generated = true;
        let generated = cell_view(&Value::Null, &generated_column);
        assert_eq!(generated.text_for_bind(true), "(auto)");
        assert_eq!(generated.text_for_bind(false), "(auto)");

        let preview = crate::ui::row_object::CellPreview {
            value: Value::Text("sample".into()),
            byte_count: 9000,
        };
        let view = CellView::from_preview(&preview);
        assert!(!view.inline_editable);
        assert_eq!(view.text_for_bind(true), "sample… (9000 bytes total)");
    }

    #[test]
    fn cell_view_maps_only_boolean_and_bit_one_values_to_checkbox_states() {
        let boolean = metadata("boolean");
        assert_eq!(cell_view(&Value::Bool(true), &boolean).checked, Some(true));
        assert_eq!(cell_view(&Value::Bool(false), &boolean).checked, Some(false));
        assert_eq!(cell_view(&Value::Int(1), &boolean).checked, None);

        let bit = metadata("BIT(1)");
        assert_eq!(cell_view(&Value::Int(1), &bit).checked, Some(true));
        assert_eq!(cell_view(&Value::Int(0), &bit).checked, Some(false));
        assert_eq!(cell_view(&Value::Int(2), &bit).checked, None);
        assert_eq!(cell_view(&Value::Null, &bit).checked, None);
    }

    #[test]
    fn display_text_temporal_variants() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).unwrap();
        assert_eq!(value_to_display_text(&Value::Date(date)), "2026-04-26");

        let time = chrono::NaiveTime::from_hms_opt(14, 30, 0).unwrap();
        assert_eq!(value_to_display_text(&Value::Time(time)), "14:30:00");

        let datetime = chrono::NaiveDateTime::new(date, time);
        assert_eq!(value_to_display_text(&Value::DateTime(datetime)), "2026-04-26 14:30:00");
        let fractional = datetime + chrono::Duration::milliseconds(10);
        assert_eq!(
            value_to_display_text(&Value::DateTime(fractional)),
            "2026-04-26 14:30:00.010"
        );

        let tz = chrono::DateTime::<chrono::Utc>::from_naive_utc_and_offset(datetime, chrono::Utc);
        assert_eq!(
            value_to_display_text(&Value::TimestampTz(tz)),
            "2026-04-26 14:30:00+00:00"
        );
    }

    #[test]
    fn display_text_extended_variants() {
        let dec: rust_decimal::Decimal = "1234.56789".parse().unwrap();
        assert_eq!(value_to_display_text(&Value::Decimal(dec)), "1234.56789");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(
            value_to_display_text(&Value::Uuid(id)),
            "550e8400-e29b-41d4-a716-446655440000"
        );

        let json = serde_json::json!({"a": 1, "b": [2, 3]});
        let text = value_to_display_text(&Value::Json(json));
        assert!(text.contains("\"a\":1"));
    }

    #[test]
    fn truncate_short_text_passes_through() {
        let s = "hello world";
        assert_eq!(truncate_for_display(s), "hello world");
    }

    #[test]
    fn truncate_caps_long_text_at_char_boundary() {
        let s = "a".repeat(100_000);
        let out = truncate_for_display(&s);
        assert!(out.starts_with(&"a".repeat(10_000)));
        assert!(out.contains("more chars"));
        assert!(out.len() < 10_500);
    }

    #[test]
    fn the_truncation_limits_are_forty_thousand_bytes_and_ten_thousand_chars() {
        assert_eq!(DISPLAY_TEXT_MAX_CHARS, 10_000);
        assert_eq!(DISPLAY_TEXT_BYTES_THRESHOLD, 40_000);
    }

    #[test]
    fn truncate_passes_through_text_one_byte_under_the_threshold() {
        let s = "a".repeat(DISPLAY_TEXT_BYTES_THRESHOLD - 1);
        assert_eq!(truncate_for_display(&s), s);
    }

    #[test]
    fn truncate_cuts_text_exactly_at_the_byte_threshold() {
        let s = "a".repeat(DISPLAY_TEXT_BYTES_THRESHOLD);
        let out = truncate_for_display(&s);
        let expected_remaining = DISPLAY_TEXT_BYTES_THRESHOLD - DISPLAY_TEXT_MAX_CHARS;
        assert_eq!(
            out,
            format!(
                "{}… (+{expected_remaining} more chars)",
                "a".repeat(DISPLAY_TEXT_MAX_CHARS)
            )
        );
    }

    #[test]
    fn truncate_handles_multibyte_boundary() {
        let s = "🦀".repeat(30_000);
        let out = truncate_for_display(&s);
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
        assert!(out.contains("more chars"));
    }

    #[test]
    fn a_large_binary_value_shows_its_exact_byte_count() {
        let mut blob = vec![0xFFu8; 100_001];
        blob[0] = 0x00;
        assert_eq!(value_to_display_text(&Value::Bytes(blob)), "<100001 bytes>");
        assert_eq!(value_to_display_text(&Value::Bytes(vec![0x00])), "<1 bytes>");
    }

    #[test]
    fn value_preview_shows_sample_and_original_byte_count() {
        let preview = crate::ui::row_object::CellPreview {
            value: Value::Text("sample".into()),
            byte_count: 9000,
        };
        assert_eq!(preview_to_display_text(&preview), "sample… (9000 bytes total)");
    }

    #[test]
    fn utf8_bytes_past_the_display_limit_mark_the_truncation_with_the_exact_remainder() {
        let text = "b".repeat(DISPLAY_TEXT_BYTES_THRESHOLD + 7);
        let display = value_to_display_text(&Value::Bytes(text.into_bytes()));
        let remaining = DISPLAY_TEXT_BYTES_THRESHOLD + 7 - DISPLAY_TEXT_MAX_CHARS;
        assert_eq!(
            display,
            format!("{}… (+{remaining} more chars)", "b".repeat(DISPLAY_TEXT_MAX_CHARS))
        );
    }

    #[test]
    fn display_text_truncates_huge_text_value() {
        let huge = "x".repeat(1_000_000);
        let display = value_to_display_text(&Value::Text(huge));
        assert!(display.len() < 100_000);
        assert!(display.contains("more chars"));
    }

    #[test]
    fn grid_widget_data_keys_use_distinct_quarks() {
        let quarks = [
            PositionKey::quark(),
            SnapshotKey::quark(),
            RowKeyKey::quark(),
            ColumnKey::quark(),
            SuppressKey::quark(),
            PopoverKey::quark(),
            PreeditKey::quark(),
            FullEditTextKey::quark(),
            IsNullKey::quark(),
        ];
        for (index, quark) in quarks.iter().enumerate() {
            for (other_index, other) in quarks.iter().enumerate() {
                if index != other_index {
                    assert_ne!(quark, other);
                }
            }
        }
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn typed_widget_slots_round_trip_and_keep_same_value_types_apart() {
        gtk4::init().unwrap();
        let label = gtk4::Label::new(None);
        POSITION_SLOT.set(&label, 7);
        COLUMN_SLOT.set(&label, 3);
        assert_eq!(POSITION_SLOT.get(&label), Some(7));
        assert_eq!(COLUMN_SLOT.get(&label), Some(3));

        SUPPRESS_SLOT.set(&label, true);
        PREEDIT_SLOT.set(&label, false);
        IS_NULL_SLOT.set(&label, true);
        assert_eq!(SUPPRESS_SLOT.get(&label), Some(true));
        assert_eq!(PREEDIT_SLOT.get(&label), Some(false));
        assert_eq!(IS_NULL_SLOT.get(&label), Some(true));

        let row_key = vec![Value::Int(11), Value::Text("pk".into())];
        ROW_KEY_SLOT.set(&label, row_key.clone());
        assert_eq!(ROW_KEY_SLOT.cloned(&label), Some(row_key));

        FULL_EDIT_TEXT_SLOT.set(&label, "pending".into());
        assert_eq!(FULL_EDIT_TEXT_SLOT.cloned(&label), Some("pending".into()));
        assert_eq!(FULL_EDIT_TEXT_SLOT.take(&label), Some("pending".into()));
        assert_eq!(FULL_EDIT_TEXT_SLOT.cloned(&label), None);

        assert_eq!(POSITION_SLOT.take(&label), Some(7));
        assert_eq!(POSITION_SLOT.get(&label), None);
        assert_eq!(COLUMN_SLOT.get(&label), Some(3));
        assert_eq!(SUPPRESS_SLOT.get(&label), Some(true));
        assert_eq!(PREEDIT_SLOT.get(&label), Some(false));
        assert_eq!(IS_NULL_SLOT.get(&label), Some(true));
    }
}
