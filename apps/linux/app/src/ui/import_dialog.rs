use std::path::PathBuf;

use crate::services::csv_import_mappings::{CsvMappingScope, CsvMappingStore};
use crate::ui::progress_dialog::CancellableDialog;
use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{
    CsvFormat, CsvImportOptions, CsvSheet, INFER_SAMPLE_ROWS, MAX_PREVIEW_ROWS, infer_columns, read_csv,
    suggest_mapping,
};
use tablepro_core::import::{CsvImportEncoding, CsvImportQuote};
use tablepro_core::sql_ddl::DraftColumn;
use tablepro_core::{ColumnInfo, import::supports_explicit_auto_increment_values, sql_dialect};
use tokio_util::sync::CancellationToken;

/// Whether the rows go into a table that is already there, or into one
/// the import creates first.
pub(crate) enum ImportMode {
    ExistingTable {
        driver_id: String,
        table: String,
        columns: Vec<ColumnInfo>,
    },
    NewTable {
        driver_id: String,
        suggested_table: String,
    },
}

/// What the app read from the file before it asked the user anything.
pub(crate) struct ImportRequest {
    pub schema: Option<String>,
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub format: CsvFormat,
    pub mode: ImportMode,
    pub mapping_store: Option<CsvMappingStore>,
    pub mapping_scope: Option<CsvMappingScope>,
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
    let for_quote = state.clone();
    state.file.quote.connect_selected_notify(move |_| for_quote.refresh());
    let for_encoding = state.clone();
    state
        .file
        .encoding
        .connect_selected_notify(move |_| for_encoding.refresh());
    let for_backslash = state.clone();
    state
        .file
        .backslash
        .connect_active_notify(move |_| for_backslash.refresh());
    let for_header = state.clone();
    state.file.header.connect_active_notify(move |_| for_header.refresh());
}

struct FileOptions {
    group: adw::PreferencesGroup,
    delimiter: adw::ComboRow,
    quote: adw::ComboRow,
    backslash: adw::SwitchRow,
    encoding: adw::ComboRow,
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
        let quote = choice_row(
            &crate::tr!("Quote character"),
            &["Double quote (\")", "Single quote (')", "None"],
        );
        let backslash = adw::SwitchRow::builder()
            .title(crate::tr!("Backslash escapes a quote"))
            .build();
        let encoding = choice_row(
            &crate::tr!("Encoding"),
            &["UTF-8", "Windows-1252", "UTF-16 LE", "UTF-16 BE"],
        );
        encoding.set_selected(starting_encoding(&request.bytes));
        group.add(&delimiter);
        group.add(&quote);
        group.add(&backslash);
        group.add(&encoding);
        group.add(&header);
        group.add(&null_marker);
        Self {
            group,
            delimiter,
            quote,
            backslash,
            encoding,
            header,
            null_marker,
        }
    }

    fn options(&self) -> CsvImportOptions {
        CsvImportOptions {
            delimiter: selected_delimiter(self.delimiter.selected()),
            quote: CsvImportQuote::ALL
                .get(self.quote.selected() as usize)
                .copied()
                .unwrap_or_default(),
            backslash_escape: self.backslash.is_active(),
            encoding: CsvImportEncoding::ALL
                .get(self.encoding.selected() as usize)
                .copied()
                .unwrap_or_default(),
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
            ImportMode::ExistingTable {
                driver_id,
                table,
                columns,
            } => Self::Existing(ExistingColumns::new(
                table,
                driver_id,
                columns,
                request.mapping_store.clone(),
                request.mapping_scope.clone(),
            )),
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
            Self::Existing(existing) => existing.refresh(sheet, options.has_header),
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
    driver_id: String,
    table: String,
    columns: Vec<ColumnInfo>,
    rows: Vec<adw::ComboRow>,
    headers: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    has_header: std::rc::Rc<std::cell::Cell<bool>>,
    initialized: std::cell::Cell<bool>,
}

impl ExistingColumns {
    fn new(
        table: &str,
        driver_id: &str,
        columns: &[ColumnInfo],
        store: Option<CsvMappingStore>,
        scope: Option<CsvMappingScope>,
    ) -> Self {
        let group = adw::PreferencesGroup::builder()
            .title(crate::tr!("Columns"))
            .description(crate::tr!(
                "Generated columns stay on Skip and are filled by the database. Other columns left on Skip are not written, so their database defaults apply."
            ))
            .build();
        let rows: Vec<adw::ComboRow> = columns
            .iter()
            .map(|column| {
                let row = adw::ComboRow::builder()
                    .title(&column.name)
                    .subtitle(column_subtitle(driver_id, column))
                    .build();
                row.set_sensitive(!server_managed(driver_id, column));
                row
            })
            .collect();
        for row in &rows {
            group.add(row);
        }
        let headers = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        let has_header = std::rc::Rc::new(std::cell::Cell::new(true));
        add_mapping_controls(
            &group,
            MappingActionsParams {
                driver_id: driver_id.to_owned(),
                rows: rows.clone(),
                headers: headers.clone(),
                has_header: has_header.clone(),
                columns: columns.to_vec(),
                store,
                scope,
            },
        );
        Self {
            group,
            driver_id: driver_id.to_owned(),
            table: table.to_owned(),
            columns: columns.to_vec(),
            rows,
            headers,
            has_header,
            initialized: std::cell::Cell::new(false),
        }
    }

    fn refresh(&self, sheet: &CsvSheet, has_header: bool) {
        let preserve = self.initialized.get() && *self.headers.borrow() == sheet.headers;
        *self.headers.borrow_mut() = sheet.headers.clone();
        self.has_header.set(has_header);
        if preserve {
            return;
        }
        let suggestion = suggested_existing_mapping(&self.driver_id, &sheet.headers, &self.columns);
        let mut labels = vec![SKIP_LABEL.to_string()];
        labels.extend(disambiguated_headers(&sheet.headers));
        for (row, field) in self.rows.iter().zip(suggestion) {
            let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
            row.set_model(Some(&gtk::StringList::new(&refs)));
            row.set_selected(field.map_or(0, |index| index as u32 + 1));
        }
        self.initialized.set(true);
    }

    fn mapping(&self) -> Vec<Option<usize>> {
        let selected = self
            .rows
            .iter()
            .map(|row| (row.selected() > 0).then(|| row.selected() as usize - 1))
            .collect();
        editable_existing_mapping(&self.driver_id, &self.columns, selected)
    }
}

struct MappingActions {
    status: gtk::Label,
    driver_id: String,
    rows: Vec<adw::ComboRow>,
    headers: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    has_header: std::rc::Rc<std::cell::Cell<bool>>,
    columns: Vec<ColumnInfo>,
    store: Option<CsvMappingStore>,
    scope: Option<CsvMappingScope>,
}

struct MappingActionsParams {
    driver_id: String,
    rows: Vec<adw::ComboRow>,
    headers: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    has_header: std::rc::Rc<std::cell::Cell<bool>>,
    columns: Vec<ColumnInfo>,
    store: Option<CsvMappingStore>,
    scope: Option<CsvMappingScope>,
}

fn add_mapping_controls(group: &adw::PreferencesGroup, params: MappingActionsParams) {
    let actions = gtk::Box::builder().spacing(6).build();
    let remember = gtk::Button::with_label(&crate::tr!("Remember mapping"));
    let restore = gtk::Button::with_label(&crate::tr!("Restore mapping"));
    let forget = gtk::Button::with_label(&crate::tr!("Forget mapping"));
    let status = gtk::Label::builder().xalign(0.0).wrap(true).build();
    let available = params.store.is_some() && params.scope.is_some();
    for button in [&remember, &restore, &forget] {
        button.set_sensitive(available);
        actions.append(button);
    }
    if !available {
        status.set_text(&crate::tr!("Saved mappings are unavailable for this connection."));
    }
    group.add(&actions);
    group.add(&status);
    MappingActions::new(&status, params).connect(&remember, &restore, &forget);
}

impl MappingActions {
    fn new(status: &gtk::Label, params: MappingActionsParams) -> Self {
        Self {
            status: status.clone(),
            driver_id: params.driver_id,
            rows: params.rows,
            headers: params.headers,
            has_header: params.has_header,
            columns: params.columns,
            store: params.store,
            scope: params.scope,
        }
    }

    fn connect(&self, remember: &gtk::Button, restore: &gtk::Button, forget: &gtk::Button) {
        self.connect_remember(remember);
        self.connect_restore(restore);
        self.connect_forget(forget);
    }

    fn connect_remember(&self, button: &gtk::Button) {
        let actions = self.clone_for_signal();
        button.connect_clicked(move |_| {
            let (Some(store), Some(scope)) = (&actions.store, &actions.scope) else {
                return;
            };
            let selected = actions
                .rows
                .iter()
                .map(|row| (row.selected() > 0).then(|| row.selected() as usize - 1))
                .collect();
            let mapping = editable_existing_mapping(&actions.driver_id, &actions.columns, selected);
            let result = store.save(
                scope,
                &actions.headers.borrow(),
                &actions.columns,
                &mapping,
                actions.has_header.get(),
            );
            actions.status.set_text(
                &result
                    .map(|()| crate::tr!("Mapping saved for this table."))
                    .unwrap_or_else(|error| error),
            );
        });
    }

    fn connect_restore(&self, button: &gtk::Button) {
        let actions = self.clone_for_signal();
        button.connect_clicked(move |_| {
            let (Some(store), Some(scope)) = (&actions.store, &actions.scope) else {
                return;
            };
            match store.restore(
                scope,
                &actions.headers.borrow(),
                &actions.columns,
                actions.has_header.get(),
            ) {
                Ok(Some(mapping)) => {
                    for (row, source) in actions.rows.iter().zip(mapping) {
                        row.set_selected(source.map_or(0, |index| index as u32 + 1));
                    }
                    actions
                        .status
                        .set_text(&crate::tr!("Saved mapping restored. Review it before importing."));
                }
                Ok(None) => actions.status.set_text(&crate::tr!("No saved mapping for this table.")),
                Err(error) => actions.status.set_text(&error),
            }
        });
    }

    fn connect_forget(&self, button: &gtk::Button) {
        let actions = self.clone_for_signal();
        button.connect_clicked(move |_| {
            let (Some(store), Some(scope)) = (&actions.store, &actions.scope) else {
                return;
            };
            match store.forget(scope) {
                Ok(true) => actions.status.set_text(&crate::tr!("Saved mapping removed.")),
                Ok(false) => actions.status.set_text(&crate::tr!("No saved mapping for this table.")),
                Err(error) => actions.status.set_text(&error),
            }
        });
    }

    fn clone_for_signal(&self) -> Self {
        Self {
            status: self.status.clone(),
            driver_id: self.driver_id.clone(),
            rows: self.rows.clone(),
            headers: self.headers.clone(),
            has_header: self.has_header.clone(),
            columns: self.columns.clone(),
            store: self.store.clone(),
            scope: self.scope.clone(),
        }
    }
}

fn disambiguated_headers(headers: &[String]) -> Vec<String> {
    headers
        .iter()
        .enumerate()
        .map(|(index, header)| {
            let occurrence = headers[..=index].iter().filter(|other| *other == header).count();
            let total = headers.iter().filter(|other| *other == header).count();
            if total > 1 {
                format!("{header} [{occurrence}]")
            } else {
                header.clone()
            }
        })
        .collect()
}

fn server_managed(driver_id: &str, column: &ColumnInfo) -> bool {
    column.is_generated || (column.is_auto_increment && !supports_explicit_auto_increment_values(driver_id))
}

fn column_subtitle(driver_id: &str, column: &ColumnInfo) -> String {
    if column.is_auto_increment && supports_explicit_auto_increment_values(driver_id) {
        format!(
            "{} · {}",
            column.data_type,
            crate::tr!("Auto-increment values are inserted when mapped.")
        )
    } else if server_managed(driver_id, column) {
        format!(
            "{} · {}",
            column.data_type,
            crate::tr!("Generated by database; CSV values are ignored.")
        )
    } else {
        column.data_type.clone()
    }
}

pub(super) fn suggested_existing_mapping(
    driver_id: &str,
    headers: &[String],
    columns: &[ColumnInfo],
) -> Vec<Option<usize>> {
    editable_existing_mapping(driver_id, columns, suggest_mapping(headers, columns))
}

fn editable_existing_mapping(
    driver_id: &str,
    columns: &[ColumnInfo],
    mapping: Vec<Option<usize>>,
) -> Vec<Option<usize>> {
    mapping
        .into_iter()
        .zip(columns)
        .map(|(field, column)| if server_managed(driver_id, column) { None } else { field })
        .collect()
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

fn starting_encoding(bytes: &[u8]) -> u32 {
    let encoding = if bytes.starts_with(&[0xff, 0xfe]) {
        CsvImportEncoding::Utf16Le
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        CsvImportEncoding::Utf16Be
    } else if std::str::from_utf8(bytes).is_err() {
        CsvImportEncoding::Windows1252
    } else {
        CsvImportEncoding::Utf8
    };
    CsvImportEncoding::ALL
        .iter()
        .position(|candidate| *candidate == encoding)
        .unwrap_or(0) as u32
}

fn choice_row(title: &str, labels: &[&str]) -> adw::ComboRow {
    adw::ComboRow::builder()
        .title(title)
        .model(&gtk::StringList::new(labels))
        .build()
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

pub(crate) struct ImportProgress {
    window: CancellableDialog,
    bar: gtk::ProgressBar,
    label: gtk::Label,
    total: u64,
}

impl ImportProgress {
    pub(crate) fn cancel_token(&self) -> CancellationToken {
        self.window.cancel_token()
    }

    pub(crate) fn set_committed(&self, committed: u64) {
        let fraction = if self.total == 0 {
            0.0
        } else {
            committed as f64 / self.total as f64
        };
        self.bar.set_fraction(fraction);
        self.label.set_label(&rows_label(committed, self.total));
    }

    pub(crate) fn close(&self) {
        self.window.close();
    }
}

fn rows_label(committed: u64, total: u64) -> String {
    crate::tr!("{done} of {total} rows")
        .replace("{done}", &committed.to_string())
        .replace("{total}", &total.to_string())
}

pub(crate) fn present_progress(parent: &adw::ApplicationWindow, table: &str, total: u64) -> ImportProgress {
    let label = gtk::Label::new(Some(&rows_label(0, total)));
    let bar = gtk::ProgressBar::new();
    let title = crate::tr!("Importing into {table}").replace("{table}", table);
    let window = CancellableDialog::present(parent, &title, &[label.upcast_ref(), bar.upcast_ref()]);
    ImportProgress {
        window,
        bar,
        label,
        total,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_that_is_not_utf8_opens_with_a_matching_encoding() {
        let selected = |bytes: &[u8]| CsvImportEncoding::ALL[starting_encoding(bytes) as usize];
        assert_eq!(selected(b"a,b\n1,2\n"), CsvImportEncoding::Utf8);
        assert_eq!(selected(b"caf\xe9\n"), CsvImportEncoding::Windows1252);
        assert_eq!(selected(&[0xff, 0xfe, b'a', 0]), CsvImportEncoding::Utf16Le);
        assert_eq!(selected(&[0xfe, 0xff, 0, b'a']), CsvImportEncoding::Utf16Be);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn finishing_an_import_force_closes_the_non_user_closable_progress_dialog() {
        gtk::init().unwrap();
        adw::init().unwrap();
        gtk::Settings::default().unwrap().set_gtk_enable_animations(false);
        let application = gtk::Application::new(None::<&str>, gtk::gio::ApplicationFlags::NON_UNIQUE);
        application.register(None::<&gtk::gio::Cancellable>).unwrap();
        let window = adw::ApplicationWindow::new(&application);
        window.present();
        let progress = present_progress(&window, "items", 2);

        assert!(wait_until(|| progress.window.dialog().is_mapped()));
        let closed = std::rc::Rc::new(std::cell::Cell::new(false));
        let closed_for_signal = closed.clone();
        progress
            .window
            .dialog()
            .connect_closed(move |_| closed_for_signal.set(true));
        progress.close();
        assert!(wait_until(|| closed.get()));
        window.close();
    }

    fn wait_until(predicate: impl Fn() -> bool) -> bool {
        let context = gtk::glib::MainContext::default();
        for _ in 0..200 {
            for _ in 0..64 {
                if !context.iteration(false) {
                    break;
                }
            }
            if predicate() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        predicate()
    }

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "INTEGER".into(),
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
    fn preview_suggestions_keep_explicit_auto_increment_and_skip_generated_columns() {
        let headers = vec!["id".into(), "name".into(), "computed".into()];
        let columns = vec![
            ColumnInfo {
                is_auto_increment: true,
                ..column("id")
            },
            ColumnInfo {
                data_type: "TEXT".into(),
                ..column("name")
            },
            ColumnInfo {
                is_generated: true,
                ..column("computed")
            },
        ];

        for driver_id in ["postgres", "mysql", "sqlite"] {
            assert_eq!(
                suggested_existing_mapping(driver_id, &headers, &columns),
                [Some(0), Some(1), None],
                "{driver_id}"
            );
        }
        assert_eq!(
            suggested_existing_mapping("mssql", &headers, &columns),
            [None, Some(1), None]
        );
    }

    #[test]
    fn selected_preview_mapping_keeps_explicit_auto_increment_and_skips_generated_columns() {
        let columns = vec![
            ColumnInfo {
                is_auto_increment: true,
                ..column("id")
            },
            column("name"),
            ColumnInfo {
                is_generated: true,
                ..column("computed")
            },
        ];

        assert_eq!(
            editable_existing_mapping("postgres", &columns, vec![Some(0), Some(1), Some(2)]),
            [Some(0), Some(1), None]
        );
        assert_eq!(
            editable_existing_mapping("mssql", &columns, vec![Some(0), Some(1), Some(2)]),
            [None, Some(1), None]
        );
        assert!(!server_managed("postgres", &columns[0]));
        assert!(server_managed("mssql", &columns[0]));
        assert!(server_managed("postgres", &columns[2]));
    }

    #[test]
    fn duplicate_header_labels_are_distinguishable_without_changing_header_values() {
        let headers = vec!["tag".to_string(), "tag".to_string(), "email".to_string()];
        assert_eq!(disambiguated_headers(&headers), ["tag [1]", "tag [2]", "email"]);
        assert_eq!(headers, ["tag", "tag", "email"]);
    }
}
