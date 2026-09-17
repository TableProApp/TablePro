use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{adw, gtk};

use tablepro_core::QueryResult;
use tablepro_core::export::{self, CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};

/// What a result needs to be written back as `INSERT` statements.
///
/// A browse tab knows both; a query result does not, because it may
/// join several tables or none, so SQL is not offered for one.
#[derive(Debug, Clone)]
pub struct SqlTarget {
    pub table: String,
    pub driver_id: String,
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

    fn offered(target: Option<&SqlTarget>) -> &'static [Format] {
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

pub fn present(
    parent: &adw::ApplicationWindow,
    toast_overlay: &adw::ToastOverlay,
    result: QueryResult,
    name: String,
    target: Option<SqlTarget>,
    settings: &Rc<tablepro_storage::AppSettings>,
) {
    let formats = Format::offered(target.as_ref());
    let page = adw::PreferencesPage::new();

    let format_group = adw::PreferencesGroup::new();
    let format_labels: Vec<&str> = formats.iter().map(|f| f.label()).collect();
    let format_row = combo_row(&crate::i18n::gettext("Format"), &format_labels);
    let rows_label = crate::i18n::ngettext_f(
        "{n} row",
        "{n} rows",
        result.rows.len() as u32,
        &[("n", &result.rows.len().to_string())],
    );
    format_row.set_subtitle(&rows_label);
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
        .title(crate::i18n::gettext("Export Results"))
        .content_width(480)
        .child(&toolbar)
        .build();
    dialog.set_default_widget(Some(&export_button));

    let window = parent.clone();
    let toast_overlay = toast_overlay.clone();
    let dialog_for_export = dialog.clone();
    export_button.connect_clicked(move |_| {
        let format = pick(formats, format_row.selected());
        let options = rows.read();
        dialog_for_export.close();
        save_with_file_dialog(
            &window,
            &toast_overlay,
            Export {
                format,
                name: name.clone(),
                target: target.clone(),
                result: result.clone(),
                options,
            },
        );
    });

    dialog.present(Some(parent));
}

/// One export, as the dialog left it.
struct Export {
    format: Format,
    name: String,
    target: Option<SqlTarget>,
    result: QueryResult,
    options: CsvOptions,
}

fn save_with_file_dialog(parent: &adw::ApplicationWindow, toast_overlay: &adw::ToastOverlay, export: Export) {
    let Export {
        format,
        name,
        target,
        result,
        options,
    } = export;
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
        .title(crate::i18n::gettext("Export Results"))
        .modal(true)
        .initial_name(format!("{name}.{}", format.extension()))
        .default_filter(&filter)
        .filters(&filters)
        .build();

    let parent_for_alert = parent.clone();
    let toast_overlay = toast_overlay.clone();
    // The HTML document titles itself after the export, and the
    // callback outlives this call, so it carries its own copy.
    let title = name.clone();
    file_dialog.save(Some(parent), gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else { return };
        let Some(path) = file.path() else { return };
        // Bytes rather than text, because a workbook is a zip archive.
        // The text formats hand over their own bytes unchanged.
        let encoded: Result<Vec<u8>, String> = match format {
            Format::Csv => export::render_csv(&result.columns, &result.rows, &options)
                .map(String::into_bytes)
                .map_err(|e| e.to_string()),
            Format::Xlsx => {
                export::render_xlsx(&result.columns, &result.rows, &title).map_err(|error| error.to_string())
            }
            Format::Json => Ok(export::render_json(&result.columns, &result.rows).into_bytes()),
            Format::Markdown => Ok(export::render_markdown(&result.columns, &result.rows).into_bytes()),
            Format::Html => Ok(export::render_html(&result.columns, &result.rows, &title).into_bytes()),
            Format::Xml => Ok(export::render_xml(&result.columns, &result.rows).into_bytes()),
            Format::Sql => match target.as_ref() {
                Some(target) => Ok(export::render_sql_insert(
                    tablepro_core::dialect::dialect_for(&target.driver_id),
                    &target.table,
                    &result.columns,
                    &result.rows,
                )
                .into_bytes()),
                // The format is only offered with a target, so this is
                // unreachable through the dialog.
                None => Err(crate::i18n::gettext("This result has no table to insert into.")),
            },
        };
        let written = encoded.and_then(|bytes| std::fs::write(&path, bytes).map_err(|e| e.to_string()));
        match written {
            Ok(()) => toast_overlay.add_toast(adw::Toast::new(&crate::i18n::gettext_f(
                "Exported to {path}",
                &[("path", &path.display().to_string())],
            ))),
            Err(error) => {
                let alert = adw::AlertDialog::new(
                    Some(&crate::i18n::gettext("Couldn't export")),
                    Some(&crate::i18n::gettext_f(
                        "Writing {path} failed: {error}",
                        &[("path", &path.display().to_string()), ("error", &error)],
                    )),
                );
                alert.add_response("close", &crate::i18n::gettext("Close"));
                alert.set_default_response(Some("close"));
                alert.set_close_response("close");
                alert.present(Some(&parent_for_alert));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
