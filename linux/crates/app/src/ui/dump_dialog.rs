//! Export Database: a whole database or one schema, structure and rows,
//! as one SQL file that loads into an empty database.

use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::dump::{DumpRequest, DumpScope};
use tablepro_session::Session;

use crate::ui::export::{DumpJob, ExportLedger};

pub(crate) struct DumpDialogInit {
    pub parent: adw::ApplicationWindow,
    pub exports: Rc<ExportLedger>,
    pub session: Arc<Session>,
    /// The database's name, which the file is named after.
    pub database: String,
    /// The schemas the user can export one of; empty on an engine whose
    /// database is the only choice.
    pub schemas: Vec<String>,
}

/// The rows the dialog reads when Export is clicked.
struct DumpForm {
    contents: Option<adw::ComboRow>,
    schemas: Vec<String>,
    data: adw::SwitchRow,
    gzip: adw::SwitchRow,
}

impl DumpForm {
    fn scope(&self) -> DumpScope {
        let chosen = self
            .contents
            .as_ref()
            .and_then(|row| (row.selected() as usize).checked_sub(1))
            .and_then(|index| self.schemas.get(index));
        match chosen {
            Some(schema) => DumpScope::Schema(schema.clone()),
            None => DumpScope::Database,
        }
    }
}

pub(crate) fn present(init: DumpDialogInit) {
    let DumpDialogInit {
        parent,
        exports,
        session,
        database,
        schemas,
    } = init;
    let page = adw::PreferencesPage::new();
    let group = adw::PreferencesGroup::builder()
        .description(crate::i18n::gettext(
            "Tables, views, routines and triggers, with every table’s rows, as one SQL file that loads into an empty database.",
        ))
        .build();
    let contents = (!schemas.is_empty()).then(|| {
        let mut titles = vec![crate::i18n::gettext("Whole Database")];
        titles.extend(
            schemas
                .iter()
                .map(|schema| crate::i18n::gettext_f("Schema “{schema}”", &[("schema", schema)])),
        );
        let titles: Vec<&str> = titles.iter().map(String::as_str).collect();
        let row = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Contents"))
            .model(&gtk::StringList::new(&titles))
            .build();
        crate::ui::combo_value::show_whole_value(&row);
        group.add(&row);
        row
    });
    let data = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Include Rows"))
        .subtitle(crate::i18n::gettext("Off writes the structure alone"))
        .active(true)
        .build();
    let gzip = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Compress with gzip"))
        .subtitle(crate::i18n::gettext("Writes a .sql.gz file"))
        .build();
    group.add(&data);
    group.add(&gzip);
    page.add(&group);

    let export_button = gtk::Button::builder()
        .label(crate::i18n::gettext("Export…"))
        .halign(gtk::Align::End)
        .margin_top(6)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    export_button.add_css_class("suggested-action");
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    toolbar.add_bottom_bar(&export_button);
    let dialog = adw::Dialog::builder()
        .title(crate::i18n::gettext("Export Database"))
        .content_width(480)
        .child(&toolbar)
        .build();
    dialog.set_default_widget(Some(&export_button));

    let form = DumpForm {
        contents,
        schemas,
        data,
        gzip,
    };
    let closing = dialog.downgrade();
    let window = parent.clone();
    export_button.connect_clicked(move |_| {
        let request = DumpRequest {
            scope: form.scope(),
            data: form.data.is_active(),
        };
        let gzip = form.gzip.is_active();
        if let Some(dialog) = closing.upgrade() {
            dialog.close();
        }
        let name = file_name(&database, &request.scope, gzip);
        glib::spawn_future_local(choose_file(
            window.clone(),
            exports.clone(),
            Arc::clone(&session),
            request,
            gzip,
            name,
        ));
    });
    dialog.present(Some(&parent));
}

/// The file's suggested name: the database, the schema where one was
/// picked, and the date.
fn file_name(database: &str, scope: &DumpScope, gzip: bool) -> String {
    let date = glib::DateTime::now_local()
        .ok()
        .and_then(|now| now.format("%Y-%m-%d").ok())
        .map(|date| date.to_string())
        .unwrap_or_default();
    let mut stem = sanitized(database);
    if let DumpScope::Schema(schema) = scope {
        stem.push('-');
        stem.push_str(&sanitized(schema));
    }
    if !date.is_empty() {
        stem.push('-');
        stem.push_str(&date);
    }
    match gzip {
        true => format!("{stem}.sql.gz"),
        false => format!("{stem}.sql"),
    }
}

/// A name a file can carry: no path separator, and none of the
/// characters other systems refuse.
fn sanitized(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            other if other.is_control() => '_',
            other => other,
        })
        .collect();
    match cleaned.trim().trim_matches('.') {
        "" => "database".to_owned(),
        trimmed => trimmed.to_owned(),
    }
}

async fn choose_file(
    parent: adw::ApplicationWindow,
    exports: Rc<ExportLedger>,
    session: Arc<Session>,
    request: DumpRequest,
    gzip: bool,
    name: String,
) {
    let filter = gtk::FileFilter::new();
    match gzip {
        true => {
            filter.set_name(Some(&crate::i18n::gettext("Gzipped SQL files")));
            filter.add_suffix("gz");
            filter.add_mime_type("application/gzip");
        }
        false => {
            filter.set_name(Some(&crate::i18n::gettext("SQL files")));
            filter.add_suffix("sql");
            filter.add_mime_type("application/sql");
        }
    }
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let file_dialog = gtk::FileDialog::builder()
        .title(crate::i18n::gettext("Export Database"))
        .modal(true)
        .initial_name(name)
        .default_filter(&filter)
        .filters(&filters)
        .build();
    // Cancelling the chooser is the only way it fails without a file.
    let Ok(destination) = file_dialog.save_future(Some(&parent)).await else {
        return;
    };
    // The ledger reports how the job ends, or logs why it never began.
    let _ = exports.begin_dump(DumpJob {
        destination,
        session,
        request,
        gzip,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_is_named_after_the_database_and_schema() {
        let name = file_name("shop", &DumpScope::Schema("sales/eu".to_owned()), true);

        assert!(name.starts_with("shop-sales_eu-"), "{name}");
        assert!(name.ends_with(".sql.gz"), "{name}");
        assert!(file_name("shop", &DumpScope::Database, false).ends_with(".sql"));
    }

    #[test]
    fn a_name_with_nothing_a_file_can_carry_becomes_database() {
        assert_eq!(sanitized(" .. "), "database");
        assert_eq!(sanitized("a\nb"), "a_b");
    }
}
