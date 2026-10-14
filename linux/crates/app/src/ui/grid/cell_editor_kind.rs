use gtk4 as gtk;

use tablepro_core::ColumnInfo;
use tablepro_core::column::{BoolStorage, ColumnKind, IntegerKind};
use tablepro_core::edit::{EditText, ReadOnlyReason, read_only_reason};

use super::CellLock;

/// Past this many bytes a value opens in the multi-line editor: a
/// one-line entry lays all of it out at once and shows almost none.
pub const INLINE_EDIT_MAX_BYTES: usize = 4096;

/// The editor a cell opens with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellEditorKind {
    Toggle(BoolStorage),
    Inline {
        accepts_line_breaks: bool,
        purpose: gtk::InputPurpose,
    },
    Multiline {
        language: Option<&'static str>,
    },
    Calendar,
    ReadOnly(CellLock),
}

impl CellEditorKind {
    pub fn for_cell(column: &ColumnInfo, editability: Result<(), CellLock>) -> Self {
        if let Err(lock) = editability {
            return Self::ReadOnly(lock);
        }
        let kind = &column.column_type.kind;
        let inline = |purpose| Self::Inline {
            accepts_line_breaks: kind.accepts_line_breaks(),
            purpose,
        };
        match kind {
            ColumnKind::Bool(storage) => Self::Toggle(*storage),
            ColumnKind::Json { .. } => Self::Multiline { language: Some("json") },
            ColumnKind::Xml => Self::Multiline { language: Some("xml") },
            ColumnKind::Date => Self::Calendar,
            ColumnKind::Integer(IntegerKind { signed: false, .. }) => inline(gtk::InputPurpose::Digits),
            ColumnKind::Integer(_) | ColumnKind::Float(_) | ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => {
                inline(gtk::InputPurpose::Number)
            }
            ColumnKind::Text { .. }
            | ColumnKind::Enum { .. }
            | ColumnKind::Uuid
            | ColumnKind::Network(_)
            | ColumnKind::Interval
            | ColumnKind::Time { .. }
            | ColumnKind::Timestamp { .. }
            | ColumnKind::BitString { .. }
            | ColumnKind::Other => inline(gtk::InputPurpose::FreeForm),
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
    /// and the multi-line one for text a one-line entry would mangle.
    pub fn for_text(self, text: &EditText) -> Self {
        match (self, text) {
            (_, EditText::ReadOnly(reason)) => Self::ReadOnly(CellLock::Value(*reason)),
            (Self::Inline { .. }, EditText::Editable(text))
                if text.contains(['\n', '\r']) || text.len() > INLINE_EDIT_MAX_BYTES =>
            {
                Self::Multiline { language: None }
            }
            (kind, EditText::Editable(_)) => kind,
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use tablepro_core::ColumnInfo;
    use tablepro_core::column::{
        BoolStorage, ColumnDefault, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily,
        TemporalZone, TextLength, TimeRange,
    };
    use tablepro_core::edit::{EditText, ReadOnlyReason};

    use super::{CellEditorKind, INLINE_EDIT_MAX_BYTES};
    use crate::ui::grid::CellLock;

    fn column(kind: ColumnKind) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("t");
        column_type.kind = kind;
        ColumnInfo {
            name: "c".to_owned(),
            column_type,
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn integer(signed: bool) -> ColumnKind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed,
        })
    }

    #[test]
    fn editor_kind_for_cell_matrix() {
        let free = |accepts_line_breaks| CellEditorKind::Inline {
            accepts_line_breaks,
            purpose: gtk::InputPurpose::FreeForm,
        };
        let number = CellEditorKind::Inline {
            accepts_line_breaks: false,
            purpose: gtk::InputPurpose::Number,
        };
        let cases = [
            (
                ColumnKind::Bool(BoolStorage::Native),
                CellEditorKind::Toggle(BoolStorage::Native),
            ),
            (
                ColumnKind::Bool(BoolStorage::Integer),
                CellEditorKind::Toggle(BoolStorage::Integer),
            ),
            (
                integer(false),
                CellEditorKind::Inline {
                    accepts_line_breaks: false,
                    purpose: gtk::InputPurpose::Digits,
                },
            ),
            (integer(true), number),
            (ColumnKind::Float(FloatWidth::F64), number),
            (
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(2),
                },
                number,
            ),
            (ColumnKind::Money { scale: Some(2) }, number),
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
            (
                ColumnKind::Json { binary: true },
                CellEditorKind::Multiline { language: Some("json") },
            ),
            (ColumnKind::Xml, CellEditorKind::Multiline { language: Some("xml") }),
            (ColumnKind::Date, CellEditorKind::Calendar),
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
        ];
        for (kind, expected) in cases {
            assert_eq!(
                CellEditorKind::for_cell(&column(kind.clone()), Ok(())),
                expected,
                "{kind:?}"
            );
        }

        let text = column(ColumnKind::Text {
            length: TextLength::Unbounded,
        });
        for lock in [
            CellLock::Value(ReadOnlyReason::Undecodable),
            CellLock::KeyColumn,
            CellLock::Generated,
            CellLock::AutoIncrement,
            CellLock::UnkeyedRow,
            CellLock::ResultRow,
            CellLock::ReadOnlySession,
        ] {
            assert_eq!(
                CellEditorKind::for_cell(&text, Err(lock)),
                CellEditorKind::ReadOnly(lock)
            );
        }
    }

    #[test]
    fn inline_escalates_to_multiline_for_line_breaks_and_4096_bytes() {
        let inline = CellEditorKind::Inline {
            accepts_line_breaks: true,
            purpose: gtk::InputPurpose::FreeForm,
        };
        let multiline = CellEditorKind::Multiline { language: None };
        let editable = |text: String| EditText::Editable(text);

        assert_eq!(inline.for_text(&editable("one line".to_owned())), inline);
        assert_eq!(inline.for_text(&editable("two\nlines".to_owned())), multiline);
        assert_eq!(inline.for_text(&editable("carriage\rreturn".to_owned())), multiline);
        assert_eq!(inline.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES))), inline);
        assert_eq!(
            inline.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES + 1))),
            multiline
        );
        assert_eq!(
            CellEditorKind::Calendar.for_text(&editable("x".repeat(INLINE_EDIT_MAX_BYTES + 1))),
            CellEditorKind::Calendar,
            "only the one-line editor gives way"
        );
        assert_eq!(
            inline.for_text(&EditText::ReadOnly(ReadOnlyReason::Bytes)),
            CellEditorKind::ReadOnly(CellLock::Value(ReadOnlyReason::Bytes))
        );
    }
}
