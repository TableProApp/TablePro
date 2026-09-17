use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_core::ColumnInfo;
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{CsvImportOptions, CsvSheet, MAX_PREVIEW_ROWS, read_csv, suggest_mapping};

/// The most a CSV may be before the import refuses it.
///
/// Every row becomes an INSERT in one transaction, so the file's size
/// decides how much the app holds at once. Refusing is better than a
/// window that stops painting halfway through a file nobody meant to
/// open.
pub const MAX_CSV_FILE_BYTES: u64 = 64 * 1024 * 1024;

/// How many values from the file each mapping row shows, so the user
/// can see they picked the field they meant.
const SAMPLE_VALUES: usize = 3;

pub struct ImportCsvDialog {
    root: adw::Dialog,
    schema: Option<String>,
    table: String,
    bytes: Vec<u8>,
    columns: Vec<ColumnInfo>,
    sheet: CsvSheet,
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
    pub columns: Vec<ColumnInfo>,
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
    pub columns: Vec<ColumnInfo>,
    /// One entry per table column: the CSV field it takes, or `None`
    /// for a column the user set to Skip.
    pub mapping: Vec<Option<usize>>,
    pub options: CsvImportOptions,
    pub bytes: Vec<u8>,
}

#[derive(Debug)]
pub enum ImportCsvDialogOutput {
    Import(Box<CsvImport>),
    ShowToast(String),
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
        import_button.connect_clicked(move |_| sender_for_import.input(ImportCsvDialogInput::Import));
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
            .title(crate::i18n::gettext("First row is a header"))
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

        let summary = gtk::Label::builder().xalign(0.0).wrap(true).build();
        summary.add_css_class("dim-label");
        let summary_group = adw::PreferencesGroup::new();
        summary_group.add(&summary);
        page.add(&summary_group);

        toolbar.set_content(Some(&page));
        root.set_child(Some(&toolbar));

        let sender_for_header = sender.clone();
        header_row.connect_active_notify(move |_| sender_for_header.input(ImportCsvDialogInput::Reread));
        let sender_for_delimiter = sender.clone();
        delimiter_row.connect_selected_notify(move |_| sender_for_delimiter.input(ImportCsvDialogInput::Reread));
        let sender_for_null = sender.clone();
        null_row.connect_changed(move |_| sender_for_null.input(ImportCsvDialogInput::MappingChanged));

        let mut model = ImportCsvDialog {
            root: root.clone(),
            schema: init.schema,
            table: init.table,
            bytes: init.bytes,
            columns: init.columns,
            sheet: CsvSheet::default(),
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
            }
            ImportCsvDialogInput::Import => {
                let mapping = self.mapping();
                if mapping.iter().all(Option::is_none) {
                    let _ = sender.output(ImportCsvDialogOutput::ShowToast(crate::i18n::gettext(
                        "Every column is set to Skip, so there is nothing to import.",
                    )));
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
                self.import_button.set_sensitive(true);
            }
            Err(error) => {
                self.sheet = CsvSheet::default();
                self.import_button.set_sensitive(false);
                let _ = sender.output(ImportCsvDialogOutput::ShowToast(error.to_string()));
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
            .chain(self.sheet.headers.iter().cloned())
            .collect();
        let choice_refs: Vec<&str> = choices.iter().map(String::as_str).collect();
        let suggested = suggest_mapping(&self.sheet.headers, &self.columns);

        for (column, field) in self.columns.iter().zip(&suggested) {
            let row = adw::ComboRow::builder()
                .title(glib::markup_escape_text(&column.name))
                .model(&gtk::StringList::new(&choice_refs))
                .build();
            row.set_selected(field.map_or(0, |index| index as u32 + 1));
            let sender = sender.clone();
            row.connect_selected_notify(move |_| sender.input(ImportCsvDialogInput::MappingChanged));
            self.mapping_group.add(&row);
            self.mapping_rows.borrow_mut().push(row);
        }
        self.show_samples();
    }

    /// Show what the mapped field actually holds, under each column.
    fn show_samples(&self) {
        for (row, field) in self.mapping_rows.borrow().iter().zip(self.mapping()) {
            row.set_subtitle(&match field {
                Some(index) => sample_text(&self.sheet, index, &self.options),
                None => crate::i18n::gettext("Uses the column's own default"),
            });
        }
    }

    fn show_summary(&self) {
        let text = match self.sheet.headers.is_empty() {
            true => crate::i18n::gettext("The file could not be read."),
            false if self.sheet.truncated => crate::i18n::gettext_f(
                "{fields} fields. Showing the first {rows} rows; the whole file is imported.",
                &[
                    ("fields", &self.sheet.headers.len().to_string()),
                    ("rows", &self.sheet.rows.len().to_string()),
                ],
            ),
            false => crate::i18n::ngettext_f(
                "{fields} fields, {rows} row.",
                "{fields} fields, {rows} rows.",
                self.sheet.rows.len() as u32,
                &[
                    ("fields", &self.sheet.headers.len().to_string()),
                    ("rows", &self.sheet.rows.len().to_string()),
                ],
            ),
        };
        self.summary.set_label(&text);
    }

    fn mapping(&self) -> Vec<Option<usize>> {
        self.mapping_rows
            .borrow()
            .iter()
            .map(|row| match row.selected() {
                0 => None,
                index => Some(index as usize - 1),
            })
            .collect()
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
}

#[cfg(test)]
mod dialog_tests {
    use super::*;
    use tablepro_core::column::{ColumnDefault, ColumnType};

    /// The dialog only reads a column's name: the type decides what a
    /// value parses into, which happens after the dialog is gone.
    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::unknown(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
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

        // "Column 1" and "Column 2" match no table column, so every row
        // falls back to Skip and the header line reads as data.
        assert_eq!(dialog.model().mapping(), vec![None, None, None]);
    }

    #[gtk4::test]
    fn a_file_that_is_not_csv_leaves_the_import_button_off() {
        let dialog = ImportCsvDialog::builder().launch(ImportCsvDialogInit {
            schema: None,
            table: "people".to_owned(),
            columns: vec![column("id")],
            bytes: Vec::new(),
        });

        crate::test_support::drain_main_context();

        assert!(!dialog.model().import_button.is_sensitive());
    }
}
