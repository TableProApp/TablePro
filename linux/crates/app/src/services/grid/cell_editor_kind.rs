use tablepro_core::column::{ColumnKind, IntegerKind};
use tablepro_core::edit::{EditText, ReadOnlyReason, read_only_reason};

use super::{CellLock, GridColumn};

/// Past this many bytes a value opens in the details editor: a one-line
/// entry lays all of it out at once and shows almost none.
pub const INLINE_EDIT_MAX_BYTES: usize = 4096;

/// Past this many bytes a value does not open for editing at all: the
/// details editor lays out every line on the GTK thread and would stall.
pub const EDIT_MAX_BYTES: usize = 1_000_000;

/// The editor a cell opens with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellEditorKind {
    Inline {
        accepts_line_breaks: bool,
        purpose: TextPurpose,
    },
    Toggle,
    Details(DetailsEditor),
    ReadOnly(CellLock),
}

/// The on-screen keyboard an inline editor asks for, as `gtk::InputPurpose`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextPurpose {
    FreeForm,
    Number,
    Digits,
}

/// The value editor of the details pane a cell opens in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetailsEditor {
    Text,
    Json,
    Xml,
    Date,
}

impl CellEditorKind {
    pub fn for_cell(column: &GridColumn, editability: Result<(), CellLock>) -> Self {
        if let Err(lock) = editability {
            return Self::ReadOnly(lock);
        }
        let kind = &column.value_type().kind;
        let inline = |purpose| Self::Inline {
            accepts_line_breaks: kind.accepts_line_breaks(),
            purpose,
        };
        match kind {
            ColumnKind::Bool(_) => Self::Toggle,
            ColumnKind::Json { .. } => Self::Details(DetailsEditor::Json),
            ColumnKind::Xml => Self::Details(DetailsEditor::Xml),
            ColumnKind::Date => Self::Details(DetailsEditor::Date),
            ColumnKind::Integer(IntegerKind { signed: false, .. }) => inline(TextPurpose::Digits),
            ColumnKind::Integer(_) | ColumnKind::Float(_) | ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => {
                inline(TextPurpose::Number)
            }
            ColumnKind::Text { .. }
            | ColumnKind::Enum { .. }
            | ColumnKind::Uuid
            | ColumnKind::Network(_)
            | ColumnKind::Interval
            | ColumnKind::Time { .. }
            | ColumnKind::Timestamp { .. }
            | ColumnKind::BitString { .. }
            | ColumnKind::Other => inline(TextPurpose::FreeForm),
            ColumnKind::Bytes { .. }
            | ColumnKind::Spatial
            | ColumnKind::Array { .. }
            | ColumnKind::Variant
            | ColumnKind::Composite => Self::ReadOnly(CellLock::Value(
                read_only_reason(kind).unwrap_or(ReadOnlyReason::Composite),
            )),
        }
    }

    /// The editor for this value: none for a value with no text form,
    /// and the details editor for text a one-line entry would mangle.
    pub fn for_text(self, text: &EditText) -> Self {
        match (self, text) {
            (_, EditText::ReadOnly(reason)) => Self::ReadOnly(CellLock::Value(*reason)),
            (Self::Inline { .. }, EditText::Editable(text))
                if text.contains(['\n', '\r']) || text.len() > INLINE_EDIT_MAX_BYTES =>
            {
                Self::Details(DetailsEditor::Text)
            }
            (kind, EditText::Editable(_)) => kind,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{
        BoolStorage, ColumnKind, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, TemporalZone, TextLength,
        TimeRange,
    };
    use tablepro_core::edit::{EditText, ReadOnlyReason};

    use super::{CellEditorKind, DetailsEditor, INLINE_EDIT_MAX_BYTES, TextPurpose};
    use crate::services::grid::CellLock;
    use crate::services::grid::test_columns::grid_of_kind;

    fn integer(signed: bool) -> ColumnKind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed,
        })
    }

    const NUMBER: CellEditorKind = CellEditorKind::Inline {
        accepts_line_breaks: false,
        purpose: TextPurpose::Number,
    };

    fn free(accepts_line_breaks: bool) -> CellEditorKind {
        CellEditorKind::Inline {
            accepts_line_breaks,
            purpose: TextPurpose::FreeForm,
        }
    }

    fn assert_editors(cases: Vec<(ColumnKind, CellEditorKind)>) {
        for (kind, expected) in cases {
            assert_eq!(
                CellEditorKind::for_cell(&grid_of_kind("c", kind.clone()), Ok(())),
                expected,
                "{kind:?}"
            );
        }
    }

    #[test]
    fn booleans_toggle_and_numbers_take_a_number_keyboard() {
        assert_editors(vec![
            (ColumnKind::Bool(BoolStorage::Native), CellEditorKind::Toggle),
            (ColumnKind::Bool(BoolStorage::Integer), CellEditorKind::Toggle),
            (
                integer(false),
                CellEditorKind::Inline {
                    accepts_line_breaks: false,
                    purpose: TextPurpose::Digits,
                },
            ),
            (integer(true), NUMBER),
            (ColumnKind::Float(FloatWidth::F64), NUMBER),
            (
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(2),
                },
                NUMBER,
            ),
            (ColumnKind::Money { scale: Some(2) }, NUMBER),
        ]);
    }

    #[test]
    fn text_like_kinds_edit_inline_and_only_text_takes_line_breaks() {
        assert_editors(vec![
            (
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
                free(true),
            ),
            (
                ColumnKind::Enum {
                    labels: vec!["a".to_owned()],
                    multiple: false,
                },
                free(false),
            ),
            (ColumnKind::Uuid, free(false)),
            (ColumnKind::Network(NetworkFamily::Inet), free(false)),
            (ColumnKind::Interval, free(false)),
            (
                ColumnKind::Time {
                    fractional_digits: None,
                    with_offset: false,
                    range: TimeRange::TimeOfDay,
                },
                free(false),
            ),
            (
                ColumnKind::Timestamp {
                    fractional_digits: Some(6),
                    zone: TemporalZone::Offset,
                },
                free(false),
            ),
            (
                ColumnKind::BitString {
                    length: Some(8),
                    varying: false,
                },
                free(false),
            ),
            (ColumnKind::Other, free(true)),
        ]);
    }

    #[test]
    fn documents_and_dates_open_their_editor_and_opaque_kinds_stay_read_only() {
        assert_editors(vec![
            (
                ColumnKind::Json { binary: true },
                CellEditorKind::Details(DetailsEditor::Json),
            ),
            (ColumnKind::Xml, CellEditorKind::Details(DetailsEditor::Xml)),
            (ColumnKind::Date, CellEditorKind::Details(DetailsEditor::Date)),
            (
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
                CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Bytes)),
            ),
            (
                ColumnKind::Spatial,
                CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Spatial)),
            ),
            (
                ColumnKind::Array {
                    element: Box::new(integer(true)),
                },
                CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Composite)),
            ),
            (
                ColumnKind::Variant,
                CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Variant)),
            ),
            (
                ColumnKind::Composite,
                CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Composite)),
            ),
        ]);
    }

    #[test]
    fn a_locked_cell_is_read_only_for_its_lock() {
        let text = grid_of_kind(
            "c",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        );
        for lock in [
            CellLock::Value(ReadOnlyReason::Undecodable),
            CellLock::KeyColumn,
            CellLock::Generated,
            CellLock::AutoIncrement,
            CellLock::UnkeyedRow,
            CellLock::ResultRow,
            CellLock::ReadOnlySession,
            CellLock::PendingDelete,
            CellLock::Unaddressable,
        ] {
            assert_eq!(
                CellEditorKind::for_cell(&text, Err(lock)),
                CellEditorKind::ReadOnly(lock)
            );
        }
    }

    #[test]
    fn inline_escalates_to_multiline_for_line_breaks_and_4096_bytes() {
        let inline = free(true);
        let details = CellEditorKind::Details(DetailsEditor::Text);
        let editable = |text: String| EditText::Editable(text);

        assert_eq!(inline.for_text(&editable("one line".to_owned())), inline);
        assert_eq!(inline.for_text(&editable("two\nlines".to_owned())), details);
        assert_eq!(inline.for_text(&editable("carriage\rreturn".to_owned())), details);
        assert_eq!(inline.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES))), inline);
        assert_eq!(
            inline.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES + 1))),
            details
        );
        let date = CellEditorKind::Details(DetailsEditor::Date);
        assert_eq!(
            date.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES + 1))),
            date,
            "only the one-line editor gives way"
        );
        assert_eq!(
            inline.for_text(&EditText::ReadOnly(ReadOnlyReason::Bytes)),
            CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Bytes))
        );
    }
}
