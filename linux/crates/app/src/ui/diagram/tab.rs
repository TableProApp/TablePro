use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_core::meta::TableRef;
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, OperationError, Session};
use tokio::sync::watch;
use uuid::Uuid;

use super::describe::diagram_label;
use super::fetch::{ReadProgress, read_diagram};
use super::layout::Point;
use super::model::SchemaDiagram;
use super::tab_imp as imp;
use super::{export, zoom};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::runtime::{FailedRequests, RequestSequencer, RequestTicket, Stamped};
use crate::ui::export::{ExportLedger, ImageExport};
use crate::ui::tab_load::{
    ContentLoad, ContentPage, FirstLoad, LoadFailure, LoadPresentation, StaleBanner, start_first_load,
};
use crate::workspace::DiagramPlace;

/// How far Alt+arrow moves a table, in diagram units.
const MOVE_STEP: f64 = 20.0;

glib::wrapper! {
    /// A schema's entity-relationship diagram, in a tab of its own.
    pub struct DiagramTab(ObjectSubclass<imp::DiagramTab>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) struct DiagramTabInit {
    /// `None` draws the default schema of an engine without schemas.
    pub schema: Option<String>,
    pub session: Arc<Session>,
    pub tasks: Tasks,
    /// The workspace's exports, which an image is written through.
    pub exports: Rc<ExportLedger>,
    /// The workspace's id for the tab, which hears how an export ended.
    pub tab_id: Uuid,
    pub first_load: FirstLoad,
    /// Where the user put tables before, for a restored or reopened tab.
    pub places: Vec<DiagramPlace>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum DiagramRequest {
    Tables,
}

pub(crate) struct DiagramModel {
    schema: Option<String>,
    session: Arc<Session>,
    tasks: Tasks,
    exports: Rc<ExportLedger>,
    tab_id: Uuid,
    pub(super) sequencer: RequestSequencer<DiagramRequest>,
    failed: FailedRequests<DiagramRequest>,
    /// The connection the running read was issued on.
    issued_on: Option<LinkGeneration>,
    link_generation: LinkGeneration,
    load: ContentLoad,
    /// Stop ended the read before anything was drawn.
    stopped: bool,
    /// What the tab bar was last told.
    tab_loading: bool,
    /// Where the user had put the tables of a restored or reopened tab,
    /// until its first diagram lands; from then on the canvas holds them.
    kept: Option<HashMap<String, Point>>,
    /// A table changed while the running read was under way, so what it
    /// brings may be out of date already.
    changed_during_read: bool,
    stale_banner: StaleBanner,
}

impl DiagramTab {
    pub(crate) fn new(init: DiagramTabInit) -> Self {
        let tab: Self = glib::Object::new();
        let imp = tab.imp();
        imp.canvas
            .update_property(&[gtk::accessible::Property::Label(&diagram_label(init.schema.as_deref()))]);
        let link_changes = init.session.link_changes();
        let weak = tab.downgrade();
        let stale_banner = StaleBanner::new(imp.stale_banner.get(), move || {
            if let Some(tab) = weak.upgrade() {
                tab.refresh();
            }
        });
        imp.model.replace(Some(DiagramModel {
            schema: init.schema,
            link_generation: init.session.link_generation(),
            session: init.session,
            tasks: init.tasks,
            exports: init.exports,
            tab_id: init.tab_id,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            issued_on: None,
            load: ContentLoad::default(),
            stopped: false,
            tab_loading: false,
            kept: points(&init.places),
            changed_during_read: false,
            stale_banner,
        }));
        tab.install_actions();
        tab.connect_canvas();
        tab.add_controller(local_shortcut_controller(ShortcutOwner::DiagramTab));
        imp.canvas
            .add_controller(local_shortcut_controller(ShortcutOwner::DiagramCanvas));
        let weak = tab.downgrade();
        imp.link_watch.replace(Some(WatchForwarder::new(
            link_changes,
            move |generation: LinkGeneration| {
                if let Some(tab) = weak.upgrade() {
                    tab.on_link_changed(generation);
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        tab.present(ContentLoad::default().presentation());
        let weak = tab.downgrade();
        start_first_load(&tab, init.first_load, move || {
            if let Some(tab) = weak.upgrade() {
                tab.read();
            }
        });
        tab
    }

    #[cfg(test)]
    pub(crate) fn schema(&self) -> Option<String> {
        self.with_model(|model| model.schema.clone()).flatten()
    }

    pub(crate) fn canvas(&self) -> super::canvas::DiagramCanvas {
        self.imp().canvas.get()
    }

    /// Read the schema's tables again, keeping the diagram on screen
    /// until the new one is drawn.
    pub(crate) fn refresh(&self) {
        self.read();
    }

    /// A table of the schema changed elsewhere, so the diagram may be out
    /// of date. Reading hundreds of tables again on every change would
    /// keep the pool busy, so the banner offers it.
    pub(crate) fn schema_changed(&self) {
        let imp = self.imp();
        self.with_model(|model| {
            if model.load.is_running() {
                model.changed_during_read = true;
            }
        });
        if imp.canvas.has_diagram() {
            imp.outdated_banner.set_revealed(true);
        }
    }

    /// Stop the read and follow no more reconnects, now rather than at
    /// dispose.
    pub fn shutdown(&self) {
        let imp = self.imp();
        imp.link_watch.take();
        imp.progress_watch.take();
        if let Ok(mut model) = imp.model.try_borrow_mut()
            && let Some(model) = model.as_mut()
        {
            model.sequencer.cancel_all();
        }
    }

    /// A read of the tables is running.
    pub fn is_loading(&self) -> bool {
        self.with_model(|model| model.tab_loading).unwrap_or(false)
    }

    pub fn connect_open_table<F: Fn(&Self, TableRef) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "open-table",
            false,
            glib::closure_local!(move |tab: &Self, schema: Option<String>, name: String| {
                f(tab, TableRef::new(schema, name));
            }),
        )
    }

    pub fn connect_show_structure<F: Fn(&Self, TableRef) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "show-structure",
            false,
            glib::closure_local!(move |tab: &Self, schema: Option<String>, name: String| {
                f(tab, TableRef::new(schema, name));
            }),
        )
    }

    /// The user moved a table, or put them all back, so the tab's record
    /// changed.
    pub fn connect_layout_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure("layout-changed", false, glib::closure_local!(move |tab: &Self| f(tab)))
    }

    /// Where the user put the tables, for the tab's record: none until one
    /// is moved, so the automatic layout places them all again.
    pub(crate) fn places(&self) -> Vec<DiagramPlace> {
        let canvas = self.canvas();
        let kept = match canvas.has_diagram() {
            true => canvas.kept_places(),
            false => self.with_model(|model| model.kept.clone()).flatten(),
        };
        let mut places: Vec<DiagramPlace> = kept
            .unwrap_or_default()
            .into_iter()
            .map(|(table, at)| DiagramPlace {
                table,
                x: whole(at.x),
                y: whole(at.y),
            })
            .collect();
        places.sort_by(|a, b| a.table.cmp(&b.table));
        places
    }

    pub fn connect_loading_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "loading-changed",
            false,
            glib::closure_local!(move |tab: &Self, loading: bool| f(tab, loading)),
        )
    }

    fn with_model<R>(&self, f: impl FnOnce(&mut DiagramModel) -> R) -> Option<R> {
        let mut model = self.imp().model.try_borrow_mut().ok()?;
        model.as_mut().map(f)
    }

    fn read(&self) {
        let started = self.with_model(|model| {
            let presentation = model.load.begin();
            model.stopped = false;
            model.changed_during_read = false;
            model.issued_on = Some(model.session.link_generation());
            let RequestTicket { stamp, cancel } = model.sequencer.issue(DiagramRequest::Tables);
            let (progress, watching) = watch::channel(ReadProgress::default());
            let work = read_diagram(model.session.clone(), model.schema.clone(), cancel, progress);
            (presentation, stamp, work, watching, model.tasks.clone())
        });
        let Some((presentation, stamp, work, watching, tasks)) = started else {
            return;
        };
        let weak = self.downgrade();
        self.imp().progress_watch.replace(Some(WatchForwarder::new(
            watching,
            move |progress: ReadProgress| {
                if let Some(tab) = weak.upgrade() {
                    tab.show_progress(progress);
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        let weak = self.downgrade();
        drop(crate::runtime::spawn_and_deliver(&tasks, work, move |joined| {
            let value =
                joined.unwrap_or_else(|failure| Err(LoadFailure::Schema(Arc::new(OperationError::from(failure)))));
            if let Some(tab) = weak.upgrade() {
                tab.on_read(Stamped { stamp, value });
            }
        }));
        self.present(presentation);
    }

    fn on_read(&self, reply: Stamped<Result<SchemaDiagram, LoadFailure>>) {
        let Stamped { stamp, value } = reply;
        let imp = self.imp();
        let loaded = imp.canvas.has_diagram();
        let accepted = self.with_model(|model| {
            if !model.sequencer.accept(DiagramRequest::Tables, stamp) {
                return None;
            }
            model.failed.record(DiagramRequest::Tables, &value);
            // A failed read leaves a restored tab's places for the next.
            let restored = (value.is_ok() && !loaded).then(|| model.kept.take()).flatten();
            Some((restored, model.changed_during_read))
        });
        let Some(Some((restored, changed))) = accepted else {
            return;
        };
        imp.progress_watch.take();
        match value {
            Ok(diagram) => {
                let tables = diagram.tables.len();
                // Where the tables are now, so a move or a Reset Layout made
                // while the read ran stands.
                let kept = match loaded {
                    true => imp.canvas.kept_places(),
                    false => restored,
                };
                let had_focus = crate::ui::a11y::holds_focus(&*imp.canvas);
                imp.canvas.set_diagram(diagram, kept);
                // A schema read again with no tables left has no card to
                // keep the keyboard on.
                if had_focus && tables == 0 {
                    imp.refresh_button.grab_focus();
                }
                imp.outdated_banner.set_revealed(changed);
                if let Some(presentation) = self.with_model(|model| model.load.succeed()) {
                    self.present(presentation);
                }
                crate::ui::a11y::announce(
                    self,
                    &crate::i18n::ngettext_f(
                        "Drew {n} table",
                        "Drew {n} tables",
                        u32::try_from(tables).unwrap_or(u32::MAX),
                        &[("n", &tables.to_string())],
                    ),
                    gtk::AccessibleAnnouncementPriority::Medium,
                );
            }
            Err(failure) => {
                let retry = self.with_model(|model| {
                    let presentation = model.load.fail(failure);
                    let moved_on = model
                        .issued_on
                        .is_some_and(|issued| model.session.link_generation() > issued);
                    (presentation, moved_on)
                });
                let Some((presentation, moved_on)) = retry else {
                    return;
                };
                self.present(presentation);
                if moved_on {
                    self.retry_failed();
                }
            }
        }
    }

    /// Stop the read. A diagram on screen stays; with none, the tab says
    /// the read stopped.
    fn stop(&self) {
        let presentation = self.with_model(|model| {
            model.sequencer.cancel(DiagramRequest::Tables);
            // A stopped read is not asked again on the next connection.
            model.failed.take();
            let presentation = model.load.abandon();
            model.stopped = !model.load.has_content();
            presentation
        });
        self.imp().progress_watch.take();
        if let Some(presentation) = presentation {
            self.present(presentation);
        }
    }

    pub(super) fn on_link_changed(&self, generation: LinkGeneration) {
        let newer = self.with_model(|model| {
            let newer = generation > model.link_generation;
            if newer {
                model.link_generation = generation;
            }
            newer
        });
        if newer == Some(true) {
            self.retry_failed();
        }
    }

    fn retry_failed(&self) {
        let failed = self.with_model(|model| model.failed.take().contains(&DiagramRequest::Tables));
        if failed == Some(true) {
            self.read();
        }
    }

    /// Show where the read stands: the progress, the diagram, or why it
    /// is not there.
    fn present(&self, presentation: LoadPresentation) {
        let imp = self.imp();
        let Some((stopped, running)) = self.with_model(|model| (model.stopped, model.load.is_running())) else {
            return;
        };
        let page = match &presentation.page {
            ContentPage::Spinner if stopped && !running => "stopped",
            ContentPage::Spinner => "loading",
            ContentPage::Content if imp.canvas.table_count() == 0 => "empty",
            ContentPage::Content => "diagram",
            ContentPage::Error(failure) => {
                imp.error_page
                    .set_description(Some(&glib::markup_escape_text(&failure.message())));
                "error"
            }
        };
        self.show_page(page);
        // An empty schema's page stays up while it is read again, so the
        // bar holds Stop for it too.
        let refreshing = running && imp.canvas.has_diagram();
        imp.refresh_box.set_visible(refreshing);
        let changed = self.with_model(|model| {
            model.stale_banner.show(presentation.stale.as_ref());
            let changed = model.tab_loading != presentation.tab_loading;
            model.tab_loading = presentation.tab_loading;
            changed
        });
        if changed == Some(true) {
            self.emit_by_name::<()>("loading-changed", &[&presentation.tab_loading]);
        }
        // Stop is on before the button takes it and off only after the
        // button lets it go: a button on a disabled action turns
        // insensitive and drops the keyboard focus.
        if refreshing {
            self.sync_actions();
            self.label_refresh_button(true);
        } else {
            self.label_refresh_button(false);
            self.sync_actions();
        }
    }

    /// Refresh, or Stop while a refresh runs. One button, so the keyboard
    /// stays on it either way.
    pub(super) fn label_refresh_button(&self, refreshing: bool) {
        let button = self.imp().refresh_button.get();
        let (icon, label, action) = match refreshing {
            true => (
                crate::ui::icons::PROCESS_STOP,
                crate::i18n::gettext("Stop"),
                "diagram.stop",
            ),
            false => (
                crate::ui::icons::VIEW_REFRESH,
                crate::i18n::gettext("Refresh"),
                "diagram.refresh",
            ),
        };
        if button.action_name().as_deref() == Some(action) {
            return;
        }
        button.set_icon_name(icon);
        button.set_action_name(Some(action));
        button.reset_property(gtk::AccessibleProperty::KeyShortcuts);
        crate::ui::a11y::describe_icon_button(&button, &label, Some(action));
    }

    fn show_page(&self, page: &str) {
        let imp = self.imp();
        if imp.inner_stack.visible_child_name().as_deref() == Some(page) {
            return;
        }
        // The page with the focus goes, so the focus goes somewhere a
        // keyboard user can carry on from rather than to the window.
        let had_focus = imp
            .inner_stack
            .visible_child()
            .is_some_and(|child| crate::ui::a11y::holds_focus(&child));
        imp.inner_stack.set_visible_child_name(page);
        if !had_focus {
            return;
        }
        match page {
            "diagram" => {
                let first = imp.canvas.selected().unwrap_or(0);
                imp.canvas.focus_table(first);
            }
            _ => {
                imp.refresh_button.grab_focus();
            }
        }
    }

    fn show_progress(&self, progress: ReadProgress) {
        let imp = self.imp();
        let text = match progress.total {
            0 => crate::i18n::gettext("Reading the list of tables…"),
            total => crate::i18n::ngettext_f(
                "{done} of {total} table read",
                "{done} of {total} tables read",
                u32::try_from(total).unwrap_or(u32::MAX),
                &[("done", &progress.done.to_string()), ("total", &total.to_string())],
            ),
        };
        imp.loading_page.set_description(Some(&glib::markup_escape_text(&text)));
        imp.refresh_label.set_label(&text);
        let fraction = match progress.total {
            0 => 0.0,
            total => progress.done as f64 / total as f64,
        };
        imp.loading_progress.set_fraction(fraction);
    }

    fn connect_canvas(&self) {
        let canvas = self.imp().canvas.get();
        let weak = self.downgrade();
        canvas.connect_zoom_changed(move |canvas| {
            if let Some(tab) = weak.upgrade() {
                tab.imp()
                    .zoom_reset_button
                    .set_label(&format!("{}%", zoom::percent(canvas.zoom())));
                tab.sync_actions();
            }
        });
        let weak = self.downgrade();
        canvas.connect_selection_changed(move |_| {
            if let Some(tab) = weak.upgrade() {
                tab.sync_actions();
            }
        });
        let weak = self.downgrade();
        canvas.connect_layout_changed(move |_| {
            if let Some(tab) = weak.upgrade() {
                tab.emit_by_name::<()>("layout-changed", &[]);
            }
        });
        let weak = self.downgrade();
        canvas.connect_table_activated(move |canvas, index| {
            if let (Some(tab), Some(table)) = (weak.upgrade(), canvas.table(index)) {
                tab.emit_table("open-table", &table);
            }
        });
    }

    fn emit_table(&self, signal: &str, table: &TableRef) {
        self.emit_by_name::<()>(signal, &[&table.schema, &table.name]);
    }

    fn install_actions(&self) {
        let group = gio::SimpleActionGroup::new();
        let add = |name: &str, act: fn(&DiagramTab)| {
            let action = gio::SimpleAction::new(name, None);
            let weak = self.downgrade();
            action.connect_activate(move |_, _| {
                if let Some(tab) = weak.upgrade() {
                    act(&tab);
                }
            });
            group.add_action(&action);
        };
        add("zoom-in", |tab| tab.canvas().zoom_in());
        add("zoom-out", |tab| tab.canvas().zoom_out());
        add("zoom-reset", |tab| tab.canvas().zoom_reset());
        add("zoom-fit", |tab| tab.canvas().zoom_fit());
        add("refresh", DiagramTab::refresh);
        add("stop", DiagramTab::stop);
        add("reset-layout", |tab| tab.canvas().reset_layout());
        add("open-table", |tab| tab.emit_selected("open-table"));
        add("show-structure", |tab| tab.emit_selected("show-structure"));
        add("context-menu", |tab| {
            let canvas = tab.canvas();
            if let Some(bounds) = canvas.selected().and_then(|index| canvas.card_bounds(index)) {
                super::canvas_input::popup_menu(&canvas, bounds);
            }
        });
        add("move-table-left", |tab| tab.canvas().move_selected(-MOVE_STEP, 0.0));
        add("move-table-right", |tab| tab.canvas().move_selected(MOVE_STEP, 0.0));
        add("move-table-up", |tab| tab.canvas().move_selected(0.0, -MOVE_STEP));
        add("move-table-down", |tab| tab.canvas().move_selected(0.0, MOVE_STEP));
        let export = gio::SimpleAction::new("export", Some(glib::VariantTy::STRING));
        let weak = self.downgrade();
        export.connect_activate(move |_, target| {
            let format = target
                .and_then(|target| target.get::<String>())
                .and_then(|name| export::ImageFormat::from_name(&name));
            if let (Some(tab), Some(format)) = (weak.upgrade(), format) {
                tab.export(format);
            }
        });
        group.add_action(&export);
        self.insert_action_group("diagram", Some(&group));
        self.imp().actions.replace(Some(group));
    }

    fn emit_selected(&self, signal: &str) {
        if let Some(table) = self.canvas().selected_table() {
            self.emit_table(signal, &table);
        }
    }

    /// Turn on what applies to the diagram on screen and its selection.
    fn sync_actions(&self) {
        let imp = self.imp();
        let shown = imp.inner_stack.visible_child_name().as_deref() == Some("diagram");
        let selected = shown && imp.canvas.selected().is_some();
        let running = self.with_model(|model| model.load.is_running()).unwrap_or(false);
        let zoom = imp.canvas.zoom();
        let states = [
            ("zoom-in", shown && zoom < zoom::MAX),
            ("zoom-out", shown && zoom > zoom::LEVELS[0]),
            ("zoom-reset", shown),
            ("zoom-fit", shown),
            ("reset-layout", shown),
            ("export", shown),
            ("stop", running),
            ("open-table", selected),
            ("show-structure", selected),
            ("context-menu", selected),
            ("move-table-left", selected),
            ("move-table-right", selected),
            ("move-table-up", selected),
            ("move-table-down", selected),
        ];
        let Some(group) = imp.actions.borrow().clone() else {
            return;
        };
        for (name, enabled) in states {
            if let Some(action) = group.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                action.set_enabled(enabled);
            }
        }
    }

    fn export(&self, format: export::ImageFormat) {
        let Some((schema, tasks, exports, tab_id)) = self.with_model(|model| {
            (
                model.schema.clone(),
                model.tasks.clone(),
                model.exports.clone(),
                model.tab_id,
            )
        }) else {
            return;
        };
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&format.filter_name()));
        filter.add_mime_type(format.mime_type());
        filter.add_suffix(format.name());
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Export Diagram"))
            .modal(true)
            .initial_name(format.suggested_name(schema.as_deref()))
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let window = self.root().and_downcast::<gtk::Window>();
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            // Cancelling the dialog is the only way it fails without a file.
            let Ok(file) = dialog.save_future(window.as_ref()).await else {
                return;
            };
            let Some(tab) = weak.upgrade() else {
                return;
            };
            // Drawn as the diagram is now, after the dialog closed. The
            // render nodes belong to the GTK thread; the encoding does not.
            let drawn = tab
                .canvas()
                .render()
                .ok_or(export::DrawError::Empty)
                .and_then(|(node, width, height)| export::draw(&node, width, height, format));
            let bytes =
                tasks.spawn_blocking_task(move || drawn.and_then(export::encode).map_err(|error| error.to_string()));
            let _started = exports.begin_image(ImageExport {
                destination: file,
                bytes,
                tab: Some(tab_id),
            });
        });
    }
}

/// A record's places as the canvas takes them, or `None` with none.
fn points(places: &[DiagramPlace]) -> Option<HashMap<String, Point>> {
    (!places.is_empty()).then(|| {
        places
            .iter()
            .map(|place| {
                let at = Point {
                    x: f64::from(place.x),
                    y: f64::from(place.y),
                };
                (place.table.clone(), at)
            })
            .collect()
    })
}

/// A place in whole units, as the record keeps it.
fn whole(value: f64) -> i32 {
    value.round().clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}
