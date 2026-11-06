use tablepro_core::import::{CsvImportOptions, CsvSheet, ImportError};

use crate::i18n::{gettext, gettext_f, ngettext_f, pgettext_f};
use crate::ui::format::format_thousands;

// Enough to tell the field is the one meant, few enough to fit a subtitle.
pub(super) const SAMPLE_VALUES: usize = 3;

pub(crate) fn import_error_text(error: &ImportError) -> String {
    match error {
        ImportError::NotUtf8 { offset } => gettext_f(
            "The file isn't UTF-8 text from byte {offset} on. Save it as UTF-8 and import it again.",
            &[("offset", &offset.to_string())],
        ),
        ImportError::Malformed { line: Some(line) } => gettext_f(
            "The file couldn't be read as CSV at line {line}.",
            &[("line", &line.to_string())],
        ),
        ImportError::Malformed { line: None } => gettext("The file couldn't be read as CSV."),
        ImportError::NoColumns => gettext("The file has no columns."),
        ImportError::TooManyFields { line, limit } => gettext_f(
            "Line {line} has more than {limit} fields, more than any table holds. Check the delimiter.",
            &[("line", &line.to_string()), ("limit", &limit.to_string())],
        ),
    }
}

pub(super) fn summary_text(fields: usize, rows: usize, truncated: bool) -> String {
    let fields = ngettext_f(
        "{n} field",
        "{n} fields",
        fields,
        &[("n", &format_thousands(fields as u64))],
    );
    let rows = ngettext_f("{n} row", "{n} rows", rows, &[("n", &format_thousands(rows as u64))]);
    let counts: [(&str, &str); 2] = [("fields", &fields), ("rows", &rows)];
    match truncated {
        // Translators: {fields} is "3 fields" and {rows} is "50 rows", each already translated.
        true => pgettext_f(
            "CSV preview summary",
            "{fields}. Showing the first {rows}; the whole file is imported.",
            &counts,
        ),
        // Translators: {fields} is "3 fields" and {rows} is "2 rows", each already translated.
        false => pgettext_f("CSV preview summary", "{fields}, {rows}.", &counts),
    }
}

// A file without a header names no field, so the mapping offers it by position.
pub(super) fn field_label(index: usize, header: &str) -> String {
    match header.trim().is_empty() {
        true => gettext_f("Column {n}", &[("n", &(index + 1).to_string())]),
        false => header.to_owned(),
    }
}

pub(super) fn sample_text(sheet: &CsvSheet, field: usize, options: &CsvImportOptions) -> String {
    let values: Vec<String> = sheet
        .rows
        .iter()
        .filter_map(|row| row.get(field))
        .take(SAMPLE_VALUES)
        .map(|text| match text == &options.null_marker {
            true => gettext("NULL"),
            false => text.clone(),
        })
        .collect();
    match values.is_empty() {
        true => gettext("No values in the file"),
        false => values.join(" · "),
    }
}

pub(super) fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(schema) => format!("{schema}.{table}"),
        None => table.to_owned(),
    }
}
