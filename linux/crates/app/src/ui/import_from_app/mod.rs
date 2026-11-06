// Import from another app: pick the app, read its connections off the GTK thread, review them
// against the saved ones with the macOS duplicate handling, then hand the plan to the window.

mod imp;
#[cfg(test)]
mod tests;
mod wording;

use std::cell::{Cell, RefCell};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::DriverRegistry;
use tablepro_foreign_import::review::{
    ConnectionRow, ImportPlan, ImportReview, ImportSelection, QueryAvailability, QueryRow, Resolution, plan,
};
use tablepro_foreign_import::{ForeignApp, ForeignAppDirs, ForeignImporter, ImportRequest, PasswordSource};
use tablepro_session::runtime::Tasks;
use tablepro_storage::ConnectionStore;
use tokio_util::sync::CancellationToken;

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::runtime::spawn_and_deliver;
use crate::services::foreign_import::{AppSource, ReadFailure, ReviewRead, importer, look_for_apps_blocking};

// The core library's cap on one saved query.
const SAVED_QUERY_BYTE_LIMIT: u64 = 1024 * 1024;

glib::wrapper! {
    pub struct ImportFromAppDialog(ObjectSubclass<imp::ImportFromAppDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) type ImportRequested = Box<dyn Fn(ImportReview, ImportPlan)>;

pub(crate) struct ImportFromAppInit {
    pub dirs: ForeignAppDirs,
    pub drivers: Arc<DriverRegistry>,
    pub connections: ConnectionStore,
    pub tasks: Tasks,
    pub on_import: ImportRequested,
}

pub(super) struct DialogParts {
    dirs: ForeignAppDirs,
    drivers: Arc<DriverRegistry>,
    connections: ConnectionStore,
    tasks: Tasks,
    on_import: ImportRequested,
    cancel: CancellationToken,
    // The switches' own answers, kept while an app that cannot honour one is picked.
    wants_passwords: Cell<bool>,
    wants_queries: Cell<bool>,
}

pub(super) struct SourceRow {
    app: ForeignApp,
    check: gtk::CheckButton,
    available: bool,
}

pub(super) struct Reviewing {
    review: ImportReview,
    selection: ImportSelection,
    connections: Vec<ConnectionWidgets>,
    queries: Vec<QueryWidgets>,
}

struct ConnectionWidgets {
    reference: String,
    row: adw::ActionRow,
    check: gtk::CheckButton,
    resolution: Option<gtk::DropDown>,
    // What the drop-down lists, which a Replace another row takes changes.
    offered: RefCell<Vec<Resolution>>,
}

#[derive(Clone)]
struct QueryWidgets {
    check: gtk::CheckButton,
    row: adw::ActionRow,
}

impl ImportFromAppDialog {
    pub(crate) fn new(init: ImportFromAppInit) -> Self {
        let dialog: Self = glib::Object::new();
        let imp = dialog.imp();
        let _ = imp.parts.set(DialogParts {
            dirs: init.dirs,
            drivers: init.drivers,
            connections: init.connections,
            tasks: init.tasks,
            on_import: init.on_import,
            cancel: CancellationToken::new(),
            wants_passwords: Cell::new(true),
            wants_queries: Cell::new(true),
        });
        imp.sources_stack.set_visible_child_name("loading");
        dialog.connect_signals();
        dialog.load_sources();
        dialog
    }

    fn parts(&self) -> Option<&DialogParts> {
        self.imp().parts.get()
    }

    fn connect_signals(&self) {
        let imp = self.imp();
        imp.continue_button.connect_clicked(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |_| dialog.on_continue()
        ));
        imp.import_button.connect_clicked(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |_| dialog.on_import()
        ));
        imp.passwords_row.connect_active_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| {
                if let Some(parts) = dialog.parts().filter(|_| row.is_sensitive()) {
                    parts.wants_passwords.set(row.is_active());
                }
            }
        ));
        imp.queries_row.connect_active_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| {
                if let Some(parts) = dialog.parts().filter(|_| row.is_sensitive()) {
                    parts.wants_queries.set(row.is_active());
                }
            }
        ));
        self.connect_closed(|dialog| {
            if let Some(parts) = dialog.parts() {
                parts.cancel.cancel();
            }
        });
    }

    fn load_sources(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let dirs = parts.dirs.clone();
        let blocking = parts.tasks.clone();
        let dialog = self.downgrade();
        spawn_and_deliver(
            &parts.tasks,
            async move {
                blocking
                    .spawn_blocking_task(move || look_for_apps_blocking(&dirs))
                    .await
            },
            move |outcome| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                match outcome {
                    Ok(Ok(sources)) => dialog.show_sources(&sources),
                    Ok(Err(failure)) | Err(failure) => {
                        tracing::warn!(%failure, "could not look for other apps");
                        dialog.show_sources(&[]);
                    }
                }
            },
        );
    }

    fn show_sources(&self, sources: &[AppSource]) {
        let imp = self.imp();
        let mut rows = Vec::with_capacity(sources.len());
        let mut leader: Option<gtk::CheckButton> = None;
        for source in sources {
            let check = gtk::CheckButton::builder().valign(gtk::Align::Center).build();
            if let Some(leader) = &leader {
                check.set_group(Some(leader));
            } else {
                leader = Some(check.clone());
            }
            let row = adw::ActionRow::builder()
                .title(source.app.display_name())
                .subtitle(wording::source_subtitle(source.app, source.available, source.inventory))
                .use_markup(false)
                .activatable_widget(&check)
                .sensitive(source.available)
                .build();
            row.add_prefix(&check);
            check.connect_toggled(glib::clone!(
                #[weak(rename_to = dialog)]
                self,
                move |check| {
                    if check.is_active() {
                        dialog.update_options();
                    }
                }
            ));
            imp.apps_group.add(&row);
            rows.push(SourceRow {
                app: source.app,
                check,
                available: source.available,
            });
        }
        if let Some(first) = rows.iter().find(|row| row.available) {
            first.check.set_active(true);
        }
        imp.sources.replace(rows);
        imp.sources_stack.set_visible_child_name("sources");
        self.update_options();
    }

    fn selected_app(&self) -> Option<ForeignApp> {
        self.imp()
            .sources
            .borrow()
            .iter()
            .find(|row| row.available && row.check.is_active())
            .map(|row| row.app)
    }

    fn update_options(&self) {
        let imp = self.imp();
        let app = self.selected_app();
        imp.continue_button.set_sensitive(app.is_some());
        let (Some(app), Some(parts)) = (app, self.parts()) else {
            imp.passwords_row.set_sensitive(false);
            imp.queries_row.set_sensitive(false);
            return;
        };
        let passwords = wording::password_option(app);
        imp.passwords_row.set_sensitive(passwords.offered);
        imp.passwords_row
            .set_active(passwords.offered && parts.wants_passwords.get());
        imp.passwords_row.set_subtitle(&passwords.subtitle);
        let queries = wording::saved_query_option(app);
        imp.queries_row.set_sensitive(queries.offered);
        imp.queries_row.set_active(queries.offered && parts.wants_queries.get());
        imp.queries_row.set_subtitle(&queries.subtitle);
    }

    fn request(&self, app: ForeignApp) -> ImportRequest {
        let imp = self.imp();
        // With the switch unavailable, a keychain app's passwords are still asked for, so the
        // review says they stayed behind.
        let include_passwords = if imp.passwords_row.is_sensitive() {
            imp.passwords_row.is_active()
        } else {
            app.password_source() == PasswordSource::Keychain
        };
        ImportRequest {
            include_passwords,
            include_saved_queries: imp.queries_row.is_sensitive() && imp.queries_row.is_active(),
            saved_query_byte_limit: SAVED_QUERY_BYTE_LIMIT,
        }
    }

    fn on_continue(&self) {
        let (Some(app), Some(parts)) = (self.selected_app(), self.parts()) else {
            return;
        };
        let importer = importer(app, &parts.dirs);
        match app.picked_file_extensions() {
            Some(extensions) => self.pick_file(importer, extensions),
            None => self.collect(importer),
        }
    }

    fn pick_file(&self, importer: ForeignImporter, extensions: &[&str]) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&gettext_f(
            "{app} export files",
            &[("app", importer.app().display_name())],
        )));
        for extension in extensions {
            filter.add_suffix(extension);
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let file_dialog = gtk::FileDialog::builder()
            .title(gettext_f(
                "Choose a {app} Export File",
                &[("app", importer.app().display_name())],
            ))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let window = self.root().and_downcast::<gtk::Window>();
        let dialog = self.downgrade();
        file_dialog.open(window.as_ref(), gio::Cancellable::NONE, move |picked| {
            let (Some(dialog), Ok(file)) = (dialog.upgrade(), picked) else {
                return;
            };
            match file.path() {
                Some(path) => dialog.collect(importer.with_file(path)),
                None => dialog.show_failure(&gettext("Only files on this computer can be imported.")),
            }
        });
    }

    fn collect(&self, importer: ForeignImporter) {
        let imp = self.imp();
        let Some(parts) = self.parts() else {
            return;
        };
        let app = importer.app();
        imp.reading_status.set_description(Some(&gettext_f(
            "Reading connections from {app}…",
            &[("app", app.display_name())],
        )));
        imp.navigation.push_by_tag("reading");
        let read = ReviewRead {
            importer,
            request: self.request(app),
            cancel: parts.cancel.clone(),
            connections: parts.connections.clone(),
            drivers: parts.drivers.clone(),
            dirs: parts.dirs.clone(),
        };
        let blocking = parts.tasks.clone();
        let dialog = self.downgrade();
        spawn_and_deliver(
            &parts.tasks,
            async move { blocking.spawn_blocking_task(move || read.run_blocking()).await },
            move |outcome| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                match outcome {
                    Ok(Ok(Ok(review))) => dialog.show_review(review),
                    Ok(Ok(Err(ReadFailure::Import(error)))) => {
                        dialog.show_failure(&wording::collect_failure(app, &error))
                    }
                    Ok(Ok(Err(ReadFailure::Library(error)))) => {
                        tracing::warn!(%error, "could not read the saved connections to compare");
                        dialog.show_failure(&gettext(
                            "Your saved connections could not be read, so nothing was imported.",
                        ));
                    }
                    Ok(Err(failure)) | Err(failure) => {
                        tracing::warn!(%failure, "the import read did not finish");
                        dialog.show_failure(&gettext("The connections could not be read."));
                    }
                }
            },
        );
    }

    fn show_failure(&self, message: &str) {
        let imp = self.imp();
        if self.parts().is_none_or(|parts| parts.cancel.is_cancelled()) {
            return;
        }
        imp.failed_status.set_description(Some(message));
        imp.navigation.replace_with_tags(&["sources", "failed"]);
    }

    fn show_review(&self, review: ImportReview) {
        let imp = self.imp();
        let Some(parts) = self.parts().filter(|parts| !parts.cancel.is_cancelled()) else {
            return;
        };
        let app = review.app();
        imp.review_page
            .set_title(&gettext_f("Import from {app}", &[("app", app.display_name())]));
        match wording::password_banner(app, review.passwords()) {
            Some(text) => {
                imp.passwords_banner.set_title(&text);
                imp.passwords_banner.set_revealed(true);
            }
            None => imp.passwords_banner.set_revealed(false),
        }
        if let Some(previous) = imp.reviewing.take() {
            for widgets in &previous.connections {
                imp.connections_group.remove(&widgets.row);
            }
            for widgets in &previous.queries {
                imp.queries_group.remove(&widgets.row);
            }
        }

        let selection = ImportSelection::defaults(&review);
        let connections = review
            .connections()
            .iter()
            .map(|row| self.connection_row(row, &selection, &parts.drivers))
            .collect();
        let queries: Vec<QueryWidgets> = review
            .saved_queries()
            .iter()
            .map(|row| self.query_row(row, &selection))
            .collect();
        imp.queries_group.set_visible(!queries.is_empty());
        imp.reviewing.replace(Some(Reviewing {
            review,
            selection,
            connections,
            queries,
        }));
        self.refresh_review();
        imp.navigation.replace_with_tags(&["sources", "review"]);
    }

    fn connection_row(
        &self,
        row: &ConnectionRow,
        selection: &ImportSelection,
        drivers: &DriverRegistry,
    ) -> ConnectionWidgets {
        let imp = self.imp();
        let selectable = row.connection.is_some();
        let check = gtk::CheckButton::builder()
            .valign(gtk::Align::Center)
            .active(selection.is_selected(&row.reference))
            .sensitive(selectable)
            .build();
        let widget = adw::ActionRow::builder()
            .title(&row.name)
            .subtitle(wording::connection_subtitle(row, drivers))
            .subtitle_lines(0)
            .use_markup(false)
            .activatable_widget(&check)
            .sensitive(selectable)
            .build();
        widget.add_prefix(&check);
        let offered = selection.offered_resolutions(row);
        let resolution = row.duplicate.as_ref().map(|_| {
            let drop_down = gtk::DropDown::builder().model(&resolution_list(&offered)).build();
            drop_down.set_valign(gtk::Align::Center);
            drop_down.set_tooltip_text(Some(&gettext("If the connection is already there")));
            drop_down.update_property(&[gtk::accessible::Property::Label(&gettext(
                "If the connection is already there",
            ))]);
            let chosen = selection
                .resolution(&row.reference)
                .or_else(|| offered.first().copied());
            if let Some(index) = chosen.and_then(|choice| offered.iter().position(|offer| *offer == choice)) {
                drop_down.set_selected(u32::try_from(index).unwrap_or(0));
            }
            widget.add_suffix(&drop_down);
            let reference = row.reference.clone();
            drop_down.connect_selected_notify(glib::clone!(
                #[weak(rename_to = dialog)]
                self,
                move |drop_down| dialog.on_resolution_changed(&reference, drop_down.selected())
            ));
            drop_down
        });
        let reference = row.reference.clone();
        check.connect_toggled(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |check| dialog.on_connection_toggled(&reference, check.is_active())
        ));
        imp.connections_group.add(&widget);
        ConnectionWidgets {
            reference: row.reference.clone(),
            row: widget,
            check,
            resolution,
            offered: RefCell::new(offered),
        }
    }

    fn query_row(&self, row: &QueryRow, selection: &ImportSelection) -> QueryWidgets {
        let check = gtk::CheckButton::builder()
            .valign(gtk::Align::Center)
            .active(selection.wants_query(row))
            .build();
        let widget = adw::ActionRow::builder()
            .title(&row.name)
            .use_markup(false)
            .activatable_widget(&check)
            .build();
        widget.add_prefix(&check);
        let reference = row.reference.clone();
        check.connect_toggled(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |check| dialog.on_query_toggled(&reference, check.is_active())
        ));
        self.imp().queries_group.add(&widget);
        QueryWidgets { check, row: widget }
    }

    // A refresh sets widgets while it holds the review, and their signals land here: those are skipped.
    fn on_connection_toggled(&self, reference: &str, selected: bool) {
        {
            let Ok(mut reviewing) = self.imp().reviewing.try_borrow_mut() else {
                return;
            };
            let Some(reviewing) = reviewing.as_mut() else {
                return;
            };
            if reviewing.selection.is_selected(reference) != selected {
                let Reviewing { review, selection, .. } = reviewing;
                selection.set_selected(selected, reference, review);
            }
        }
        self.refresh_review();
    }

    fn on_resolution_changed(&self, reference: &str, index: u32) {
        {
            let Ok(mut reviewing) = self.imp().reviewing.try_borrow_mut() else {
                return;
            };
            let Some(reviewing) = reviewing.as_mut() else {
                return;
            };
            let Some(choice) = reviewing
                .connections
                .iter()
                .find(|widgets| widgets.reference == reference)
                .and_then(|widgets| {
                    widgets
                        .offered
                        .borrow()
                        .get(usize::try_from(index).unwrap_or(usize::MAX))
                        .copied()
                })
            else {
                return;
            };
            if reviewing.selection.resolution(reference) != Some(choice) {
                let Reviewing { review, selection, .. } = reviewing;
                selection.resolve(reference, choice, review);
            }
        }
        self.refresh_review();
    }

    fn on_query_toggled(&self, reference: &str, included: bool) {
        {
            let Ok(mut reviewing) = self.imp().reviewing.try_borrow_mut() else {
                return;
            };
            let Some(reviewing) = reviewing.as_mut() else {
                return;
            };
            let Some(row) = reviewing
                .review
                .saved_queries()
                .iter()
                .find(|row| row.reference == reference)
            else {
                return;
            };
            if reviewing.selection.wants_query(row) != included {
                reviewing.selection.set_included(included, reference);
            }
        }
        // Even an unchanged choice is drawn again, so a box always shows what the plan imports.
        self.refresh_review();
    }

    // Each change can move another row: a Replace one row takes is withdrawn from the others, and a
    // query follows whether its connection imports.
    fn refresh_review(&self) {
        let imp = self.imp();
        let reviewing = imp.reviewing.borrow();
        let Some(reviewing) = reviewing.as_ref() else {
            return;
        };
        let planned = plan(&reviewing.review, &reviewing.selection);
        for (widgets, row) in reviewing.connections.iter().zip(reviewing.review.connections()) {
            let selected = reviewing.selection.is_selected(&row.reference);
            if widgets.check.is_active() != selected {
                widgets.check.set_active(selected);
            }
            if let Some(drop_down) = &widgets.resolution {
                let offered = reviewing.selection.offered_resolutions(row);
                if *widgets.offered.borrow() != offered {
                    drop_down.set_model(Some(&resolution_list(&offered)));
                    widgets.offered.replace(offered.clone());
                }
                let current = reviewing.selection.resolution(&row.reference);
                if let Some(index) = current
                    .and_then(|choice| offered.iter().position(|offer| *offer == choice))
                    .and_then(|index| u32::try_from(index).ok())
                    .filter(|index| drop_down.selected() != *index)
                {
                    drop_down.set_selected(index);
                }
                drop_down.set_sensitive(selected && offered.len() > 1);
                drop_down.set_visible(selected);
            }
        }
        for (widgets, row) in reviewing.queries.iter().zip(reviewing.review.saved_queries()) {
            let status = planned.query_status(&row.reference);
            // A name another row takes on the same connection waits until that row is unchecked.
            let importable = status.is_some_and(|status| status.availability == QueryAvailability::Available);
            let included = status.is_some_and(|status| status.included);
            widgets.row.set_sensitive(importable);
            if widgets.check.is_active() != included {
                widgets.check.set_active(included);
            }
            widgets.row.set_subtitle(&wording::query_subtitle(row, status));
        }
        let connections = reviewing.review.connections();
        let selected = connections
            .iter()
            .filter(|row| reviewing.selection.is_selected(&row.reference))
            .count();
        let mut summary = ngettext_f(
            "{selected} of {n} connection selected",
            "{selected} of {n} connections selected",
            connections.len(),
            &[
                ("selected", &selected.to_string()),
                ("n", &connections.len().to_string()),
            ],
        );
        if !reviewing.queries.is_empty() {
            let included = planned
                .query_statuses()
                .values()
                .filter(|status| status.included)
                .count();
            summary.push('\n');
            summary.push_str(&ngettext_f(
                "{included} of {n} saved query selected",
                "{included} of {n} saved queries selected",
                reviewing.queries.len(),
                &[
                    ("included", &included.to_string()),
                    ("n", &reviewing.queries.len().to_string()),
                ],
            ));
        }
        imp.summary_label.set_label(&summary);
        imp.import_button.set_sensitive(!planned.is_empty());
    }

    fn on_import(&self) {
        let Some(reviewing) = self.imp().reviewing.take() else {
            return;
        };
        let planned = plan(&reviewing.review, &reviewing.selection);
        if planned.is_empty() {
            self.imp().reviewing.replace(Some(reviewing));
            return;
        }
        if let Some(parts) = self.parts() {
            (parts.on_import)(reviewing.review, planned);
        }
        self.close();
    }
}

fn resolution_list(offered: &[Resolution]) -> gtk::StringList {
    let titles: Vec<String> = offered
        .iter()
        .map(|choice| wording::resolution_title(*choice))
        .collect();
    let titles: Vec<&str> = titles.iter().map(String::as_str).collect();
    gtk::StringList::new(&titles)
}
