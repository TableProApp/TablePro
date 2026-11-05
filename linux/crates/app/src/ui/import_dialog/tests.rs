use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ColumnInfo;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{CsvImportOptions, CsvSheet, ImportColumn, ImportError};

use super::preview_text::SAMPLE_VALUES;
use super::*;
use crate::runtime::AppRuntime;
use crate::test_support::{OwnedWindow, descendants, drain_main_context, drop_focus, test_runtime, wait_until};

const WAIT: Duration = Duration::from_secs(30);

// Long enough for a replaced read's reply to come back after the current one.
const STRAGGLER: Duration = Duration::from_millis(200);

const PEOPLE: &[u8] = b"name,id\nada,1\n";

fn sheet() -> CsvSheet {
    CsvSheet {
        headers: vec!["id".to_owned(), "name".to_owned()],
        rows: vec![
            vec!["1".to_owned(), "ada".to_owned()],
            vec!["2".to_owned(), String::new()],
            vec!["3".to_owned(), "grace".to_owned()],
            vec!["4".to_owned(), "alan".to_owned()],
        ],
        truncated: false,
    }
}

// The dialog reads only a column's name; the type matters once the import runs.
fn column(name: &str) -> ImportColumn {
    ImportColumn {
        info: ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::unknown(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        },
        server_filled: false,
    }
}

fn people() -> Vec<ImportColumn> {
    vec![column("id"), column("name"), column("nickname")]
}

struct Harness {
    runtime: AppRuntime,
}

impl Harness {
    fn new() -> Self {
        crate::register_test_resources();
        Self {
            runtime: test_runtime(),
        }
    }

    fn open(&self, columns: Vec<ImportColumn>, csv: &[u8]) -> ImportCsvDialog {
        self.open_bytes(columns, Arc::from(csv))
    }

    fn open_bytes(&self, columns: Vec<ImportColumn>, bytes: Arc<[u8]>) -> ImportCsvDialog {
        ImportCsvDialog::new(ImportCsvDialogInit {
            schema: Some("public".to_owned()),
            table: "people".to_owned(),
            columns,
            bytes,
            tasks: self.runtime.tasks(),
        })
    }

    fn loaded(&self, columns: Vec<ImportColumn>, csv: &[u8]) -> ImportCsvDialog {
        let dialog = self.open(columns, csv);
        settle(&dialog);
        dialog
    }
}

fn settle(dialog: &ImportCsvDialog) {
    wait_until(WAIT, || !dialog.reading()).expect("the preview read to land");
}

fn summary(dialog: &ImportCsvDialog) -> String {
    dialog.imp().summary.label().to_string()
}

fn rows(dialog: &ImportCsvDialog) -> Vec<adw::ComboRow> {
    dialog.imp().mapping_rows.borrow().clone()
}

fn subtitles(dialog: &ImportCsvDialog) -> Vec<String> {
    rows(dialog)
        .iter()
        .map(|row| row.subtitle().unwrap_or_default().to_string())
        .collect()
}

fn offered(row: &adw::ComboRow) -> Vec<String> {
    let Some(list) = row.model().and_downcast::<gtk::StringList>() else {
        return Vec::new();
    };
    (0..list.n_items())
        .filter_map(|index| list.string(index))
        .map(|text| text.to_string())
        .collect()
}

#[test]
fn a_sample_shows_the_first_few_values_of_its_field() {
    assert_eq!(
        sample_text(&sheet(), 0, &CsvImportOptions::default()),
        "1 · 2 · 3",
        "a sample past {SAMPLE_VALUES} values would not fit a subtitle"
    );
}

#[test]
fn a_sample_names_the_values_that_would_import_as_null() {
    assert_eq!(
        sample_text(&sheet(), 1, &CsvImportOptions::default()),
        "ada · NULL · grace"
    );
}

#[test]
fn a_field_the_file_never_fills_says_so_rather_than_showing_nothing() {
    assert_eq!(
        sample_text(&CsvSheet::default(), 0, &CsvImportOptions::default()),
        "No values in the file"
    );
}

#[test]
fn a_table_in_a_schema_is_named_with_it() {
    assert_eq!(qualified(Some("public"), "orders"), "public.orders");
    assert_eq!(qualified(None, "orders"), "orders");
}

#[test]
fn a_file_the_csv_reader_refused_says_where_in_the_apps_words() {
    assert_eq!(
        import_error_text(&ImportError::Malformed { line: Some(12) }),
        "The file couldn't be read as CSV at line 12."
    );
    assert_eq!(
        import_error_text(&ImportError::Malformed { line: None }),
        "The file couldn't be read as CSV."
    );
}

#[test]
fn a_field_with_no_name_is_offered_by_its_position() {
    assert_eq!(field_label(0, ""), "Column 1");
    assert_eq!(field_label(2, "  "), "Column 3");
    assert_eq!(field_label(1, "city"), "city");
}

#[test]
fn the_summary_counts_fields_and_rows_each_in_its_own_plural() {
    assert_eq!(summary_text(1, 1, false), "1 field, 1 row.");
    assert_eq!(summary_text(2, 2, false), "2 fields, 2 rows.");
    assert_eq!(summary_text(1, 2, false), "1 field, 2 rows.");
}

#[test]
fn a_truncated_preview_says_the_whole_file_is_imported() {
    assert_eq!(
        summary_text(2, 50, true),
        "2 fields. Showing the first 50 rows; the whole file is imported."
    );
}

#[gtk4::test]
fn the_file_is_read_off_the_gtk_thread_and_import_waits_for_it() {
    let harness = Harness::new();
    let dialog = harness.open(people(), PEOPLE);
    let imported = Rc::new(Cell::new(false));
    let flag = imported.clone();
    dialog.connect_import(move |_, _| flag.set(true));

    // Nothing has run the main context yet, so a read on the GTK thread would already have landed.
    assert_eq!(summary(&dialog), "Reading the file…");
    assert!(dialog.imp().summary.has_css_class("dim-label"));
    assert!(!dialog.imp().import_button.is_sensitive());
    assert!(rows(&dialog).is_empty());
    dialog.imp().import_button.emit_clicked();
    assert!(!imported.get(), "an import went out before the file was read");

    settle(&dialog);

    assert_eq!(dialog.mapping(), vec![Some(1), Some(0), None]);
    assert!(dialog.imp().import_button.is_sensitive());
    assert_eq!(summary(&dialog), "2 fields, 1 row.");
}

#[gtk4::test]
fn only_the_last_of_two_header_changes_is_shown() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);
    let shown = Rc::new(RefCell::new(Vec::new()));
    let log = shown.clone();
    dialog
        .imp()
        .summary
        .connect_label_notify(move |label| log.borrow_mut().push(label.label().to_string()));

    dialog.imp().header_row.set_active(false);
    dialog.imp().header_row.set_active(true);
    settle(&dialog);
    std::thread::sleep(STRAGGLER);
    drain_main_context();

    assert_eq!(dialog.mapping(), vec![Some(1), Some(0), None]);
    let shown = shown.borrow();
    assert_eq!(shown.last().map(String::as_str), Some("2 fields, 1 row."));
    assert!(
        shown
            .iter()
            .all(|text| text == "Reading the file…" || text == "2 fields, 1 row."),
        "the read the second change replaced was shown: {shown:?}"
    );
}

#[gtk4::test]
fn a_dialog_closed_during_its_read_is_freed_and_fills_nothing() {
    let harness = Harness::new();
    let window = OwnedWindow::presented(adw::Window::new());
    let dialog = harness.open(people(), PEOPLE);
    dialog.present(Some(&*window));
    assert!(dialog.reading());
    let group = dialog.imp().mapping_group.get();
    let weak = dialog.downgrade();

    drop_focus(&*window);
    dialog.close();
    drop(dialog);
    wait_until(WAIT, || weak.upgrade().is_none()).expect("the closed dialog to be freed");
    std::thread::sleep(STRAGGLER);
    drain_main_context();

    assert!(weak.upgrade().is_none(), "the read kept its dialog alive");
    assert!(
        !descendants(&group).iter().any(|widget| widget.is::<adw::ComboRow>()),
        "a read filled the mapping after its dialog closed"
    );
}

#[gtk4::test]
fn import_hands_over_the_mapping_and_options_and_closes() {
    let harness = Harness::new();
    let window = OwnedWindow::presented(adw::Window::new());
    let bytes: Arc<[u8]> = Arc::from(PEOPLE);
    let dialog = harness.open_bytes(people(), bytes.clone());
    dialog.present(Some(&*window));
    settle(&dialog);
    let received = Rc::new(RefCell::new(None));
    let slot = received.clone();
    dialog.connect_import(move |_, import| {
        slot.replace(Some(import));
    });
    let closed = Rc::new(Cell::new(false));
    let flag = closed.clone();
    dialog.connect_closed(move |_| flag.set(true));

    dialog.imp().null_row.set_text("-");
    dialog.imp().import_button.emit_clicked();

    wait_until(WAIT, || closed.get()).expect("the dialog to close");
    let import = received.take().expect("the import");
    assert_eq!(import.schema.as_deref(), Some("public"));
    assert_eq!(import.table, "people");
    assert_eq!(import.mapping, vec![Some(1), Some(0), None]);
    assert_eq!(
        import.options,
        CsvImportOptions {
            delimiter: CsvDelimiter::Comma,
            has_header: true,
            null_marker: "-".to_owned(),
        }
    );
    assert!(Arc::ptr_eq(&import.bytes, &bytes), "the file was copied");
    drop(import);
    assert_eq!(Arc::strong_count(&bytes), 1, "the closed dialog kept the file");
}

#[gtk4::test]
fn a_null_marker_change_redraws_the_samples_without_reading_again() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);

    dialog.imp().null_row.set_text("ada");

    assert!(!dialog.reading(), "the file was read again for a NULL marker");
    assert_eq!(subtitles(&dialog)[1], "NULL");
}

#[gtk4::test]
fn names_and_values_with_markup_characters_show_as_written() {
    let harness = Harness::new();
    let dialog = harness.loaded(vec![column("R&D <team>")], b"R&D <team>\nAT&T <b>\n");

    let rows = rows(&dialog);
    let row = rows.first().expect("a mapping row");

    assert!(!row.uses_markup());
    assert_eq!(row.title(), "R&D <team>");
    assert_eq!(row.subtitle().as_deref(), Some("AT&T <b>"));
}

#[gtk4::test]
fn a_column_named_in_the_file_starts_mapped_to_its_field() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);

    // id is the file's second field, name its first, and nothing in the file is called nickname.
    assert_eq!(dialog.mapping(), vec![Some(1), Some(0), None]);
}

#[gtk4::test]
fn an_unmapped_column_says_it_keeps_its_default() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);

    let subtitles = subtitles(&dialog);

    assert_eq!(subtitles[0], "1");
    assert_eq!(subtitles[1], "ada");
    assert_eq!(subtitles[2], "Uses the column's own default");
}

#[gtk4::test]
fn turning_the_header_switch_off_remaps_against_positional_names() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);
    assert_eq!(dialog.mapping(), vec![Some(1), Some(0), None]);

    dialog.imp().header_row.set_active(false);
    settle(&dialog);

    // Fields with no name match no table column, so every row falls back to Skip and the header line reads as data.
    assert_eq!(dialog.mapping(), vec![None, None, None]);
    assert_eq!(offered(&rows(&dialog)[0]), vec!["Skip", "Column 1", "Column 2"]);
}

#[gtk4::test]
fn a_column_the_server_fills_cannot_take_a_field() {
    let harness = Harness::new();
    let mut id = column("id");
    id.server_filled = true;
    let dialog = harness.loaded(vec![id, column("name")], b"id,name\n1,ada\n");

    let rows = rows(&dialog);

    assert_eq!(dialog.mapping(), vec![None, Some(1)]);
    assert!(
        !rows[0].is_sensitive(),
        "a field could be picked for a column the server fills"
    );
    assert_eq!(
        rows[0].subtitle().unwrap_or_default().as_str(),
        "The database fills this column"
    );
}

#[gtk4::test]
fn a_file_that_is_not_csv_leaves_the_import_button_off_and_says_why_in_the_dialog() {
    let harness = Harness::new();
    let dialog = harness.loaded(vec![column("id")], b"id\n\xff\n");

    assert!(!dialog.imp().import_button.is_sensitive());
    assert_eq!(
        summary(&dialog),
        "The file isn't UTF-8 text from byte 3 on. Save it as UTF-8 and import it again."
    );
    assert!(dialog.imp().summary.has_css_class("error"));
}

#[gtk4::test]
fn every_column_set_to_skip_turns_the_import_button_off() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), PEOPLE);
    assert!(dialog.imp().import_button.is_sensitive());

    for row in rows(&dialog) {
        row.set_selected(0);
    }

    assert!(!dialog.imp().import_button.is_sensitive());
    assert_eq!(
        summary(&dialog),
        "Every column is set to Skip. Pick a field for at least one column to import."
    );
}

#[gtk4::test]
fn a_file_with_only_a_header_has_nothing_to_import() {
    let harness = Harness::new();
    let dialog = harness.loaded(people(), b"name,id\n");

    assert!(!dialog.imp().import_button.is_sensitive());
    assert_eq!(summary(&dialog), "The file has no rows to import.");
}

#[gtk4::test]
fn a_long_file_shows_its_first_rows_and_says_the_rest_import_too() {
    let harness = Harness::new();
    let csv: String = std::iter::once("name,id\n".to_owned())
        .chain((0..=MAX_PREVIEW_ROWS).map(|index| format!("person {index},{index}\n")))
        .collect();

    let dialog = harness.loaded(people(), csv.as_bytes());

    assert_eq!(
        summary(&dialog),
        format!("2 fields. Showing the first {MAX_PREVIEW_ROWS} rows; the whole file is imported.")
    );
    assert!(dialog.imp().import_button.is_sensitive());
}
