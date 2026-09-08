use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{adw, gtk};

use tablepro_core::QueryResult;
use tablepro_core::export::{self, CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};

use crate::services::preferences;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Format {
    Csv,
    Json,
}

impl Format {
    const ALL: [Format; 2] = [Format::Csv, Format::Json];

    fn label(self) -> &'static str {
        match self {
            Format::Csv => "CSV",
            Format::Json => "JSON",
        }
    }

    fn extension(self) -> &'static str {
        match self {
            Format::Csv => "csv",
            Format::Json => "json",
        }
    }

    fn mime_type(self) -> &'static str {
        match self {
            Format::Csv => "text/csv",
            Format::Json => "application/json",
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

pub fn present(parent: &adw::ApplicationWindow, toast_overlay: &adw::ToastOverlay, result: QueryResult, name: String) {
    let page = adw::PreferencesPage::new();

    let format_group = adw::PreferencesGroup::new();
    let format_labels: Vec<&str> = Format::ALL.iter().map(|f| f.label()).collect();
    let format_row = combo_row(&crate::tr!("Format"), &format_labels);
    let rows_label = crate::tr!("{n} rows").replace("{n}", &result.rows.len().to_string());
    format_row.set_subtitle(&rows_label);
    format_group.add(&format_row);
    page.add(&format_group);

    let csv_group = adw::PreferencesGroup::builder()
        .title(crate::tr!("CSV options"))
        .build();
    let rows = Rc::new(CsvRows {
        null_to_empty: switch_row(&crate::tr!("Convert NULL to empty"), None),
        line_break_to_space: switch_row(&crate::tr!("Convert line breaks to spaces"), None),
        header_row: switch_row(&crate::tr!("Put field names in the first row"), None),
        sanitize_formulas: switch_row(
            &crate::tr!("Sanitize formula-like values"),
            Some(&crate::tr!(
                "Prefix values starting with =, +, - or @ so spreadsheets do not run them"
            )),
        ),
        delimiter: combo_row(
            &crate::tr!("Delimiter"),
            &[
                &crate::tr!("Comma (,)"),
                &crate::tr!("Semicolon (;)"),
                &crate::tr!("Tab"),
                &crate::tr!("Pipe (|)"),
            ],
        ),
        quote: combo_row(
            &crate::tr!("Quote"),
            &[
                &crate::tr!("Always"),
                &crate::tr!("Quote if needed"),
                &crate::tr!("Never"),
            ],
        ),
        line_break: combo_row(&crate::tr!("Line break"), &["LF (\\n)", "CRLF (\\r\\n)", "CR (\\r)"]),
        decimal: combo_row(
            &crate::tr!("Decimal separator"),
            &[&crate::tr!("Period (.)"), &crate::tr!("Comma (,)")],
        ),
    });
    rows.show(&preferences::load().csv_export);
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

    // Read-modify-write: the preferences dialog can be open over this
    // one, and neither should overwrite the other's settings.
    let persist = {
        let rows = rows.clone();
        Rc::new(move || preferences::update(|prefs| prefs.csv_export = rows.read()))
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
        csv_group_for_format.set_visible(pick(&Format::ALL, row.selected()) == Format::Csv);
    });

    let reset_button = gtk::Button::builder().label(crate::tr!("Reset to Defaults")).build();
    reset_button.add_css_class("flat");
    let rows_for_reset = rows.clone();
    reset_button.connect_clicked(move |_| rows_for_reset.show(&CsvOptions::default()));

    let export_button = gtk::Button::builder().label(crate::tr!("Export\u{2026}")).build();
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
        .title(crate::tr!("Export Results"))
        .content_width(480)
        .child(&toolbar)
        .build();
    dialog.set_default_widget(Some(&export_button));

    let window = parent.clone();
    let toast_overlay = toast_overlay.clone();
    let dialog_for_export = dialog.clone();
    export_button.connect_clicked(move |_| {
        let format = pick(&Format::ALL, format_row.selected());
        let options = rows.read();
        dialog_for_export.close();
        save_with_file_dialog(&window, &toast_overlay, format, &name, result.clone(), options);
    });

    dialog.present(Some(parent));
}

fn save_with_file_dialog(
    parent: &adw::ApplicationWindow,
    toast_overlay: &adw::ToastOverlay,
    format: Format,
    name: &str,
    result: QueryResult,
    options: CsvOptions,
) {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::tr!("{format} files").replace("{format}", format.label())));
    filter.add_mime_type(format.mime_type());
    filter.add_suffix(format.extension());
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let file_dialog = gtk::FileDialog::builder()
        .title(crate::tr!("Export Results"))
        .modal(true)
        .initial_name(format!("{name}.{}", format.extension()))
        .default_filter(&filter)
        .filters(&filters)
        .build();

    let parent_for_alert = parent.clone();
    let toast_overlay = toast_overlay.clone();
    file_dialog.save(Some(parent), gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else { return };
        let Some(path) = file.path() else { return };
        let text = match format {
            Format::Csv => export::render_csv(&result.columns, &result.rows, &options),
            Format::Json => export::render_json(&result.columns, &result.rows),
        };
        match std::fs::write(&path, text) {
            Ok(()) => toast_overlay.add_toast(adw::Toast::new(
                &crate::tr!("Exported to {path}").replace("{path}", &path.display().to_string()),
            )),
            Err(e) => {
                let alert = adw::AlertDialog::new(
                    Some(&crate::tr!("Couldn't export")),
                    Some(
                        &crate::tr!("Writing {path} failed: {error}")
                            .replace("{path}", &path.display().to_string())
                            .replace("{error}", &e.to_string()),
                    ),
                );
                alert.add_response("close", &crate::tr!("Close"));
                alert.set_default_response(Some("close"));
                alert.set_close_response("close");
                alert.present(Some(&parent_for_alert));
            }
        }
    });
}
