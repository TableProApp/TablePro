use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{adw, gtk};

use tablepro_core::dialect::SqlDialect;
use tablepro_core::export::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
use tablepro_session::Session;

use super::export::{
    DocumentFormat, ExpectedRows, ExportFormat, ExportJob, ExportLedger, ExportOffer, ExportOrigin, ExportSource,
    InsertTarget, RowFormat, ScopeChoice, ScopeSource, scope_choices,
};

/// The table a result can be written back to as `INSERT` statements.
///
/// A browse tab knows it; a query result does not, because it may join
/// several tables or none, so SQL is not offered for one.
#[derive(Debug, Clone)]
pub struct SqlTarget {
    pub table: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Format {
    Csv,
    Xlsx,
    Json,
    Markdown,
    Html,
    Xml,
    Sql,
}

impl Format {
    /// Every format a query result can take. A browse tab adds SQL,
    /// which needs a table to insert into.
    const ALL: [Format; 6] = [
        Format::Csv,
        Format::Xlsx,
        Format::Json,
        Format::Markdown,
        Format::Html,
        Format::Xml,
    ];
    const ALL_WITH_SQL: [Format; 7] = [
        Format::Csv,
        Format::Xlsx,
        Format::Json,
        Format::Markdown,
        Format::Html,
        Format::Xml,
        Format::Sql,
    ];

    fn offered(target: Option<&InsertTarget>) -> &'static [Format] {
        match target {
            Some(_) => &Self::ALL_WITH_SQL,
            None => &Self::ALL,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Format::Csv => "CSV",
            Format::Xlsx => "Excel",
            Format::Json => "JSON",
            Format::Markdown => "Markdown",
            Format::Html => "HTML",
            Format::Xml => "XML",
            Format::Sql => "SQL",
        }
    }

    fn extension(self) -> &'static str {
        match self {
            Format::Csv => "csv",
            Format::Xlsx => "xlsx",
            Format::Json => "json",
            Format::Markdown => "md",
            Format::Html => "html",
            Format::Xml => "xml",
            Format::Sql => "sql",
        }
    }

    /// What a job writes in this format. `None` for SQL without a table
    /// to insert into, which the dialog never offers.
    fn job_format(self, csv: CsvOptions, name: &str, target: Option<&InsertTarget>) -> Option<ExportFormat> {
        Some(match self {
            Format::Csv => ExportFormat::Rows(RowFormat::Csv(csv)),
            Format::Json => ExportFormat::Rows(RowFormat::Json),
            Format::Markdown => ExportFormat::Rows(RowFormat::Markdown),
            Format::Xlsx => ExportFormat::Document(DocumentFormat::Xlsx { sheet: name.to_owned() }),
            Format::Html => ExportFormat::Rows(RowFormat::Html { title: name.to_owned() }),
            Format::Xml => ExportFormat::Rows(RowFormat::Xml),
            Format::Sql => ExportFormat::Rows(RowFormat::Sql(target?.clone())),
        })
    }

    fn mime_type(self) -> &'static str {
        match self {
            Format::Csv => "text/csv",
            Format::Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Format::Json => "application/json",
            Format::Markdown => "text/markdown",
            Format::Html => "text/html",
            Format::Xml => "application/xml",
            Format::Sql => "application/sql",
        }
    }
}

struct CsvRows {
    null_to_empty: adw::SwitchRow,
    line_break_to_space: adw::SwitchRow,
    header_row: adw::SwitchRow,
    sanitize_formulas: adw::SwitchRow,
    delimiter: adw::ComboRow,
    quote: adw::ComboRow,
    line_break: adw::ComboRow,
    decimal: adw::ComboRow,
}

impl CsvRows {
    fn show(&self, opts: &CsvOptions) {
        self.null_to_empty.set_active(opts.null_to_empty);
        self.line_break_to_space.set_active(opts.line_break_to_space);
        self.header_row.set_active(opts.header_row);
        self.sanitize_formulas.set_active(opts.sanitize_formulas);
        self.delimiter
            .set_selected(index_of(&CsvDelimiter::ALL, opts.delimiter));
        self.quote.set_selected(index_of(&CsvQuote::ALL, opts.quote));
        self.line_break
            .set_selected(index_of(&CsvLineBreak::ALL, opts.line_break));
        self.decimal.set_selected(index_of(&CsvDecimal::ALL, opts.decimal));
    }

    fn read(&self) -> CsvOptions {
        CsvOptions {
            null_to_empty: self.null_to_empty.is_active(),
            line_break_to_space: self.line_break_to_space.is_active(),
            header_row: self.header_row.is_active(),
            sanitize_formulas: self.sanitize_formulas.is_active(),
            delimiter: pick(&CsvDelimiter::ALL, self.delimiter.selected()),
            quote: pick(&CsvQuote::ALL, self.quote.selected()),
            line_break: pick(&CsvLineBreak::ALL, self.line_break.selected()),
            decimal: pick(&CsvDecimal::ALL, self.decimal.selected()),
        }
    }
}

fn index_of<T: PartialEq>(all: &[T], value: T) -> u32 {
    all.iter().position(|v| *v == value).unwrap_or(0) as u32
}

fn pick<T: Copy>(all: &[T], index: u32) -> T {
    all[(index as usize).min(all.len() - 1)]
}

fn switch_row(title: &str, subtitle: Option<&str>) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder().title(title).build();
    if let Some(subtitle) = subtitle {
        row.set_subtitle(subtitle);
    }
    row
}

fn combo_row(title: &str, choices: &[&str]) -> adw::ComboRow {
    adw::ComboRow::builder()
        .title(title)
        .model(&gtk::StringList::new(choices))
        .build()
}

/// What the dialog exports, and where it hands the job.
pub(crate) struct ExportDialogInit<'a> {
    pub parent: &'a adw::ApplicationWindow,
    pub exports: &'a Rc<ExportLedger>,
    pub offer: ExportOffer,
    pub dialect: Option<Arc<dyn SqlDialect>>,
    pub settings: &'a Rc<tablepro_storage::AppSettings>,
}

/// The Rows list: which rows the export writes, one entry per scope
/// the origin offers.
struct ScopeRow {
    row: adw::ComboRow,
    choices: Vec<ScopeChoice>,
}

impl ScopeRow {
    fn new(origin: &ExportOrigin, can_read: bool) -> Self {
        let mut choices = scope_choices(origin);
        // A read of every row goes through the tab's session, and a
        // window that disconnected has none.
        choices.retain(|choice| can_read || choice.source == ScopeSource::Shown);
        let titles: Vec<&str> = choices.iter().map(|choice| choice.title.as_str()).collect();
        let row = combo_row(&crate::i18n::gettext("Rows"), &titles);
        let preselected = origin.preselected();
        let index = choices
            .iter()
            .position(|choice| choice.source == preselected)
            .unwrap_or_default();
        row.set_selected(u32::try_from(index).unwrap_or_default());
        row.set_sensitive(choices.len() > 1);
        let subtitles: Vec<String> = choices.iter().map(|choice| choice.subtitle.clone()).collect();
        let show_subtitle = move |row: &adw::ComboRow| {
            let subtitle = subtitles.get(row.selected() as usize).map_or("", String::as_str);
            row.set_subtitle(subtitle);
        };
        show_subtitle(&row);
        row.connect_selected_notify(show_subtitle);
        Self { row, choices }
    }

    fn selected(&self) -> Option<&ScopeChoice> {
        self.choices.get(self.row.selected() as usize)
    }
}

pub(crate) fn present(init: ExportDialogInit<'_>) {
    let ExportDialogInit {
        parent,
        exports,
        offer,
        dialect,
        settings,
    } = init;
    let ExportOffer {
        origin,
        session,
        name,
        target,
    } = offer;
    let target = target.zip(dialect).map(|(target, dialect)| InsertTarget {
        table: target.table,
        dialect,
    });
    let formats = Format::offered(target.as_ref());
    let page = adw::PreferencesPage::new();

    let format_group = adw::PreferencesGroup::new();
    let scope = ScopeRow::new(&origin, session.is_some());
    format_group.add(&scope.row);
    let format_labels: Vec<&str> = formats.iter().map(|f| f.label()).collect();
    let format_row = combo_row(&crate::i18n::gettext("Format"), &format_labels);
    format_group.add(&format_row);
    page.add(&format_group);

    let csv_group = adw::PreferencesGroup::builder()
        .title(crate::i18n::gettext("CSV options"))
        .build();
    let rows = Rc::new(CsvRows {
        null_to_empty: switch_row(&crate::i18n::gettext("Convert NULL to empty"), None),
        line_break_to_space: switch_row(&crate::i18n::gettext("Convert line breaks to spaces"), None),
        header_row: switch_row(&crate::i18n::gettext("Put field names in the first row"), None),
        sanitize_formulas: switch_row(
            &crate::i18n::gettext("Sanitize formula-like values"),
            Some(&crate::i18n::gettext(
                "Prefix values starting with =, +, - or @ so spreadsheets do not run them",
            )),
        ),
        delimiter: combo_row(
            &crate::i18n::gettext("Delimiter"),
            &[
                &crate::i18n::gettext("Comma (,)"),
                &crate::i18n::gettext("Semicolon (;)"),
                &crate::i18n::gettext("Tab"),
                &crate::i18n::gettext("Pipe (|)"),
            ],
        ),
        quote: combo_row(
            &crate::i18n::gettext("Quote"),
            &[
                &crate::i18n::gettext("Always"),
                &crate::i18n::gettext("Quote if needed"),
                &crate::i18n::gettext("Never"),
            ],
        ),
        line_break: combo_row(
            &crate::i18n::gettext("Line break"),
            &["LF (\\n)", "CRLF (\\r\\n)", "CR (\\r)"],
        ),
        decimal: combo_row(
            &crate::i18n::gettext("Decimal separator"),
            &[&crate::i18n::gettext("Period (.)"), &crate::i18n::gettext("Comma (,)")],
        ),
    });
    rows.show(&settings.csv_options());
    for row in [
        &rows.null_to_empty,
        &rows.line_break_to_space,
        &rows.header_row,
        &rows.sanitize_formulas,
    ] {
        csv_group.add(row);
    }
    for row in [&rows.delimiter, &rows.quote, &rows.line_break, &rows.decimal] {
        csv_group.add(row);
    }
    page.add(&csv_group);

    // GSettings is the single copy, so two open dialogs converge instead
    // of overwriting each other.
    let persist = {
        let rows = rows.clone();
        let settings = settings.clone();
        Rc::new(move || {
            if let Err(error) = settings.set_csv_options(&rows.read()) {
                tracing::warn!(%error, "could not save the CSV export options");
            }
        })
    };
    for row in [
        &rows.null_to_empty,
        &rows.line_break_to_space,
        &rows.header_row,
        &rows.sanitize_formulas,
    ] {
        let persist = persist.clone();
        row.connect_active_notify(move |_| persist());
    }
    for row in [&rows.delimiter, &rows.quote, &rows.line_break, &rows.decimal] {
        let persist = persist.clone();
        row.connect_selected_notify(move |_| persist());
    }

    let csv_group_for_format = csv_group.clone();
    format_row.connect_selected_notify(move |row| {
        csv_group_for_format.set_visible(pick(formats, row.selected()) == Format::Csv);
    });

    let reset_button = gtk::Button::builder()
        .label(crate::i18n::gettext("Reset to Defaults"))
        .build();
    reset_button.add_css_class("flat");
    let rows_for_reset = rows.clone();
    let settings_for_reset = settings.clone();
    reset_button.connect_clicked(move |_| {
        settings_for_reset.reset_csv_options();
        rows_for_reset.show(&settings_for_reset.csv_options());
    });

    let export_button = gtk::Button::builder().label(crate::i18n::gettext("Export…")).build();
    export_button.add_css_class("suggested-action");

    let footer = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .margin_top(6)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    footer.append(&reset_button);
    footer.append(&gtk::Box::builder().hexpand(true).build());
    footer.append(&export_button);

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    toolbar.add_bottom_bar(&footer);

    let dialog = adw::Dialog::builder()
        .title(crate::i18n::gettext("Export Rows"))
        .content_width(480)
        .child(&toolbar)
        .build();
    dialog.set_default_widget(Some(&export_button));

    // One dialog, one export: the rows go to the job rather than being
    // copied for each click.
    let unexported = Rc::new(RefCell::new(Some(Unexported { origin, session })));
    let window = parent.clone();
    let exports = exports.clone();
    let dialog_for_export = dialog.clone();
    export_button.connect_clicked(move |_| {
        let format = pick(formats, format_row.selected());
        let Some(job_format) = format.job_format(rows.read(), &name, target.as_ref()) else {
            return;
        };
        let Some(choice) = scope.selected().cloned() else {
            return;
        };
        let Some(Unexported { origin, session }) = unexported.borrow_mut().take() else {
            return;
        };
        let Some(source) = origin.into_source(choice.source, session) else {
            return;
        };
        dialog_for_export.close();
        let chosen = Chosen {
            format,
            job_format,
            name: name.clone(),
            source,
            expected_rows: choice.expected,
        };
        glib::spawn_future_local(save_with_file_dialog(window.clone(), exports.clone(), chosen));
    });

    dialog.present(Some(parent));
}

/// What the dialog holds until its one export takes it.
struct Unexported {
    origin: ExportOrigin,
    session: Option<Arc<Session>>,
}

/// One export, as the dialog left it.
struct Chosen {
    format: Format,
    job_format: ExportFormat,
    name: String,
    source: ExportSource,
    expected_rows: Option<ExpectedRows>,
}

async fn save_with_file_dialog(parent: adw::ApplicationWindow, exports: Rc<ExportLedger>, chosen: Chosen) {
    let Chosen {
        format,
        job_format,
        name,
        source,
        expected_rows,
    } = chosen;
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::i18n::gettext_f(
        "{format} files",
        &[("format", format.label())],
    )));
    filter.add_mime_type(format.mime_type());
    filter.add_suffix(format.extension());
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let file_dialog = gtk::FileDialog::builder()
        .title(crate::i18n::gettext("Export Rows"))
        .modal(true)
        .initial_name(format!("{name}.{}", format.extension()))
        .default_filter(&filter)
        .filters(&filters)
        .build();
    // Cancelling the chooser is the only way it fails without a file.
    let Ok(destination) = file_dialog.save_future(Some(&parent)).await else {
        return;
    };
    // The ledger reports how the job ends, or logs why it never began.
    let _ = exports.begin(ExportJob {
        destination,
        format: job_format,
        source,
        expected_rows,
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{EditorSession, ResultEvent, Truncation, Value};
    use tablepro_test_support::{FakeEditorSession, FakeReply, FakeRun, Replies};

    use super::*;
    use crate::test_support::{descendants, first_descendant_of_type, wait_until};
    use crate::ui::session_window::tests::{TestWindow, editors};

    const WAIT: Duration = Duration::from_secs(20);

    /// A run whose one result the row limit cut short.
    fn capped_run() -> Replies<FakeRun> {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("text"))].into();
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(vec![
            ResultEvent::ResultSetStarted { columns },
            ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
            ResultEvent::RowLimitReached { retained: 2 },
            ResultEvent::ResultSetFinished {
                retained: 2,
                total_rows: None,
                truncation: Truncation::ServerStopped,
            },
        ]));
        runs
    }

    #[gtk4::test]
    fn export_all_opens_dialog_with_all_rows_scope_selected() {
        let fake = Arc::new(FakeEditorSession::new(capped_run()));
        let test = TestWindow::connected_with("ExportAll", |script| {
            let editor: Arc<dyn EditorSession> = fake.clone();
            script.open_editor_session.always(FakeReply::ok(editor));
        });
        test.run_in_new_editor_tab();
        let editor = editors(&test.window).pop().expect("the editor tab");
        let banner = first_descendant_of_type::<adw::Banner>(&editor).expect("the result's banner");
        assert!(banner.is_revealed(), "the capped result has no banner");

        banner.emit_by_name::<()>("button-clicked", &[]);

        wait_until(WAIT, || test.window.visible_dialog().is_some()).expect("the export dialog");
        let dialog = test.window.visible_dialog().expect("the export dialog");
        assert_eq!(dialog.title(), "Export Rows");
        let rows = descendants(&dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ComboRow>().ok())
            .find(|row| row.title() == "Rows")
            .expect("the Rows list");
        let selected = rows
            .selected_item()
            .and_downcast::<gtk::StringObject>()
            .expect("a selected scope");
        assert_eq!(selected.string(), "All Rows");
        assert_eq!(
            rows.subtitle().as_deref(),
            Some("Runs the statement again on a separate read-only connection")
        );
    }

    #[test]
    fn every_format_has_a_label_extension_and_type_of_its_own() {
        let mut labels: Vec<&str> = Format::ALL_WITH_SQL.iter().map(|f| f.label()).collect();
        let mut extensions: Vec<&str> = Format::ALL_WITH_SQL.iter().map(|f| f.extension()).collect();
        let mut types: Vec<&str> = Format::ALL_WITH_SQL.iter().map(|f| f.mime_type()).collect();

        for list in [&mut labels, &mut extensions, &mut types] {
            let before = list.len();
            list.sort_unstable();
            list.dedup();
            assert_eq!(list.len(), before, "two formats share an entry: {list:?}");
        }
    }

    #[test]
    fn sql_is_the_only_format_that_needs_a_table() {
        assert!(!Format::offered(None).contains(&Format::Sql));
        assert!(Format::offered(None).contains(&Format::Xlsx));
        assert_eq!(Format::offered(None).len() + 1, Format::ALL_WITH_SQL.len());
    }
}
