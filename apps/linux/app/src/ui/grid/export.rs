//! All result surfaces share the core serializers.
pub(super) use tablepro_core::export::{render_in_clause, render_json, render_markdown, render_tsv, row_to_json};

pub(super) fn render_csv(
    columns: &[tablepro_core::ColumnInfo],
    rows: &[Vec<tablepro_core::Value>],
    with_headers: bool,
) -> String {
    let null_marker = tablepro_core::export::unique_csv_null_marker(rows);
    tablepro_core::export::render_csv(
        columns,
        rows,
        &tablepro_core::export::CsvOptions {
            header_row: with_headers,
            null_to_empty: false,
            null_marker: Some(null_marker),
            ..Default::default()
        },
    )
}

#[cfg(test)]
mod tests {
    use relm4::gtk;
    use relm4::gtk::prelude::*;
    use tablepro_core::{ColumnInfo, Value};

    use super::render_csv;

    #[test]
    fn clipboard_csv_keeps_null_empty_enum_and_marker_labels_distinct() {
        let columns = vec![ColumnInfo {
            name: "status".into(),
            data_type: "sample_schema.status_kind".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: Some(tablepro_core::QualifiedTypeName {
                schema: "sample_schema".into(),
                name: "status_kind".into(),
            }),
            domain_type: None,
        }];
        let rows = vec![
            vec![Value::Text("NULL".into())],
            vec![Value::Text(String::new())],
            vec![Value::Null],
            vec![Value::Text("\\N".into())],
            vec![Value::Text("\\NN".into())],
            vec![Value::Text("=1+1".into())],
        ];

        assert_eq!(
            render_csv(&columns, &rows, false),
            "NULL\n\"\"\n\\NNN\n\\N\n\\NN\n\"'=1+1\"\n"
        );
        assert_eq!(
            render_csv(&columns, &rows, true),
            "status\nNULL\n\"\"\n\\NNN\n\\N\n\\NN\n\"'=1+1\"\n"
        );
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn clipboard_csv_is_published_and_read_back_exactly() {
        gtk::init().unwrap();
        let columns = vec![ColumnInfo {
            name: "status".into(),
            data_type: "sample_schema.status_kind".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: Some(tablepro_core::QualifiedTypeName {
                schema: "sample_schema".into(),
                name: "status_kind".into(),
            }),
            domain_type: None,
        }];
        let rows = vec![
            vec![Value::Text("NULL".into())],
            vec![Value::Text(String::new())],
            vec![Value::Null],
            vec![Value::Text("\\N".into())],
            vec![Value::Text("\\NN".into())],
            vec![Value::Text("=1+1".into())],
        ];
        let csv = render_csv(&columns, &rows, false);
        let window = gtk::Window::new();
        let clipboard = window.clipboard();
        clipboard.set_text(&csv);

        let received = gtk::glib::MainContext::default()
            .block_on(clipboard.read_text_future())
            .unwrap()
            .unwrap();
        assert_eq!(received.as_str(), csv);

        let options = tablepro_core::import::CsvImportOptions {
            delimiter: tablepro_core::export::CsvDelimiter::Comma,
            has_header: false,
            null_marker: tablepro_core::export::unique_csv_null_marker(&rows),
        };
        let sheet = tablepro_core::import::read_csv(received.as_bytes(), &options, None).unwrap();
        let pasted = sheet
            .rows
            .iter()
            .enumerate()
            .map(|(index, row)| {
                tablepro_core::import::row_to_values(row, &[Some(0)], &columns, &options, index + 1)
                    .unwrap()
                    .remove(0)
            })
            .collect::<Vec<_>>();
        assert_eq!(
            pasted,
            vec![
                Value::Text("NULL".into()),
                Value::Text(String::new()),
                Value::Null,
                Value::Text("\\N".into()),
                Value::Text("\\NN".into()),
                Value::Text("'=1+1".into()),
            ]
        );
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn clipboard_tsv_is_published_and_keeps_null_and_formula_cells_distinct() {
        gtk::init().unwrap();
        let columns = vec![ColumnInfo {
            name: "status".into(),
            data_type: "sample_schema.status_kind".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: Some(tablepro_core::QualifiedTypeName {
                schema: "sample_schema".into(),
                name: "status_kind".into(),
            }),
            domain_type: None,
        }];
        let rows = vec![
            vec![Value::Text("NULL".into())],
            vec![Value::Text(String::new())],
            vec![Value::Null],
            vec![Value::Text("\\N".into())],
            vec![Value::Text("\\NN".into())],
            vec![Value::Text("=1+1".into())],
        ];
        let tsv = tablepro_core::export::render_tsv(&columns, &rows, false);
        let window = gtk::Window::new();
        let clipboard = window.clipboard();
        clipboard.set_text(&tsv);

        let received = gtk::glib::MainContext::default()
            .block_on(clipboard.read_text_future())
            .unwrap()
            .unwrap();
        assert_eq!(received.as_str(), tsv);

        let options = tablepro_core::import::CsvImportOptions {
            delimiter: tablepro_core::export::CsvDelimiter::Tab,
            has_header: false,
            null_marker: tablepro_core::export::unique_csv_null_marker(&rows),
        };
        let sheet = tablepro_core::import::read_csv(received.as_bytes(), &options, None).unwrap();
        let pasted = sheet
            .rows
            .iter()
            .enumerate()
            .map(|(index, row)| {
                tablepro_core::import::row_to_values(row, &[Some(0)], &columns, &options, index + 1)
                    .unwrap()
                    .remove(0)
            })
            .collect::<Vec<_>>();
        assert_eq!(
            pasted,
            vec![
                Value::Text("NULL".into()),
                Value::Text(String::new()),
                Value::Null,
                Value::Text("\\N".into()),
                Value::Text("\\NN".into()),
                Value::Text("'=1+1".into()),
            ]
        );
    }
}
