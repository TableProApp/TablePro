use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{
    CsvImportOptions, CsvSheet, ImportColumn, ImportError, MAX_PREVIEW_ROWS, read_csv, suggest_mapping,
};

use crate::runtime::DeliverInput;

/// How many values from the file each mapping row shows, so the user
/// can see they picked the field they meant.
const SAMPLE_VALUES: usize = 3;

pub struct ImportCsvDialog {
    root: adw::Dialog,
    schema: Option<String>,
    table: String,
    bytes: Vec<u8>,
    columns: Vec<ImportColumn>,
    sheet: CsvSheet,
    /// Why the file could not be read under the options as they stand.
    read_error: Option<String>,
    options: CsvImportOptions,
    /// One row per table column, in column order. The selected index is
    /// 0 for "Skip" and the field number plus one otherwise.
    mapping_rows: Rc<RefCell<Vec<adw::ComboRow>>>,
    mapping_group: adw::PreferencesGroup,
    summary: gtk::Label,
    delimiter_row: adw::ComboRow,
    header_row: adw::SwitchRow,
    null_row: adw::EntryRow,
    import_button: gtk::Button,
}

pub struct ImportCsvDialogInit {
    pub schema: Option<String>,
    pub table: String,
    pub columns: Vec<ImportColumn>,
    pub bytes: Vec<u8>,
}

#[derive(Debug)]
pub enum ImportCsvDialogInput {
    /// The delimiter, header switch or NULL marker moved, so the file
    /// has to be read again.
    Reread,
    /// A mapping combo moved, so the samples have to be redrawn.
    MappingChanged,
    Import,
}

/// Everything an import needs, once the mapping dialog has settled it.
///
/// It travels as one value because every part of it is a decision the
/// dialog made together with the others: the mapping only means
/// anything against these columns, read under these options.
#[derive(Debug, Clone)]
pub struct CsvImport {
    pub schema: Option<String>,
    pub table: String,
    pub columns: Vec<ImportColumn>,
    /// One entry per table column: the CSV field it takes, or `None`
    /// for a column the user set to Skip or the server fills.
    pub mapping: Vec<Option<usize>>,
    pub options: CsvImportOptions,
    pub bytes: Vec<u8>,
}

#[derive(Debug)]
pub enum ImportCsvDialogOutput {
    Import(Box<CsvImport>),
}

impl Component for ImportCsvDialog {
    type Init = ImportCsvDialogInit;
    type Input = ImportCsvDialogInput;
    type Output = ImportCsvDialogOutput;
    type CommandOutput = ();
    type Root = adw::Dialog;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::Dialog::builder()
            .title(crate::i18n::gettext("Import CSV"))
            .content_width(560)
            .content_height(680)
            .build()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::builder().show_end_title_buttons(true).build();
        let subtitle = qualified(init.schema.as_deref(), &init.table);
        header.set_title_widget(Some(&adw::WindowTitle::new(
            &crate::i18n::gettext("Import CSV"),
            &subtitle,
        )));
        let import_button = gtk::Button::builder().label(crate::i18n::gettext("Import")).build();
        import_button.add_css_class("suggested-action");
        let sender_for_import = sender.clone();
        import_button.connect_clicked(move |_| sender_for_import.deliver(ImportCsvDialogInput::Import));
        header.pack_end(&import_button);
        toolbar.add_top_bar(&header);

        let page = adw::PreferencesPage::new();

        let file_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("File"))
            .build();
        let delimiter_row = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Delimiter"))
            .model(&gtk::StringList::new(&[
                &crate::i18n::gettext("Comma"),
                &crate::i18n::gettext("Semicolon"),
                &crate::i18n::gettext("Tab"),
                &crate::i18n::gettext("Pipe"),
            ]))
            .build();
        let header_row = adw::SwitchRow::builder()
            .title(crate::i18n::gettext("First Row Is a Header"))
            .subtitle(crate::i18n::gettext(
                "Its values name the fields instead of being imported.",
            ))
            .active(true)
            .build();
        let null_row = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Text that means NULL"))
            .build();
        file_group.add(&delimiter_row);
        file_group.add(&header_row);
        file_group.add(&null_row);
        page.add(&file_group);

        let mapping_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Columns"))
            .description(crate::i18n::gettext(
                "Each table column takes one field from the file. A column set to Skip keeps its own default.",
            ))
            .build();
        page.add(&mapping_group);

        // Problems with the file are told here, inside the dialog that
        // covers the window a toast would go to, and long enough to read.
        let summary = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .selectable(true)
            .build();
        let summary_group = adw::PreferencesGroup::new();
        summary_group.add(&summary);
        page.add(&summary_group);

        toolbar.set_content(Some(&page));
        root.set_child(Some(&toolbar));

        let sender_for_header = sender.clone();
        header_row.connect_active_notify(move |_| sender_for_header.deliver(ImportCsvDialogInput::Reread));
        let sender_for_delimiter = sender.clone();
        delimiter_row.connect_selected_notify(move |_| sender_for_delimiter.deliver(ImportCsvDialogInput::Reread));
        let sender_for_null = sender.clone();
        null_row.connect_changed(move |_| sender_for_null.deliver(ImportCsvDialogInput::MappingChanged));

        let mut model = ImportCsvDialog {
            root: root.clone(),
            schema: init.schema,
            table: init.table,
            bytes: init.bytes,
            columns: init.columns,
            sheet: CsvSheet::default(),
            read_error: None,
            options: CsvImportOptions::default(),
            mapping_rows: Rc::new(RefCell::new(Vec::new())),
            mapping_group,
            summary,
            delimiter_row,
            header_row,
            null_row,
            import_button,
        };
        model.reread(&sender);

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            ImportCsvDialogInput::Reread => self.reread(&sender),
            ImportCsvDialogInput::MappingChanged => {
                self.options = self.read_options();
                self.show_samples();
                self.show_summary();
            }
            ImportCsvDialogInput::Import => {
                let mapping = self.mapping();
                if self.blocker().is_some() {
                    return;
                }
                let _ = sender.output(ImportCsvDialogOutput::Import(Box::new(CsvImport {
                    schema: self.schema.clone(),
                    table: self.table.clone(),
                    columns: self.columns.clone(),
                    mapping,
                    options: self.read_options(),
                    bytes: std::mem::take(&mut self.bytes),
                })));
                self.root.close();
            }
        }
    }
}

impl ImportCsvDialog {
    pub fn dialog(&self) -> &adw::Dialog {
        &self.root
    }

    fn read_options(&self) -> CsvImportOptions {
        CsvImportOptions {
            delimiter: match self.delimiter_row.selected() {
                1 => CsvDelimiter::Semicolon,
                2 => CsvDelimiter::Tab,
                3 => CsvDelimiter::Pipe,
                _ => CsvDelimiter::Comma,
            },
            has_header: self.header_row.is_active(),
            null_marker: self.null_row.text().to_string(),
        }
    }

    /// Read the file again under the options as they stand and rebuild
    /// the mapping rows, which are named after the file's own fields.
    fn reread(&mut self, sender: &ComponentSender<Self>) {
        self.options = self.read_options();
        match read_csv(&self.bytes, &self.options, Some(MAX_PREVIEW_ROWS)) {
            Ok(sheet) => {
                self.sheet = sheet;
                self.read_error = None;
            }
            Err(error) => {
                self.sheet = CsvSheet::default();
                self.read_error = Some(import_error_text(&error));
            }
        }
        self.rebuild_mapping(sender);
        self.show_summary();
    }

    fn rebuild_mapping(&mut self, sender: &ComponentSender<Self>) {
        for row in self.mapping_rows.borrow_mut().drain(..) {
            self.mapping_group.remove(&row);
        }

        let choices: Vec<String> = std::iter::once(crate::i18n::gettext("Skip"))
            .chain(
                self.sheet
                    .headers
                    .iter()
                    .enumerate()
                    .map(|(index, header)| field_label(index, header)),
            )
            .collect();
        let choice_refs: Vec<&str> = choices.iter().map(String::as_str).collect();
        // One list for every row: each row keeps its own selection, and
        // a wide file is held once rather than once per column.
        let choices = gtk::StringList::new(&choice_refs);
        let suggested = suggest_mapping(&self.sheet.headers, &self.columns);

        for (column, field) in self.columns.iter().zip(&suggested) {
            let row = adw::ComboRow::builder()
                .title(glib::markup_escape_text(&column.info.name))
                .model(&choices)
                .sensitive(!column.server_filled)
                .build();
            row.set_selected(field.map_or(0, |index| index as u32 + 1));
            let sender = sender.clone();
            row.connect_selected_notify(move |_| sender.deliver(ImportCsvDialogInput::MappingChanged));
            self.mapping_group.add(&row);
            self.mapping_rows.borrow_mut().push(row);
        }
        self.show_samples();
    }

    /// Show what the mapped field actually holds, under each column.
    fn show_samples(&self) {
        let rows = self.mapping_rows.borrow();
        for ((row, field), column) in rows.iter().zip(self.mapping()).zip(&self.columns) {
            row.set_subtitle(&match field {
                _ if column.server_filled => crate::i18n::gettext("The database fills this column"),
                Some(index) => sample_text(&self.sheet, index, &self.options),
                None => crate::i18n::gettext("Uses the column's own default"),
            });
        }
    }

    /// What stands in the way of importing, if anything.
    fn blocker(&self) -> Option<String> {
        if let Some(error) = &self.read_error {
            return Some(error.clone());
        }
        if self.sheet.rows.is_empty() {
            return Some(crate::i18n::gettext("The file has no rows to import."));
        }
        if self.mapping().iter().all(Option::is_none) {
            return Some(crate::i18n::gettext(
                "Every column is set to Skip. Pick a field for at least one column to import.",
            ));
        }
        None
    }

    fn show_summary(&self) {
        let blocker = self.blocker();
        self.import_button.set_sensitive(blocker.is_none());
        let text = match blocker {
            Some(blocker) => {
                self.summary.remove_css_class("dim-label");
                self.summary.add_css_class("error");
                self.summary.set_label(&blocker);
                return;
            }
            None if self.sheet.truncated => crate::i18n::gettext_f(
                "{fields} fields. Showing the first {rows} rows; the whole file is imported.",
                &[
                    ("fields", &self.sheet.headers.len().to_string()),
                    ("rows", &self.sheet.rows.len().to_string()),
                ],
            ),
            None => crate::i18n::ngettext_f(
                "{fields} fields, {rows} row.",
                "{fields} fields, {rows} rows.",
                self.sheet.rows.len() as u32,
                &[
                    ("fields", &self.sheet.headers.len().to_string()),
                    ("rows", &self.sheet.rows.len().to_string()),
                ],
            ),
        };
        self.summary.remove_css_class("error");
        self.summary.add_css_class("dim-label");
        self.summary.set_label(&text);
    }

    fn mapping(&self) -> Vec<Option<usize>> {
        self.mapping_rows
            .borrow()
            .iter()
            .zip(&self.columns)
            .map(|(row, column)| match row.selected() {
                _ if column.server_filled => None,
                0 => None,
                index => Some(index as usize - 1),
            })
            .collect()
    }
}

/// What went wrong reading the file, in words the user can act on.
pub(crate) fn import_error_text(error: &ImportError) -> String {
    match error {
        ImportError::NotUtf8 { offset } => crate::i18n::gettext_f(
            "The file isn't UTF-8 text from byte {offset} on. Save it as UTF-8 and import it again.",
            &[("offset", &offset.to_string())],
        ),
        ImportError::Malformed { line: Some(line) } => crate::i18n::gettext_f(
            "The file couldn't be read as CSV at line {line}.",
            &[("line", &line.to_string())],
        ),
        ImportError::Malformed { line: None } => crate::i18n::gettext("The file couldn't be read as CSV."),
        ImportError::NoColumns => crate::i18n::gettext("The file has no columns."),
        ImportError::TooManyFields { line, limit } => crate::i18n::gettext_f(
            "Line {line} has more than {limit} fields, more than any table holds. Check the delimiter.",
            &[("line", &line.to_string()), ("limit", &limit.to_string())],
        ),
    }
}

/// A field as the mapping offers it: its header, or its position when
/// the file names none.
fn field_label(index: usize, header: &str) -> String {
    match header.trim().is_empty() {
        true => crate::i18n::gettext_f("Column {n}", &[("n", &(index + 1).to_string())]),
        false => header.to_owned(),
    }
}

/// The first few values of one field, as one line.
fn sample_text(sheet: &CsvSheet, field: usize, options: &CsvImportOptions) -> String {
    let values: Vec<String> = sheet
        .rows
        .iter()
        .filter_map(|row| row.get(field))
        .take(SAMPLE_VALUES)
        .map(|text| match text == &options.null_marker {
            true => crate::i18n::gettext("NULL"),
            false => text.clone(),
        })
        .collect();
    match values.is_empty() {
        true => crate::i18n::gettext("No values in the file"),
        false => values.join(" · "),
    }
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(schema) => format!("{schema}.{table}"),
        None => table.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}

#[cfg(test)]
mod dialog_tests {
    use super::*;
    use tablepro_core::ColumnInfo;
    use tablepro_core::column::{ColumnDefault, ColumnType};

    /// The dialog only reads a column's name: the type decides what a
    /// value parses into, which happens after the dialog is gone.
    fn column(name: &str) -> ImportColumn {
        ImportColumn {
            info: ColumnInfo {
                name: name.to_owned(),
                column_type: ColumnType::unknown(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            server_filled: false,
        }
    }

    fn launch(csv: &str) -> relm4::component::Connector<ImportCsvDialog> {
        ImportCsvDialog::builder().launch(ImportCsvDialogInit {
            schema: Some("public".to_owned()),
            table: "people".to_owned(),
            columns: vec![column("id"), column("name"), column("nickname")],
            bytes: csv.as_bytes().to_vec(),
        })
    }

    #[gtk4::test]
    fn a_column_named_in_the_file_starts_mapped_to_its_field() {
        let dialog = launch("name,id\nada,1\n");

        crate::test_support::drain_main_context();

        // id is the file's second field, name its first, and nothing in
        // the file is called nickname.
        assert_eq!(dialog.model().mapping(), vec![Some(1), Some(0), None]);
    }

    #[gtk4::test]
    fn an_unmapped_column_says_it_keeps_its_default() {
        let dialog = launch("name,id\nada,1\n");
        crate::test_support::drain_main_context();

        let subtitles: Vec<String> = dialog
            .model()
            .mapping_rows
            .borrow()
            .iter()
            .map(|row| row.subtitle().unwrap_or_default().to_string())
            .collect();

        assert_eq!(subtitles[0], "1");
        assert_eq!(subtitles[1], "ada");
        assert_eq!(subtitles[2], "Uses the column's own default");
    }

    #[gtk4::test]
    fn turning_the_header_switch_off_remaps_against_positional_names() {
        let dialog = launch("name,id\nada,1\n");
        crate::test_support::drain_main_context();
        assert_eq!(dialog.model().mapping(), vec![Some(1), Some(0), None]);

        dialog.model().header_row.set_active(false);
        crate::test_support::drain_main_context();

        // Fields with no name match no table column, so every row falls
        // back to Skip and the header line reads as data.
        assert_eq!(dialog.model().mapping(), vec![None, None, None]);
        let offered: Vec<String> = (0..3)
            .map(|index| {
                dialog.model().mapping_rows.borrow()[0]
                    .model()
                    .and_downcast::<gtk::StringList>()
                    .and_then(|list| list.string(index))
                    .map(|text| text.to_string())
                    .unwrap_or_default()
            })
            .collect();
        assert_eq!(offered, vec!["Skip", "Column 1", "Column 2"]);
    }

    #[gtk4::test]
    fn a_column_the_server_fills_cannot_take_a_field() {
        let mut id = column("id");
        id.server_filled = true;
        let dialog = ImportCsvDialog::builder().launch(ImportCsvDialogInit {
            schema: None,
            table: "people".to_owned(),
            columns: vec![id, column("name")],
            bytes: b"id,name\n1,ada\n".to_vec(),
        });
        crate::test_support::drain_main_context();

        let rows = dialog.model().mapping_rows.borrow().clone();

        assert_eq!(dialog.model().mapping(), vec![None, Some(1)]);
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
        let dialog = ImportCsvDialog::builder().launch(ImportCsvDialogInit {
            schema: None,
            table: "people".to_owned(),
            columns: vec![column("id")],
            bytes: b"id\n\xff\n".to_vec(),
        });

        crate::test_support::drain_main_context();

        assert!(!dialog.model().import_button.is_sensitive());
        assert_eq!(
            dialog.model().summary.label().as_str(),
            "The file isn't UTF-8 text from byte 3 on. Save it as UTF-8 and import it again."
        );
        assert!(dialog.model().summary.has_css_class("error"));
    }

    #[gtk4::test]
    fn every_column_set_to_skip_turns_the_import_button_off() {
        let dialog = launch("name,id\nada,1\n");
        crate::test_support::drain_main_context();
        assert!(dialog.model().import_button.is_sensitive());

        for row in dialog.model().mapping_rows.borrow().iter() {
            row.set_selected(0);
        }
        crate::test_support::drain_main_context();

        assert!(!dialog.model().import_button.is_sensitive());
        assert_eq!(
            dialog.model().summary.label().as_str(),
            "Every column is set to Skip. Pick a field for at least one column to import."
        );
    }

    #[gtk4::test]
    fn a_file_with_only_a_header_has_nothing_to_import() {
        let dialog = launch("name,id\n");
        crate::test_support::drain_main_context();

        assert!(!dialog.model().import_button.is_sensitive());
        assert_eq!(
            dialog.model().summary.label().as_str(),
            "The file has no rows to import."
        );
    }
}
