// The setup guide, a page of the session window that ends with a connection open (core ADR 0057).

mod app_icon;
mod hero;
mod imp;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gio::prelude::SettingsExtManual;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::DriverRegistry;
use tablepro_foreign_import::review::{ImportPlan, ImportReview};
use tablepro_foreign_import::{ForeignApp, ForeignAppDirs, ForeignSource, ScanDepth, SourceAvailability};
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_storage::ConnectionStore;
use uuid::Uuid;

use super::handler_guard::HandlerGuard;
use super::import_from_app::{ImportPages, ImportPagesInit, ImportPagesMode, source_subtitle};
use crate::i18n::{gettext, gettext_f, ngettext_f, pgettext};
use crate::runtime::spawn_and_deliver;
use crate::services::foreign_import::look_for_apps_blocking;
use crate::services::setup_guide::{
    FirstConnectionChoice, OriginChoice, SetupEnding, SetupFlow, SetupStep, found_subtitle, import_source,
};
use crate::ui::icons;

const ORIGIN: &str = "setup-origin";
const IMPORT: &str = "setup-import";
const FIRST_CONNECTION: &str = "setup-first-connection";
const OPTIONS: &str = "setup-options";

pub(crate) type ImportDone = Box<dyn FnOnce(Vec<Uuid>)>;

pub(crate) struct SetupGuideInit {
    pub dirs: ForeignAppDirs,
    pub drivers: Arc<DriverRegistry>,
    pub connections: ConnectionStore,
    pub tasks: Tasks,
    pub settings: Rc<AppSettings>,
    // The window writes the plan and answers with the ids it wrote, which the guide's ending opens.
    pub on_import: Box<dyn Fn(ImportReview, ImportPlan, ImportDone)>,
    pub on_import_file: Box<dyn Fn()>,
    pub on_end: Box<dyn Fn(SetupEnding)>,
}

glib::wrapper! {
    pub struct SetupGuide(ObjectSubclass<imp::SetupGuide>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(super) struct Parts {
    init: SetupGuideInit,
    flow: RefCell<SetupFlow>,
    opened: Cell<Option<Instant>>,
    sources: RefCell<Vec<SourceRow>>,
    scanned: Cell<bool>,
    import: RefCell<Option<ImportPages>>,
    imported_apps: RefCell<Vec<ForeignApp>>,
    ended: Cell<bool>,
    scheme: RefCell<Option<HandlerGuard>>,
}

struct SourceRow {
    app: ForeignApp,
    connections: usize,
    check: gtk::CheckButton,
    row: adw::ActionRow,
}

impl SourceRow {
    // A row the guide could not read stays out of the queue whatever its box says.
    fn is_queued(&self) -> bool {
        self.row.is_sensitive() && self.check.is_active()
    }
}

fn tag(step: SetupStep) -> &'static str {
    match step {
        SetupStep::Origin => ORIGIN,
        SetupStep::Import => IMPORT,
        SetupStep::FirstConnection => FIRST_CONNECTION,
        SetupStep::Options => OPTIONS,
    }
}

fn step_of(tag: &str) -> Option<SetupStep> {
    match tag {
        ORIGIN => Some(SetupStep::Origin),
        IMPORT => Some(SetupStep::Import),
        FIRST_CONNECTION => Some(SetupStep::FirstConnection),
        OPTIONS => Some(SetupStep::Options),
        _ => None,
    }
}

// A picked file or an uncounted app has no total to promise, so the pill says Import alone.
fn import_label(ticked: usize, connections: usize) -> String {
    match (ticked, connections) {
        (0, _) => gettext("_Continue"),
        (_, 0) => gettext("_Import"),
        (_, n) => ngettext_f(
            "_Import {n} Connection",
            "_Import {n} Connections",
            n,
            &[("n", &n.to_string())],
        ),
    }
}

// The fallback glyph keeps the icon's 40 px slot, so every card's title starts at the same place.
fn app_art(app: ForeignApp) -> gtk::Image {
    let image = gtk::Image::builder()
        .pixel_size(40)
        .width_request(40)
        .height_request(40)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    match app_icon::app_icon(app) {
        Some(icon) => {
            image.set_from_gicon(&icon);
            image.add_css_class("icon-dropshadow");
        }
        None => {
            image.set_icon_name(Some(icons::APPLICATION_X_EXECUTABLE));
            image.set_pixel_size(32);
            image.add_css_class("dimmed");
        }
    }
    image
}

impl SetupGuide {
    pub(crate) fn new(init: SetupGuideInit) -> Self {
        let guide: Self = glib::Object::new();
        let settings = init.settings.clone();
        let _ = guide.imp().parts.set(Parts {
            init,
            flow: RefCell::new(SetupFlow::new()),
            opened: Cell::new(None),
            sources: RefCell::new(Vec::new()),
            scanned: Cell::new(false),
            import: RefCell::new(None),
            imported_apps: RefCell::new(Vec::new()),
            ended: Cell::new(false),
            scheme: RefCell::new(None),
        });
        guide.imp().origin_hero.set_icon_name(crate::config::APP_ID);
        guide.bind_options(&settings);
        guide.connect_signals();
        guide
    }

    fn parts(&self) -> Option<&Parts> {
        self.imp().parts.get()
    }

    pub(crate) fn toast_overlay(&self) -> adw::ToastOverlay {
        self.imp().toasts.get()
    }

    // Opens on the origin, where a probe that finds an app with data in time selects the other-app card.
    pub(crate) fn start(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        parts.opened.set(Some(Instant::now()));
        self.sync_stack();
        self.update_default_widget();
        let dirs = parts.init.dirs.clone();
        let blocking = parts.init.tasks.clone();
        let guide = self.downgrade();
        spawn_and_deliver(
            &parts.init.tasks,
            async move {
                blocking
                    .spawn_blocking_task(move || look_for_apps_blocking(&dirs, ScanDepth::Presence))
                    .await
            },
            move |outcome| {
                if let Some(guide) = guide.upgrade() {
                    guide.probe_answered(outcome.and_then(std::convert::identity));
                }
            },
        );
    }

    pub(crate) fn shutdown(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        parts.ended.set(true);
        if let Some(pages) = parts.import.take() {
            pages.cancel();
        }
        drop(parts.scheme.take());
    }

    fn probe_answered(&self, probed: Result<Vec<ForeignSource>, TaskFailure>) {
        let Some(parts) = self.parts().filter(|parts| !parts.ended.get()) else {
            return;
        };
        let probed = match probed {
            Ok(probed) => probed,
            Err(failure) => {
                tracing::warn!(%failure, "the look for other apps at launch did not finish");
                return;
            }
        };
        let elapsed = parts.opened.get().map_or(Duration::MAX, |opened| opened.elapsed());
        let subtitle = {
            let mut flow = parts.flow.borrow_mut();
            if !flow.probe_answered(elapsed, &probed) {
                return;
            }
            found_subtitle(flow.found())
        };
        let imp = self.imp();
        imp.from_app_row.set_subtitle(&subtitle);
        imp.from_app_check.set_active(true);
    }

    fn connect_signals(&self) {
        let imp = self.imp();
        for skip in [&imp.origin_skip, &imp.import_skip, &imp.first_skip, &imp.options_skip] {
            skip.connect_clicked(glib::clone!(
                #[weak(rename_to = guide)]
                self,
                move |_| guide.finish()
            ));
        }
        imp.finish_button.connect_clicked(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.finish()
        ));
        for (row, check, origin) in [
            (imp.from_app_row.get(), imp.from_app_check.get(), OriginChoice::OtherApp),
            (
                imp.from_file_row.get(),
                imp.from_file_check.get(),
                OriginChoice::ConnectionsFile,
            ),
            (imp.start_row.get(), imp.start_check.get(), OriginChoice::StartFresh),
        ] {
            check.connect_toggled(glib::clone!(
                #[weak(rename_to = guide)]
                self,
                move |check| {
                    if check.is_active() {
                        guide.origin_toggled(origin);
                    }
                }
            ));
            // Activating the card already selected changes nothing on screen, yet it is still the user's choice.
            row.connect_activated(glib::clone!(
                #[weak(rename_to = guide)]
                self,
                move |_| guide.choose_origin(origin)
            ));
        }
        imp.origin_continue.connect_clicked(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.on_origin_continue()
        ));
        imp.import_continue.connect_clicked(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.on_import_continue()
        ));
        imp.first_continue.connect_clicked(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.go_to(SetupStep::Options)
        ));
        // A choice counts as it is made, so Skip runs it as Finish does.
        for check in [imp.new_connection_check.get(), imp.sample_check.get()] {
            check.connect_toggled(glib::clone!(
                #[weak(rename_to = guide)]
                self,
                move |_| guide.record_first_choice()
            ));
        }
        imp.navigation.connect_popped(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_, page| guide.on_popped(page)
        ));
        imp.navigation.connect_visible_page_notify(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.update_default_widget()
        ));
    }

    // The probe writes the flow before it selects the card, so only a toggle by the user differs from it.
    fn origin_toggled(&self, origin: OriginChoice) {
        let Some(parts) = self.parts() else {
            return;
        };
        let mut flow = parts.flow.borrow_mut();
        if flow.origin() != origin {
            flow.choose_origin(origin);
        }
    }

    fn choose_origin(&self, origin: OriginChoice) {
        if let Some(parts) = self.parts() {
            parts.flow.borrow_mut().choose_origin(origin);
        }
    }

    // A click on a card only selects it, so the pill alone moves on, and Return has one target.
    fn on_origin_continue(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let origin = parts.flow.borrow_mut().continue_from_origin();
        match origin.next_step() {
            Some(step) => self.go_to(step),
            None => self.import_file(),
        }
    }

    // Return runs the pill of the step on screen; an import page pushed on top has buttons of its own.
    fn update_default_widget(&self) {
        let Some(window) = self.root().and_downcast::<gtk::Window>() else {
            return;
        };
        let pill = self
            .imp()
            .navigation
            .visible_page()
            .and_then(|page| page.tag())
            .and_then(|tag| step_of(&tag))
            .map(|step| self.pill(step));
        window.set_default_widget(pill.as_ref());
    }

    fn pill(&self, step: SetupStep) -> gtk::Button {
        let imp = self.imp();
        match step {
            SetupStep::Origin => imp.origin_continue.get(),
            SetupStep::Import => imp.import_continue.get(),
            SetupStep::FirstConnection => imp.first_continue.get(),
            SetupStep::Options => imp.finish_button.get(),
        }
    }

    // The options apply as they change, as Preferences does, so Skip on the last step loses nothing.
    fn bind_options(&self, settings: &Rc<AppSettings>) {
        let imp = self.imp();
        let gio_settings = settings.gio();
        gio_settings
            .bind(keys::VIM_KEYBINDINGS, &imp.vim_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::STYLE_SCHEME, &imp.system_style_row.get(), "active")
            .mapping(|variant, _| Some(variant.get::<String>()?.is_empty().to_value()))
            .set_mapping(|value, _| {
                let automatic = value.get::<bool>().ok()?;
                let id = if automatic {
                    ""
                } else if adw::StyleManager::default().is_dark() {
                    "Adwaita-dark"
                } else {
                    "Adwaita"
                };
                Some(id.to_variant())
            })
            .build();
        if let Some(parts) = self.parts() {
            parts.scheme.replace(Some(super::style_scheme_grid::populate(
                &imp.style_scheme_box.get(),
                settings,
            )));
        }
        crate::application::bind_preset_row(&imp.shortcuts_row.get(), gio_settings, &[]);
    }

    fn sync_stack(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let tags: Vec<&str> = parts.flow.borrow().shown().iter().map(|step| tag(*step)).collect();
        self.imp().navigation.replace_with_tags(&tags);
    }

    fn go_to(&self, step: SetupStep) {
        let Some(parts) = self.parts().filter(|parts| !parts.ended.get()) else {
            return;
        };
        parts.flow.borrow_mut().go_to(step);
        self.sync_stack();
        self.entered(step);
    }

    fn entered(&self, step: SetupStep) {
        match step {
            SetupStep::Import => self.scan_sources(),
            SetupStep::Options => {
                self.bind_presets();
                self.update_finish_label();
            }
            SetupStep::Origin | SetupStep::FirstConnection => {}
        }
    }

    // A user who pressed Back and went on again keeps the list and the ticks they made.
    fn scan_sources(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        if parts.scanned.replace(true) {
            return;
        }
        self.imp().import_stack.set_visible_child_name("loading");
        let dirs = parts.init.dirs.clone();
        let blocking = parts.init.tasks.clone();
        let guide = self.downgrade();
        spawn_and_deliver(
            &parts.init.tasks,
            async move {
                blocking
                    .spawn_blocking_task(move || look_for_apps_blocking(&dirs, ScanDepth::Inventory))
                    .await
            },
            move |outcome| {
                if let Some(guide) = guide.upgrade() {
                    guide.sources_scanned(outcome.and_then(std::convert::identity));
                }
            },
        );
    }

    fn sources_scanned(&self, scanned: Result<Vec<ForeignSource>, TaskFailure>) {
        let imp = self.imp();
        let Some(parts) = self.parts() else {
            return;
        };
        let sources = match scanned {
            Ok(sources) => sources,
            Err(failure) => {
                tracing::warn!(%failure, "could not look for other apps");
                imp.import_stack.set_visible_child_name("failed");
                return;
            }
        };
        for old in parts.sources.take() {
            imp.import_apps_group.remove(&old.row);
        }
        // An unreadable app keeps its card so a missing count is never hidden (core ADR 0057); an absent app is named.
        let (missing, found): (Vec<&ForeignSource>, Vec<&ForeignSource>) = sources
            .iter()
            .partition(|source| source.availability == SourceAvailability::NotFound);
        let rows: Vec<SourceRow> = found.into_iter().map(|source| self.source_row(source)).collect();
        for source in &rows {
            imp.import_apps_group.add(&source.row);
        }
        let names: Vec<&str> = missing.iter().map(|source| source.app.display_name()).collect();
        imp.not_found_label.set_label(&gettext_f(
            "Not found on this computer: {apps}",
            &[("apps", &names.join(&pgettext("list separator", ", ")))],
        ));
        imp.not_found_label.set_visible(!names.is_empty());
        let any = !rows.is_empty();
        parts.sources.replace(rows);
        self.update_import_label();
        imp.import_stack
            .set_visible_child_name(if any { "sources" } else { "empty" });
    }

    fn source_row(&self, source: &ForeignSource) -> SourceRow {
        let check = gtk::CheckButton::builder()
            .valign(gtk::Align::Center)
            .active(source.starts_ticked())
            .build();
        let row = adw::ActionRow::builder()
            .title(source.app.display_name())
            .subtitle(source_subtitle(source))
            .subtitle_lines(2)
            .use_markup(false)
            .activatable_widget(&check)
            .sensitive(source.availability == SourceAvailability::Available)
            .build();
        if let SourceAvailability::Unreadable(reason) = &source.availability {
            row.set_tooltip_text(Some(&reason.detail));
        }
        row.add_prefix(&app_art(source.app));
        row.add_suffix(&check);
        check.connect_toggled(glib::clone!(
            #[weak(rename_to = guide)]
            self,
            move |_| guide.update_import_label()
        ));
        SourceRow {
            app: source.app,
            connections: source.inventory.connections,
            check,
            row,
        }
    }

    fn update_import_label(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let (ticked, connections) = parts
            .sources
            .borrow()
            .iter()
            .filter(|source| source.is_queued())
            .fold((0, 0), |(ticked, connections), source| {
                (ticked + 1, connections + source.connections)
            });
        self.imp().import_continue.set_label(&import_label(ticked, connections));
    }

    fn on_import_continue(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let apps: Vec<ForeignApp> = parts
            .sources
            .borrow()
            .iter()
            .filter(|source| source.is_queued())
            .map(|source| source.app)
            .collect();
        if apps.is_empty() {
            self.go_to(SetupStep::FirstConnection);
            return;
        }
        if let Some(previous) = parts.import.take() {
            previous.detach();
        }
        let (importing, moving_on) = (self.downgrade(), self.downgrade());
        let pages = ImportPages::new(ImportPagesInit {
            dirs: parts.init.dirs.clone(),
            drivers: parts.init.drivers.clone(),
            connections: parts.init.connections.clone(),
            tasks: parts.init.tasks.clone(),
            mode: ImportPagesMode::Queue(apps),
            on_import: Box::new(move |review, plan| {
                if let Some(guide) = importing.upgrade() {
                    guide.import(review, plan);
                }
            }),
            on_cancel: Box::new(move || {
                if let Some(guide) = moving_on.upgrade() {
                    guide.next_app();
                }
            }),
        });
        pages.attach(&self.imp().navigation);
        parts.import.replace(Some(pages.clone()));
        pages.start();
    }

    // Each app's read waits for the write before it, so its review checks the library that write left.
    fn import(&self, review: ImportReview, plan: ImportPlan) {
        let Some(parts) = self.parts() else {
            return;
        };
        let app = review.app();
        let guide = self.downgrade();
        (parts.init.on_import)(
            review,
            plan,
            Box::new(move |ids: Vec<Uuid>| {
                let Some(guide) = guide.upgrade() else {
                    return;
                };
                if let Some(parts) = guide.parts() {
                    if !ids.is_empty() {
                        parts.imported_apps.borrow_mut().push(app);
                    }
                    parts.flow.borrow_mut().add_imported(&ids, import_source(app));
                }
                guide.next_app();
            }),
        );
    }

    fn next_app(&self) {
        let Some(parts) = self.parts().filter(|parts| !parts.ended.get()) else {
            return;
        };
        let pages = parts.import.borrow().clone();
        if pages.is_some_and(|pages| pages.next()) {
            return;
        }
        self.go_to(SetupStep::FirstConnection);
    }

    fn record_first_choice(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let imp = self.imp();
        let choice = if imp.new_connection_check.is_active() {
            Some(FirstConnectionChoice::NewConnection)
        } else if imp.sample_check.is_active() {
            Some(FirstConnectionChoice::Sample)
        } else {
            None
        };
        if let Some(choice) = choice {
            parts.flow.borrow_mut().record(choice);
        }
    }

    // The imported app's preset comes first, after TablePro's own.
    fn bind_presets(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let first: Vec<&'static str> = parts.imported_apps.borrow().iter().map(|app| app.id()).collect();
        crate::application::bind_preset_row(&self.imp().shortcuts_row.get(), parts.init.settings.gio(), &first);
    }

    fn update_finish_label(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        let ending = parts.flow.borrow().end();
        let label = match ending {
            SetupEnding::Open(_) => gettext("_Open Connection"),
            SetupEnding::Select(_) => gettext("_Show Connections"),
            SetupEnding::NewConnection => gettext("_Add Connection"),
            SetupEnding::Sample => gettext("_Open Sample"),
            SetupEnding::Stay => gettext("_Done"),
        };
        self.imp().finish_button.set_label(&label);
    }

    fn finish(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        if parts.ended.replace(true) {
            return;
        }
        if let Some(pages) = parts.import.borrow().as_ref() {
            pages.cancel();
        }
        let ending = parts.flow.borrow().end();
        (parts.init.on_end)(ending);
    }

    fn import_file(&self) {
        let Some(parts) = self.parts() else {
            return;
        };
        if parts.ended.replace(true) {
            return;
        }
        (parts.init.on_import_file)();
    }

    // Back, Escape and Alt+Left pop the page on top; a page an import pushed is not a step.
    fn on_popped(&self, page: &adw::NavigationPage) {
        let Some(parts) = self.parts() else {
            return;
        };
        let Some(step) = page.tag().and_then(|tag| step_of(&tag)) else {
            return;
        };
        let mut flow = parts.flow.borrow_mut();
        if flow.step() == step {
            flow.back();
        }
    }
}
