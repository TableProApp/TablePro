mod file;

use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{adw, gtk};
use tablepro_core::QueryResult;
use tablepro_core::export::{ExportError, RowPage};
use tokio_util::sync::CancellationToken;

use crate::services::preferences::PreferencesStore;

pub(crate) type PageFetcherFactory = std::sync::Arc<dyn Fn(CancellationToken) -> PageFetcher + Send + Sync>;

pub(crate) type PageFetcher = Box<dyn FnMut() -> Result<Option<RowPage>, ExportError> + Send>;

#[derive(Clone)]
pub(crate) struct PagedExport {
    pub(crate) total_rows: Option<usize>,
    pub(crate) open: PageFetcherFactory,
}

pub(crate) struct ExportRequest {
    pub(crate) paged: Option<PagedExport>,
    pub(crate) result: QueryResult,
    pub(crate) suggested_name: String,
    pub(crate) driver_id: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ExportFormat {
    Csv,
    Json,
    Markdown,
    Html,
    Xml,
    Sql,
    Xlsx,
}

struct FormatSpec {
    format: ExportFormat,
    label: &'static str,
    extension: &'static str,
    mime_type: &'static str,
    csv_options: bool,
}

const FORMATS: [FormatSpec; 7] = [
    FormatSpec {
        format: ExportFormat::Csv,
        label: "CSV",
        extension: "csv",
        mime_type: "text/csv",
        csv_options: true,
    },
    FormatSpec {
        format: ExportFormat::Json,
        label: "JSON",
        extension: "json",
        mime_type: "application/json",
        csv_options: false,
    },
    FormatSpec {
        format: ExportFormat::Markdown,
        label: "Markdown",
        extension: "md",
        mime_type: "text/markdown",
        csv_options: false,
    },
    FormatSpec {
        format: ExportFormat::Html,
        label: "HTML",
        extension: "html",
        mime_type: "text/html",
        csv_options: false,
    },
    FormatSpec {
        format: ExportFormat::Xml,
        label: "XML",
        extension: "xml",
        mime_type: "application/xml",
        csv_options: false,
    },
    FormatSpec {
        format: ExportFormat::Sql,
        label: "SQL INSERT statements",
        extension: "sql",
        mime_type: "application/sql",
        csv_options: false,
    },
    FormatSpec {
        format: ExportFormat::Xlsx,
        label: "Excel workbook",
        extension: "xlsx",
        mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        csv_options: false,
    },
];

impl ExportFormat {
    fn spec(self) -> &'static FormatSpec {
        FORMATS.iter().find(|spec| spec.format == self).unwrap_or(&FORMATS[0])
    }

    fn label(self) -> &'static str {
        self.spec().label
    }

    fn extension(self) -> &'static str {
        self.spec().extension
    }

    fn mime_type(self) -> &'static str {
        self.spec().mime_type
    }

    fn shows_csv_options(self) -> bool {
        self.spec().csv_options
    }
}

fn format_subtitle(result: &QueryResult, paged: Option<&PagedExport>) -> String {
    match paged {
        Some(PagedExport {
            total_rows: Some(total),
            ..
        }) => crate::tr!("All {n} rows, read page by page; changes made meanwhile may be missed")
            .replace("{n}", &total.to_string()),
        Some(_) => crate::tr!("All rows, read page by page; changes made meanwhile may be missed"),
        None if result.truncated => {
            crate::tr!("{n} loaded rows (result truncated)").replace("{n}", &result.rows.len().to_string())
        }
        None => crate::tr!("{n} loaded rows / current page").replace("{n}", &result.rows.len().to_string()),
    }
}

fn available_formats(driver_id: &str, paged: Option<&PagedExport>) -> Vec<ExportFormat> {
    let statements = tablepro_core::export::supports_sql_literals(driver_id);
    let workbook_fits = paged.is_none_or(|paged| paged.total_rows.is_some());
    FORMATS
        .iter()
        .filter(|spec| statements || spec.format != ExportFormat::Sql)
        .filter(|spec| workbook_fits || spec.format != ExportFormat::Xlsx)
        .map(|spec| spec.format)
        .collect()
}

fn selected_format(formats: &[ExportFormat], index: u32) -> ExportFormat {
    formats.get(index as usize).copied().unwrap_or(ExportFormat::Csv)
}

fn build_sql_group(suggested_name: &str) -> (adw::PreferencesGroup, adw::EntryRow) {
    let (schema, table) = insert_target(suggested_name);
    let group = adw::PreferencesGroup::builder()
        .title(crate::tr!("SQL options"))
        .build();
    let target = adw::EntryRow::builder().title(crate::tr!("Table name")).build();
    target.set_text(&match schema {
        Some(schema) => format!("{schema}.{table}"),
        None => table,
    });
    group.add(&target);
    (group, target)
}

fn insert_target(name: &str) -> (Option<String>, String) {
    match name.rsplit_once('.') {
        Some((schema, table)) if !schema.is_empty() && !table.is_empty() => {
            (Some(schema.to_string()), table.to_string())
        }
        _ => (None, name.to_string()),
    }
}

fn suggested_file_name(name: &str, format: ExportFormat) -> String {
    let base = FORMATS
        .iter()
        .find_map(|spec| name.strip_suffix(&format!(".{}", spec.extension)))
        .filter(|base| !base.is_empty())
        .unwrap_or(name);
    format!("{base}.{}", format.extension())
}

pub(crate) fn present(
    parent: &adw::ApplicationWindow,
    toast_overlay: &adw::ToastOverlay,
    request: ExportRequest,
    preferences: &PreferencesStore,
) {
    present_with_format(parent, toast_overlay, request, false, preferences);
}

pub(crate) fn present_with_format(
    parent: &adw::ApplicationWindow,
    toast_overlay: &adw::ToastOverlay,
    request: ExportRequest,
    json: bool,
    preferences: &PreferencesStore,
) {
    let ExportRequest {
        paged,
        result,
        suggested_name,
        driver_id,
    } = request;
    let null_marker = if paged.is_some() {
        "\\N".to_string()
    } else {
        tablepro_core::export::unique_csv_null_marker(&result.rows)
    };
    let page = adw::PreferencesPage::new();

    let format_group = adw::PreferencesGroup::new();
    let formats = available_formats(&driver_id, paged.as_ref());
    let labels: Vec<&str> = formats.iter().map(|format| format.label()).collect();
    let format_row = adw::ComboRow::builder()
        .title(crate::tr!("Format"))
        .subtitle(format_subtitle(&result, paged.as_ref()))
        .model(&gtk::StringList::new(&labels))
        .build();
    format_row.set_selected(u32::from(json));
    format_group.add(&format_row);
    page.add(&format_group);

    let csv_group = adw::PreferencesGroup::builder()
        .title(crate::tr!("CSV options"))
        .build();
    let include_header = adw::SwitchRow::builder()
        .title(crate::tr!("Include column names"))
        .subtitle(crate::tr!("Write column names in the first row"))
        .build();
    include_header.set_active(preferences.load().csv_include_header);
    csv_group.add(&include_header);
    let safe_csv = adw::SwitchRow::builder()
        .title(crate::tr!("Spreadsheet-safe text"))
        .subtitle(crate::tr!(
            "Prefix formula-like text with an apostrophe for spreadsheet safety. Turn off for lossless re-import."
        ))
        .active(true)
        .build();
    csv_group.add(&safe_csv);
    let null_marker_row = adw::EntryRow::builder()
        .title(crate::tr!("Text that means NULL"))
        .build();
    null_marker_row.set_text(&null_marker);
    null_marker_row.set_editable(false);
    csv_group.add(&null_marker_row);
    csv_group.set_visible(!json);
    page.add(&csv_group);

    let (sql_group, sql_target) = build_sql_group(&suggested_name);
    sql_group.set_visible(false);
    page.add(&sql_group);

    let preferences_for_toggle = preferences.clone();
    include_header.connect_active_notify(move |row| {
        if let Err(error) = preferences_for_toggle.update(|prefs| prefs.csv_include_header = row.is_active()) {
            tracing::warn!(%error, "preferences: update rejected");
        }
    });

    let csv_group_for_format = csv_group.clone();
    let sql_group_for_format = sql_group.clone();
    let formats_for_visibility = formats.clone();
    format_row.connect_selected_notify(move |row| {
        let format = selected_format(&formats_for_visibility, row.selected());
        csv_group_for_format.set_visible(format.shows_csv_options());
        sql_group_for_format.set_visible(format == ExportFormat::Sql);
    });

    let reset_button = gtk::Button::builder().label(crate::tr!("Reset to Defaults")).build();
    reset_button.add_css_class("flat");
    let include_header_for_reset = include_header.clone();
    let safe_csv_for_reset = safe_csv.clone();
    reset_button.connect_clicked(move |_| {
        include_header_for_reset.set_active(true);
        safe_csv_for_reset.set_active(true);
    });

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

    let parent_for_export = parent.clone();
    let toast_overlay_for_export = toast_overlay.clone();
    let dialog_for_export = dialog.clone();
    let include_header_for_export = include_header.clone();
    let null_marker_for_export = null_marker.clone();
    export_button.connect_clicked(move |_| {
        let format = selected_format(&formats, format_row.selected());
        let include_header = include_header_for_export.is_active();
        dialog_for_export.close();
        save_with_file_dialog(
            &parent_for_export,
            &toast_overlay_for_export,
            SaveRequest {
                format,
                suggested_name: suggested_name.clone(),
                driver_id: driver_id.clone(),
                result: result.clone(),
                paged: paged.clone(),
                include_header,
                sanitize_formulas: safe_csv.is_active(),
                null_marker: null_marker_for_export.clone(),
                sql_target: sql_target.text().to_string(),
            },
        );
    });

    dialog.present(Some(parent));
}

struct SaveRequest {
    format: ExportFormat,
    suggested_name: String,
    driver_id: String,
    result: QueryResult,
    paged: Option<PagedExport>,
    include_header: bool,
    sanitize_formulas: bool,
    null_marker: String,
    sql_target: String,
}

fn save_with_file_dialog(parent: &adw::ApplicationWindow, toast_overlay: &adw::ToastOverlay, request: SaveRequest) {
    let SaveRequest {
        format,
        suggested_name,
        driver_id,
        result,
        paged,
        include_header,
        sanitize_formulas,
        null_marker,
        sql_target,
    } = request;
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::tr!("{format} files").replace("{format}", format.label())));
    filter.add_mime_type(format.mime_type());
    filter.add_suffix(format.extension());
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let file_dialog = gtk::FileDialog::builder()
        .title(crate::tr!("Export Results"))
        .modal(true)
        .initial_name(suggested_file_name(&suggested_name, format))
        .default_filter(&filter)
        .filters(&filters)
        .build();

    let parent_for_alert = parent.clone();
    let toast_overlay = toast_overlay.clone();
    file_dialog.save(Some(parent), gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else {
            return;
        };
        let Some(path) = file.path() else {
            return;
        };
        let options = tablepro_core::export::CsvOptions {
            null_to_empty: false,
            header_row: include_header,
            sanitize_formulas,
            preserve_sqlite_result_types: driver_id == "sqlite",
            null_marker: Some(null_marker),
            ..Default::default()
        };
        let (schema, table) = insert_target(&sql_target);
        file::start(
            &parent_for_alert,
            &toast_overlay,
            file::ExportJob {
                path,
                source: job_source(&paged, &result),
                format,
                options,
                driver_id: driver_id.clone(),
                schema,
                table,
            },
        );
    });
}

fn job_source(paged: &Option<PagedExport>, result: &QueryResult) -> file::JobSource {
    match paged {
        Some(paged) => file::JobSource::Paged {
            columns: result.columns.clone(),
            total: paged.total_rows,
            open: paged.open.clone(),
        },
        None => file::JobSource::Loaded(result.clone()),
    }
}

fn show_export_error(
    parent: &adw::ApplicationWindow,
    path: &std::path::Path,
    error: &tablepro_core::export::ExportError,
) {
    let alert = adw::AlertDialog::new(
        Some(&crate::tr!("Couldn't export")),
        Some(
            &crate::tr!("Writing {path} failed: {error}")
                .replace("{path}", &path.display().to_string())
                .replace("{error}", &error.to_string()),
        ),
    );
    alert.add_response("close", &crate::tr!("Close"));
    alert.set_default_response(Some("close"));
    alert.set_close_response("close");
    alert.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_qualified_result_name_becomes_a_schema_and_table_for_sql_statements() {
        assert_eq!(
            insert_target("public.customers"),
            (Some("public".into()), "customers".into())
        );
        assert_eq!(insert_target("customers"), (None, "customers".into()));
        assert_eq!(insert_target("Query 1"), (None, "Query 1".into()));
        assert_eq!(insert_target(".customers"), (None, ".customers".into()));
    }

    #[test]
    fn a_result_with_no_source_table_offers_its_label_for_the_user_to_correct() {
        assert_eq!(insert_target("query-results"), (None, "query-results".into()));
        assert_eq!(
            insert_target("orders"),
            (None, "orders".into()),
            "an edited table name is used verbatim rather than the result label"
        );
    }

    #[test]
    fn a_connection_without_sql_literals_is_not_offered_the_statement_format() {
        assert!(available_formats("postgres", None).contains(&ExportFormat::Sql));
        for driver_id in ["mongodb", "redis"] {
            assert!(
                !available_formats(driver_id, None).contains(&ExportFormat::Sql),
                "{driver_id}"
            );
            assert_eq!(available_formats(driver_id, None).len(), FORMATS.len() - 1);
        }
    }

    #[test]
    fn the_csv_options_group_belongs_to_csv_alone() {
        for spec in &FORMATS {
            assert_eq!(
                spec.format.shows_csv_options(),
                spec.format == ExportFormat::Csv,
                "{:?}",
                spec.format
            );
        }
    }

    #[test]
    fn the_selected_row_maps_to_the_format_offered_at_that_position() {
        let formats = available_formats("mongodb", None);
        assert_eq!(selected_format(&formats, 0), ExportFormat::Csv);
        assert_eq!(selected_format(&formats, 5), ExportFormat::Xlsx);
        assert_eq!(selected_format(&formats, 99), ExportFormat::Csv);
        assert_eq!(
            selected_format(&available_formats("postgres", None), 5),
            ExportFormat::Sql
        );
    }

    #[test]
    fn every_offered_format_has_its_own_extension_and_media_type() {
        for spec in &FORMATS {
            assert_eq!(spec.format.extension(), spec.extension);
            assert_eq!(spec.format.mime_type(), spec.mime_type);
            assert_eq!(
                FORMATS.iter().filter(|other| other.extension == spec.extension).count(),
                1,
                "{}",
                spec.extension
            );
        }
        assert_eq!(
            suggested_file_name("customers.csv", ExportFormat::Xlsx),
            "customers.xlsx"
        );
        assert_eq!(suggested_file_name("customers.md", ExportFormat::Sql), "customers.sql");
    }

    #[test]
    fn suggested_file_name_uses_the_selected_format() {
        assert_eq!(suggested_file_name("customers", ExportFormat::Csv), "customers.csv");
        assert_eq!(
            suggested_file_name("customers.csv", ExportFormat::Json),
            "customers.json"
        );
        assert_eq!(
            suggested_file_name("customers.json", ExportFormat::Csv),
            "customers.csv"
        );
    }

    #[test]
    fn a_workbook_needs_a_known_row_count_when_rows_are_read_page_by_page() {
        let unknown = PagedExport {
            total_rows: None,
            open: std::sync::Arc::new(|_| Box::new(|| Ok(None))),
        };
        let known = PagedExport {
            total_rows: Some(10),
            open: unknown.open.clone(),
        };
        assert!(!available_formats("sqlite", Some(&unknown)).contains(&ExportFormat::Xlsx));
        assert!(available_formats("sqlite", Some(&known)).contains(&ExportFormat::Xlsx));
        assert!(available_formats("sqlite", None).contains(&ExportFormat::Xlsx));
    }
}
