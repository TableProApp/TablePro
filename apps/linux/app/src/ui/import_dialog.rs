use std::path::PathBuf;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{
    CsvFormat, CsvImportOptions, CsvSheet, INFER_SAMPLE_ROWS, MAX_PREVIEW_ROWS, infer_columns, read_csv,
    suggest_mapping,
};
use tablepro_core::sql_ddl::DraftColumn;
use tablepro_core::{ColumnInfo, sql_dialect};
use tokio_util::sync::CancellationToken;

/// Whether the rows go into a table that is already there, or into one
/// the import creates first.
pub(crate) enum ImportMode {
    ExistingTable { table: String, columns: Vec<ColumnInfo> },
    NewTable { driver_id: String, suggested_table: String },
}

/// What the app read from the file before it asked the user anything.
pub(crate) struct ImportRequest {
    pub schema: Option<String>,
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub format: CsvFormat,
    pub mode: ImportMode,
}

/// What the user settled on. The app re-reads the whole file with these
/// options; the dialog only ever read a preview.
#[derive(Debug, Clone)]
pub(crate) struct ImportChoice {
    pub schema: Option<String>,
    pub table: String,
    pub bytes: Vec<u8>,
    pub options: CsvImportOptions,
    pub mapping: Vec<Option<usize>>,
    pub columns: Vec<ColumnInfo>,
    /// The table to create first, when the import is making one. The
    /// CREATE is its own governed statement, run before any row.
    pub create: Option<Vec<DraftColumn>>,
}

const SKIP_LABEL: &str = "Skip";

pub(crate) fn present(
    parent: &adw::ApplicationWindow,
    request: ImportRequest,
    on_start: impl Fn(ImportChoice) + 'static,
) {
    let page = adw::PreferencesPage::new();
    let file = FileOptions::new(&request);
    page.add(&file.group);
    let columns = ColumnSection::new(&request);
    page.add(columns.group());
    let state = std::rc::Rc::new(State { request, file, columns });
    state.refresh();
    connect_refresh(&state);

    let start_button = gtk::Button::builder().label(crate::tr!("Import")).build();
    start_button.add_css_class("suggested-action");
    let dialog = build_dialog(&page, &start_button);
    let dialog_for_start = dialog.clone();
    start_button.connect_clicked(move |_| {
        let Some(choice) = state.choice() else {
            return;
        };
        dialog_for_start.close();
        on_start(choice);
    });
    dialog.present(Some(parent));
}

struct State {
    request: ImportRequest,
    file: FileOptions,
    columns: ColumnSection,
}

impl State {
    fn preview(&self) -> CsvSheet {
        read_csv(
            &self.request.bytes,
            &self.file.options(),
            Some(MAX_PREVIEW_ROWS.max(INFER_SAMPLE_ROWS)),
        )
        .unwrap_or_default()
    }

    fn refresh(&self) {
        self.columns.refresh(&self.preview(), &self.file.options());
    }

    /// The user's answer, or nothing when a name they typed cannot be an
    /// identifier. The rows say which; the import does not start.
    fn choice(&self) -> Option<ImportChoice> {
        let options = self.file.options();
        let (table, columns, mapping, create) = self.columns.resolve()?;
        Some(ImportChoice {
            schema: self.request.schema.clone(),
            table,
            bytes: self.request.bytes.clone(),
            options,
            mapping,
            columns,
            create,
        })
    }
}

fn connect_refresh(state: &std::rc::Rc<State>) {
    let for_delimiter = state.clone();
    state
        .file
        .delimiter
        .connect_selected_notify(move |_| for_delimiter.refresh());
    let for_header = state.clone();
    state.file.header.connect_active_notify(move |_| for_header.refresh());
}

struct FileOptions {
    group: adw::PreferencesGroup,
    delimiter: adw::ComboRow,
    header: adw::SwitchRow,
    null_marker: adw::EntryRow,
}

impl FileOptions {
    fn new(request: &ImportRequest) -> Self {
        let group = adw::PreferencesGroup::builder()
            .title(crate::tr!("File"))
            .description(request.path.display().to_string())
            .build();
        let delimiter = delimiter_row(request.format.delimiter);
        let header = adw::SwitchRow::builder()
            .title(crate::tr!("First row names the columns"))
            .active(request.format.has_header)
            .build();
        let null_marker = adw::EntryRow::builder()
            .title(crate::tr!("Text that means NULL"))
            .build();
        group.add(&delimiter);
        group.add(&header);
        group.add(&null_marker);
        Self {
            group,
            delimiter,
            header,
            null_marker,
        }
    }

    fn options(&self) -> CsvImportOptions {
        CsvImportOptions {
            delimiter: selected_delimiter(self.delimiter.selected()),
            has_header: self.header.is_active(),
            null_marker: self.null_marker.text().to_string(),
        }
    }
}

enum ColumnSection {
    Existing(ExistingColumns),
    New(NewColumns),
}

impl ColumnSection {
    fn new(request: &ImportRequest) -> Self {
        match &request.mode {
            ImportMode::ExistingTable { table, columns } => Self::Existing(ExistingColumns::new(table, columns)),
            ImportMode::NewTable {
                driver_id,
                suggested_table,
            } => Self::New(NewColumns::new(driver_id, suggested_table)),
        }
    }

    fn group(&self) -> &adw::PreferencesGroup {
        match self {
            Self::Existing(existing) => &existing.group,
            Self::New(new) => &new.group,
        }
    }

    fn refresh(&self, sheet: &CsvSheet, options: &CsvImportOptions) {
        match self {
            Self::Existing(existing) => existing.refresh(sheet),
            Self::New(new) => new.refresh(sheet, options),
        }
    }

    #[allow(clippy::type_complexity)]
    fn resolve(&self) -> Option<(String, Vec<ColumnInfo>, Vec<Option<usize>>, Option<Vec<DraftColumn>>)> {
        match self {
            Self::Existing(existing) => Some((
                existing.table.clone(),
                existing.columns.clone(),
                existing.mapping(),
                None,
            )),
            Self::New(new) => new.resolve(),
        }
    }
}

struct ExistingColumns {
    group: adw::PreferencesGroup,
    table: String,
    columns: Vec<ColumnInfo>,
    rows: Vec<adw::ComboRow>,
}

impl ExistingColumns {
    fn new(table: &str, columns: &[ColumnInfo]) -> Self {
        let group = adw::PreferencesGroup::builder()
            .title(crate::tr!("Columns"))
            .description(crate::tr!(
                "A column left on Skip is not written, so the database applies its own default."
            ))
            .build();
        let rows: Vec<adw::ComboRow> = columns
            .iter()
            .map(|column| {
                adw::ComboRow::builder()
                    .title(&column.name)
                    .subtitle(&column.data_type)
                    .build()
            })
            .collect();
        for row in &rows {
            group.add(row);
        }
        Self {
            group,
            table: table.to_owned(),
            columns: columns.to_vec(),
            rows,
        }
    }

    fn refresh(&self, sheet: &CsvSheet) {
        let suggestion = suggest_mapping(&sheet.headers, &self.columns);
        let mut labels: Vec<&str> = vec![SKIP_LABEL];
        labels.extend(sheet.headers.iter().map(String::as_str));
        for (row, field) in self.rows.iter().zip(suggestion) {
            row.set_model(Some(&gtk::StringList::new(&labels)));
            row.set_selected(field.map_or(0, |index| index as u32 + 1));
        }
    }

    fn mapping(&self) -> Vec<Option<usize>> {
        self.rows
            .iter()
            .map(|row| (row.selected() > 0).then(|| row.selected() as usize - 1))
            .collect()
    }
}

struct NewColumns {
    group: adw::PreferencesGroup,
    driver_id: String,
    table: adw::EntryRow,
    type_names: Vec<&'static str>,
    rows: std::cell::RefCell<Vec<NewColumnRow>>,
}

struct NewColumnRow {
    row: adw::EntryRow,
    types: gtk::DropDown,
}

impl NewColumns {
    fn new(driver_id: &str, suggested_table: &str) -> Self {
        let group = adw::PreferencesGroup::builder()
            .title(crate::tr!("New table"))
            .description(crate::tr!(
                "The type of each column is a guess from the first rows of the file. Change any that is wrong before the table is created."
            ))
            .build();
        let table = adw::EntryRow::builder().title(crate::tr!("Table name")).build();
        table.set_text(suggested_table);
        group.add(&table);
        Self {
            group,
            driver_id: driver_id.to_owned(),
            table,
            type_names: type_names_for(driver_id),
            rows: std::cell::RefCell::new(Vec::new()),
        }
    }

    fn refresh(&self, sheet: &CsvSheet, options: &CsvImportOptions) {
        let mut rows = self.rows.borrow_mut();
        for existing in rows.drain(..) {
            self.group.remove(&existing.row);
        }
        for draft in infer_columns(sheet, options, &self.driver_id) {
            let row = adw::EntryRow::builder().title(crate::tr!("Column")).build();
            row.set_text(&draft.name);
            let types = gtk::DropDown::from_strings(&self.type_names);
            types.set_valign(gtk::Align::Center);
            types.set_selected(self.position_of(&draft.data_type));
            row.add_suffix(&types);
            self.group.add(&row);
            rows.push(NewColumnRow { row, types });
        }
    }

    fn position_of(&self, data_type: &str) -> u32 {
        self.type_names.iter().position(|name| *name == data_type).unwrap_or(0) as u32
    }

    #[allow(clippy::type_complexity)]
    fn resolve(&self) -> Option<(String, Vec<ColumnInfo>, Vec<Option<usize>>, Option<Vec<DraftColumn>>)> {
        let table = self.table.text().trim().to_owned();
        let table_ok = sql_dialect::validate_ident(&table).is_ok();
        mark(&self.table, table_ok);
        let rows = self.rows.borrow();
        let mut drafts = Vec::with_capacity(rows.len());
        let mut all_ok = table_ok && !rows.is_empty();
        for entry in rows.iter() {
            let name = entry.row.text().trim().to_owned();
            let ok = sql_dialect::validate_ident(&name).is_ok();
            mark(&entry.row, ok);
            all_ok = all_ok && ok;
            drafts.push(DraftColumn {
                original: None,
                name,
                data_type: self.selected_type(entry).to_owned(),
                nullable: true,
                primary_key: false,
                auto_increment: false,
                default_value: None,
                comment: None,
                collation: None,
            });
        }
        if !all_ok {
            return None;
        }
        let columns: Vec<ColumnInfo> = drafts.iter().map(draft_to_info).collect();
        let mapping = (0..columns.len()).map(Some).collect();
        Some((table, columns, mapping, Some(drafts)))
    }

    fn selected_type(&self, entry: &NewColumnRow) -> &'static str {
        self.type_names
            .get(entry.types.selected() as usize)
            .copied()
            .unwrap_or("TEXT")
    }
}

/// A column the import is about to create: what the table will hold once
/// the CREATE has run, which is what the INSERT binds against.
fn draft_to_info(draft: &DraftColumn) -> ColumnInfo {
    ColumnInfo {
        name: draft.name.clone(),
        data_type: draft.data_type.clone(),
        nullable: draft.nullable,
        primary_key: draft.primary_key,
        is_auto_increment: draft.auto_increment,
        default_value: draft.default_value.clone(),
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn mark(row: &adw::EntryRow, ok: bool) {
    if ok {
        row.remove_css_class("error");
        return;
    }
    row.add_css_class("error");
}

fn type_names_for(driver_id: &str) -> Vec<&'static str> {
    let mut names = Vec::new();
    for kind in tablepro_core::import::ColumnKind::ALL {
        let name = tablepro_core::import::type_name(driver_id, kind);
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

fn delimiter_row(selected: CsvDelimiter) -> adw::ComboRow {
    let labels: Vec<&str> = CsvDelimiter::ALL
        .iter()
        .map(|delimiter| delimiter_label(*delimiter))
        .collect();
    let row = adw::ComboRow::builder()
        .title(crate::tr!("Field separator"))
        .model(&gtk::StringList::new(&labels))
        .build();
    row.set_selected(
        CsvDelimiter::ALL
            .iter()
            .position(|delimiter| *delimiter == selected)
            .unwrap_or(0) as u32,
    );
    row
}

fn delimiter_label(delimiter: CsvDelimiter) -> &'static str {
    match delimiter {
        CsvDelimiter::Comma => "Comma",
        CsvDelimiter::Semicolon => "Semicolon",
        CsvDelimiter::Tab => "Tab",
        CsvDelimiter::Pipe => "Pipe",
    }
}

fn selected_delimiter(index: u32) -> CsvDelimiter {
    CsvDelimiter::ALL
        .get(index as usize)
        .copied()
        .unwrap_or(CsvDelimiter::Comma)
}

fn build_dialog(page: &adw::PreferencesPage, start_button: &gtk::Button) -> adw::Dialog {
    let footer = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .halign(gtk::Align::End)
        .margin_top(6)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    footer.append(start_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(page));
    toolbar.add_bottom_bar(&footer);
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Import CSV"))
        .content_width(560)
        .content_height(680)
        .child(&toolbar)
        .build();
    dialog.set_default_widget(Some(start_button));
    dialog
}

/// The running import's progress window. The app holds it while the
/// batches run and drops it when the import reaches its terminal state.
pub(crate) struct ImportProgress {
    dialog: adw::Dialog,
    bar: gtk::ProgressBar,
    label: gtk::Label,
    total: u64,
    cancel: CancellationToken,
}

impl ImportProgress {
    pub(crate) fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    pub(crate) fn set_committed(&self, committed: u64) {
        let fraction = if self.total == 0 {
            0.0
        } else {
            committed as f64 / self.total as f64
        };
        self.bar.set_fraction(fraction);
        self.label.set_label(
            &crate::tr!("{done} of {total} rows")
                .replace("{done}", &committed.to_string())
                .replace("{total}", &self.total.to_string()),
        );
    }

    pub(crate) fn close(&self) {
        self.dialog.close();
    }
}

pub(crate) fn present_progress(parent: &adw::ApplicationWindow, table: &str, total: u64) -> ImportProgress {
    let cancel = CancellationToken::new();
    let label = gtk::Label::new(Some(
        &crate::tr!("{done} of {total} rows")
            .replace("{done}", "0")
            .replace("{total}", &total.to_string()),
    ));
    let bar = gtk::ProgressBar::new();
    let stop = gtk::Button::with_label(&crate::tr!("Cancel"));
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    content.append(&label);
    content.append(&bar);
    content.append(&stop);
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Importing into {table}").replace("{table}", table))
        .content_width(400)
        .child(&content)
        .can_close(false)
        .build();
    stop.connect_clicked({
        let cancel = cancel.clone();
        move |button| {
            cancel.cancel();
            button.set_sensitive(false);
        }
    });
    dialog.present(Some(parent));
    ImportProgress {
        dialog,
        bar,
        label,
        total,
        cancel,
    }
}
