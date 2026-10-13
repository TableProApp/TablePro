/// A bool column never gets here: it is a check button, not an editor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CellEditorKind {
    Text,
    Date,
    Int,
    Float,
    Json,
}

pub(super) fn classify_editor_kind(data_type: &str) -> CellEditorKind {
    // JSON before the numbers: a contrived type name can match both.
    if is_date_type(data_type) {
        CellEditorKind::Date
    } else if is_json_type(data_type) {
        CellEditorKind::Json
    } else if is_int_type(data_type) {
        CellEditorKind::Int
    } else if is_float_type(data_type) {
        CellEditorKind::Float
    } else {
        CellEditorKind::Text
    }
}

pub(super) fn is_bool_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(dt.as_str(), "bool" | "boolean" | "bit" | "tinyint(1)")
}

/// A calendar picks a day and nothing else, so a type with a time in it
/// stays on the text editor.
fn is_date_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    dt == "date" || (dt.starts_with("date") && !dt.contains("datetime") && !dt.contains("time"))
}

fn is_int_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(
        dt.as_str(),
        "int"
            | "int2"
            | "int4"
            | "int8"
            | "integer"
            | "smallint"
            | "bigint"
            | "tinyint"
            | "mediumint"
            | "serial"
            | "bigserial"
            | "smallserial"
    ) || dt.starts_with("int(")
        || dt.starts_with("integer(")
        || dt.starts_with("smallint(")
        || dt.starts_with("bigint(")
        || dt.starts_with("mediumint(")
}

/// Decimal, numeric and money are left out because `SqlDecimal` keeps
/// every digit and `GtkSpinButton` holds an f64.
fn is_float_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(dt.as_str(), "float" | "double" | "real" | "double precision") || dt.starts_with("float(")
}

fn is_json_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    dt.contains("json")
}
