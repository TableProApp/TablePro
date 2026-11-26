// One set of import pages for two hosts: the dialog reads the app the user picks, the guide each app it ticked.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::DriverRegistry;
use tablepro_foreign_import::review::{
    ConnectionRow, ImportPlan, ImportReview, ImportSelection, QueryAvailability, QueryRow, Resolution, plan,
};
use tablepro_foreign_import::{
    ForeignApp, ForeignAppDirs, ForeignImporter, ForeignSource, ImportRequest, PasswordSource, ScanDepth,
    SourceAvailability, preselect,
};
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_storage::ConnectionStore;
use tokio_util::sync::CancellationToken;

use super::wording;
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::runtime::spawn_and_deliver;
use crate::services::foreign_import::{
    ReadFailure, ReviewRead, SAVED_QUERY_BYTE_LIMIT, default_request, importer, look_for_apps_blocking,
};

pub(crate) const SOURCES: &str = "import-sources";
pub(crate) const READING: &str = "import-reading";
pub(crate) const FAILED: &str = "import-failed";
pub(crate) const REVIEW: &str = "import-review";

pub(crate) enum ImportPagesMode {
    PickOne,
    Queue(Vec<ForeignApp>),
}

pub(crate) type ImportRequested = Box<dyn Fn(ImportReview, ImportPlan)>;

pub(crate) struct ImportPagesInit {
    pub dirs: ForeignAppDirs,
    pub drivers: Arc<DriverRegistry>,
    pub connections: ConnectionStore,
    pub tasks: Tasks,
    pub mode: ImportPagesMode,
    pub on_import: ImportRequested,
    // Queue only: the user went past the app in front without importing it.
    pub on_cancel: Box<dyn Fn()>,
}

#[derive(Clone)]
pub(crate) struct ImportPages {
    inner: Rc<Inner>,
}

struct Inner {
    dirs: ForeignAppDirs,
    drivers: Arc<DriverRegistry>,
    connections: ConnectionStore,
    tasks: Tasks,
    mode: ImportPagesMode,
    on_import: ImportRequested,
    on_cancel: Box<dyn Fn()>,
    cancel: CancellationToken,
    // One read's own token, so cancelling it leaves the queue's later reads alive.
    read_cancel: RefCell<Option<CancellationToken>>,
    // The switches' own answers, kept while an app that cannot honour one is picked.
    wants_passwords: Cell<bool>,
    wants_queries: Cell<bool>,
    view: glib::WeakRef<adw::NavigationView>,
    // The host's pages under these, which every move keeps.
    base: RefCell<Vec<String>>,
    queued: Cell<usize>,
    sources: RefCell<Vec<SourceRow>>,
    reviewing: RefCell<Option<Reviewing>>,
    // Import takes the review, and its rows stay on the page until the next review clears them.
    review_rows: RefCell<ReviewRows>,
    widgets: Widgets,
}

#[derive(Default)]
struct ReviewRows {
    connections: Vec<adw::ActionRow>,
    queries: Vec<adw::ActionRow>,
}

struct Widgets {
    sources: adw::NavigationPage,
    continue_button: gtk::Button,
    sources_stack: gtk::Stack,
    apps_group: adw::PreferencesGroup,
    passwords_row: adw::SwitchRow,
    queries_row: adw::SwitchRow,
    reading: adw::NavigationPage,
    reading_status: adw::StatusPage,
    reading_cancel: gtk::Button,
    failed: adw::NavigationPage,
    failed_status: adw::StatusPage,
    failed_continue: gtk::Button,
    review: adw::NavigationPage,
    passwords_banner: adw::Banner,
    connections_group: adw::PreferencesGroup,
    queries_group: adw::PreferencesGroup,
    summary_label: gtk::Label,
    import_button: gtk::Button,
}

pub(super) struct SourceRow {
    pub(super) app: ForeignApp,
    pub(super) check: gtk::CheckButton,
    pub(super) row: adw::ActionRow,
    pub(super) available: bool,
}

pub(super) struct Reviewing {
    pub(super) review: ImportReview,
    pub(super) selection: ImportSelection,
    pub(super) connections: Vec<ConnectionWidgets>,
    pub(super) queries: Vec<QueryWidgets>,
}

pub(super) struct ConnectionWidgets {
    pub(super) reference: String,
    pub(super) row: adw::ActionRow,
    pub(super) check: gtk::CheckButton,
    pub(super) resolution: Option<gtk::DropDown>,
    // What the drop-down lists, which a Replace another row takes changes.
    offered: RefCell<Vec<Resolution>>,
}

#[derive(Clone)]
pub(super) struct QueryWidgets {
    pub(super) check: gtk::CheckButton,
    pub(super) row: adw::ActionRow,
}

fn suggested(label: &str) -> gtk::Button {
    let button = gtk::Button::builder().label(label).use_underline(true).build();
    button.add_css_class("suggested-action");
    button
}

fn page(tag: &str, title: &str, header: &adw::HeaderBar, content: &impl IsA<gtk::Widget>) -> adw::NavigationPage {
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(header);
    toolbar.set_content(Some(content));
    adw::NavigationPage::builder()
        .tag(tag)
        .title(title)
        .child(&toolbar)
        .build()
}

struct SourcesPage {
    page: adw::NavigationPage,
    continue_button: gtk::Button,
    stack: gtk::Stack,
    apps_group: adw::PreferencesGroup,
    passwords_row: adw::SwitchRow,
    queries_row: adw::SwitchRow,
}

fn sources_page() -> SourcesPage {
    let continue_button = suggested(&gettext("_Continue"));
    continue_button.set_sensitive(false);
    let header = adw::HeaderBar::new();
    header.pack_end(&continue_button);
    let spinner = adw::Spinner::builder()
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .width_request(32)
        .height_request(32)
        .build();
    let apps_group = adw::PreferencesGroup::builder()
        .title(gettext("Apps"))
        .description(gettext(
            "Connections are read from the app's own files and nothing is changed there.",
        ))
        .build();
    let passwords_row = adw::SwitchRow::builder()
        .title(gettext("Include _Passwords"))
        .use_underline(true)
        .active(true)
        .build();
    let queries_row = adw::SwitchRow::builder()
        .title(gettext("Include Saved _Queries"))
        .use_underline(true)
        .active(true)
        .build();
    let options = adw::PreferencesGroup::new();
    options.add(&passwords_row);
    options.add(&queries_row);
    let list = adw::PreferencesPage::new();
    list.add(&apps_group);
    list.add(&options);
    let scan_failed = adw::StatusPage::builder()
        .icon_name("dialog-warning-symbolic")
        .title(gettext("Other Apps Could Not Be Looked For"))
        .description(gettext(
            "The search stopped before it finished. Close this and try again.",
        ))
        .build();
    let stack = gtk::Stack::new();
    stack.add_named(&spinner, Some("loading"));
    stack.add_named(&list, Some("sources"));
    stack.add_named(&scan_failed, Some("scan-failed"));
    let page = page(SOURCES, &gettext("Import from Another App"), &header, &stack);
    SourcesPage {
        page,
        continue_button,
        stack,
        apps_group,
        passwords_row,
        queries_row,
    }
}

struct ReviewPage {
    page: adw::NavigationPage,
    passwords_banner: adw::Banner,
    connections_group: adw::PreferencesGroup,
    queries_group: adw::PreferencesGroup,
    summary_label: gtk::Label,
    import_button: gtk::Button,
}

fn review_page() -> ReviewPage {
    let passwords_banner = adw::Banner::new("");
    let connections_group = adw::PreferencesGroup::builder().title(gettext("Connections")).build();
    let queries_group = adw::PreferencesGroup::builder()
        .title(gettext("Saved Queries"))
        .visible(false)
        .build();
    let review_list = adw::PreferencesPage::new();
    review_list.add(&connections_group);
    review_list.add(&queries_group);
    let summary_label = gtk::Label::builder().xalign(0.0).wrap(true).build();
    summary_label.add_css_class("dim-label");
    let import_button = suggested(&gettext("_Import"));
    let actions = gtk::ActionBar::new();
    actions.pack_start(&summary_label);
    actions.pack_end(&import_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.add_top_bar(&passwords_banner);
    toolbar.set_content(Some(&review_list));
    toolbar.add_bottom_bar(&actions);
    let page = adw::NavigationPage::builder()
        .tag(REVIEW)
        .title(gettext("Review"))
        .child(&toolbar)
        .build();
    ReviewPage {
        page,
        passwords_banner,
        connections_group,
        queries_group,
        summary_label,
        import_button,
    }
}

impl Widgets {
    fn build(queue: bool) -> Self {
        let sources = sources_page();

        let reading_status = adw::StatusPage::builder().title(gettext("Reading Connections")).build();
        reading_status.set_paintable(Some(&adw::SpinnerPaintable::new(Some(&reading_status))));
        // The guide has no close button to stop a slow read, so its read gets Cancel; a write never does.
        let reading_cancel = gtk::Button::with_mnemonic(&gettext("_Cancel"));
        reading_cancel.set_visible(false);
        let reading_header = adw::HeaderBar::new();
        reading_header.pack_start(&reading_cancel);
        let reading = page(
            READING,
            &gettext("Reading Connections"),
            &reading_header,
            &reading_status,
        );
        reading.set_can_pop(false);

        let failed_continue = suggested(&gettext("_Continue"));
        failed_continue.set_visible(queue);
        let header = adw::HeaderBar::new();
        header.pack_end(&failed_continue);
        let failed_status = adw::StatusPage::builder()
            .icon_name("dialog-warning-symbolic")
            .title(gettext("Nothing Imported"))
            .build();
        let failed = page(FAILED, &gettext("Nothing Imported"), &header, &failed_status);

        let review = review_page();

        Self {
            sources: sources.page,
            continue_button: sources.continue_button,
            sources_stack: sources.stack,
            apps_group: sources.apps_group,
            passwords_row: sources.passwords_row,
            queries_row: sources.queries_row,
            reading,
            reading_status,
            reading_cancel,
            failed,
            failed_status,
            failed_continue,
            review: review.page,
            passwords_banner: review.passwords_banner,
            connections_group: review.connections_group,
            queries_group: review.queries_group,
            summary_label: review.summary_label,
            import_button: review.import_button,
        }
    }

    fn pages(&self) -> [&adw::NavigationPage; 4] {
        [&self.sources, &self.reading, &self.failed, &self.review]
    }
}

impl ImportPages {
    pub(crate) fn new(init: ImportPagesInit) -> Self {
        let queue = matches!(init.mode, ImportPagesMode::Queue(_));
        let pages = Self {
            inner: Rc::new(Inner {
                dirs: init.dirs,
                drivers: init.drivers,
                connections: init.connections,
                tasks: init.tasks,
                mode: init.mode,
                on_import: init.on_import,
                on_cancel: init.on_cancel,
                cancel: CancellationToken::new(),
                read_cancel: RefCell::new(None),
                wants_passwords: Cell::new(true),
                wants_queries: Cell::new(true),
                view: glib::WeakRef::new(),
                base: RefCell::new(Vec::new()),
                queued: Cell::new(0),
                sources: RefCell::new(Vec::new()),
                reviewing: RefCell::new(None),
                review_rows: RefCell::new(ReviewRows::default()),
                widgets: Widgets::build(queue),
            }),
        };
        pages.connect_signals();
        pages
    }

    fn widgets(&self) -> &Widgets {
        &self.inner.widgets
    }

    fn weak(&self) -> Weak<Inner> {
        Rc::downgrade(&self.inner)
    }

    fn upgrade(weak: &Weak<Inner>) -> Option<Self> {
        weak.upgrade().map(|inner| Self { inner })
    }

    fn is_queue(&self) -> bool {
        matches!(self.inner.mode, ImportPagesMode::Queue(_))
    }

    pub(crate) fn attach(&self, view: &adw::NavigationView) {
        for page in self.widgets().pages() {
            view.add(page);
        }
        self.inner.view.set(Some(view));
    }

    // Only while none of the pages is on the host's stack, which then drops them at once.
    pub(crate) fn detach(&self) {
        self.cancel();
        if let Some(view) = self.inner.view.upgrade() {
            for page in self.widgets().pages() {
                view.remove(page);
            }
        }
    }

    pub(crate) fn cancel(&self) {
        self.inner.cancel.cancel();
    }

    pub(crate) fn start(&self) {
        let Some(view) = self.inner.view.upgrade() else {
            return;
        };
        match &self.inner.mode {
            ImportPagesMode::PickOne => {
                self.inner.base.replace(Vec::new());
                self.widgets().sources_stack.set_visible_child_name("loading");
                self.show_top(SOURCES);
                self.load_sources();
            }
            ImportPagesMode::Queue(apps) => {
                self.inner.base.replace(stack_tags(&view));
                self.inner.queued.set(0);
                if let Some(app) = apps.first() {
                    self.read_queued(*app);
                }
            }
        }
    }

    pub(crate) fn next(&self) -> bool {
        let ImportPagesMode::Queue(apps) = &self.inner.mode else {
            return false;
        };
        let position = self.inner.queued.get() + 1;
        self.inner.queued.set(position);
        match apps.get(position) {
            Some(app) => {
                self.read_queued(*app);
                true
            }
            None => false,
        }
    }

    // The import pages a move shows on top of the host's own.
    fn show_top(&self, tag: &str) {
        let Some(view) = self.inner.view.upgrade() else {
            return;
        };
        let mut tags = self.inner.base.borrow().clone();
        if !self.is_queue() {
            tags.push(SOURCES.to_owned());
        }
        if tag != SOURCES {
            tags.push(tag.to_owned());
        }
        let tags: Vec<&str> = tags.iter().map(String::as_str).collect();
        view.replace_with_tags(&tags);
    }

    fn connect_signals(&self) {
        let widgets = self.widgets();
        let weak = self.weak();
        widgets.continue_button.connect_clicked(move |_| {
            if let Some(pages) = Self::upgrade(&weak) {
                pages.on_continue();
            }
        });
        let weak = self.weak();
        widgets.import_button.connect_clicked(move |_| {
            if let Some(pages) = Self::upgrade(&weak) {
                pages.on_import();
            }
        });
        let weak = self.weak();
        widgets.failed_continue.connect_clicked(move |_| {
            if let Some(pages) = Self::upgrade(&weak) {
                (pages.inner.on_cancel)();
            }
        });
        let weak = self.weak();
        widgets.reading_cancel.connect_clicked(move |_| {
            if let Some(pages) = Self::upgrade(&weak) {
                if let Some(token) = pages.inner.read_cancel.take() {
                    token.cancel();
                }
                (pages.inner.on_cancel)();
            }
        });
        let weak = self.weak();
        widgets.passwords_row.connect_active_notify(move |row| {
            if let Some(pages) = Self::upgrade(&weak).filter(|_| row.is_sensitive()) {
                pages.inner.wants_passwords.set(row.is_active());
            }
        });
        let weak = self.weak();
        widgets.queries_row.connect_active_notify(move |row| {
            if let Some(pages) = Self::upgrade(&weak).filter(|_| row.is_sensitive()) {
                pages.inner.wants_queries.set(row.is_active());
            }
        });
    }

    fn load_sources(&self) {
        let dirs = self.inner.dirs.clone();
        let blocking = self.inner.tasks.clone();
        let weak = self.weak();
        spawn_and_deliver(
            &self.inner.tasks,
            async move {
                blocking
                    .spawn_blocking_task(move || look_for_apps_blocking(&dirs, ScanDepth::Inventory))
                    .await
            },
            move |outcome| {
                if let Some(pages) = Self::upgrade(&weak) {
                    pages.sources_scanned(outcome.and_then(std::convert::identity));
                }
            },
        );
    }

    pub(super) fn sources_scanned(&self, scanned: Result<Vec<ForeignSource>, TaskFailure>) {
        match scanned {
            Ok(sources) => self.show_sources(&sources),
            Err(failure) => {
                tracing::warn!(%failure, "could not look for other apps");
                self.widgets().continue_button.set_sensitive(false);
                self.widgets().sources_stack.set_visible_child_name("scan-failed");
            }
        }
    }

    fn show_sources(&self, sources: &[ForeignSource]) {
        let widgets = self.widgets();
        for old in self.inner.sources.take() {
            widgets.apps_group.remove(&old.row);
        }
        let mut rows = Vec::with_capacity(sources.len());
        let mut leader: Option<gtk::CheckButton> = None;
        for source in sources {
            let check = gtk::CheckButton::builder().valign(gtk::Align::Center).build();
            if let Some(leader) = &leader {
                check.set_group(Some(leader));
            } else {
                leader = Some(check.clone());
            }
            let available = source.availability == SourceAvailability::Available;
            let row = adw::ActionRow::builder()
                .title(source.app.display_name())
                .subtitle(wording::source_subtitle(source))
                .use_markup(false)
                .activatable_widget(&check)
                .sensitive(available)
                .build();
            if let SourceAvailability::Unreadable(reason) = &source.availability {
                row.set_tooltip_text(Some(&reason.detail));
            }
            row.add_prefix(&check);
            let weak = self.weak();
            check.connect_toggled(move |check| {
                if let Some(pages) = Self::upgrade(&weak).filter(|_| check.is_active()) {
                    pages.update_options();
                }
            });
            widgets.apps_group.add(&row);
            rows.push(SourceRow {
                app: source.app,
                check,
                row,
                available,
            });
        }
        if let Some(app) = preselect(sources)
            && let Some(row) = rows.iter().find(|row| row.app == app)
        {
            row.check.set_active(true);
        }
        self.inner.sources.replace(rows);
        widgets.sources_stack.set_visible_child_name("sources");
        self.update_options();
    }

    fn selected_app(&self) -> Option<ForeignApp> {
        self.inner
            .sources
            .borrow()
            .iter()
            .find(|row| row.available && row.check.is_active())
            .map(|row| row.app)
    }

    fn update_options(&self) {
        let widgets = self.widgets();
        let app = self.selected_app();
        widgets.continue_button.set_sensitive(app.is_some());
        let Some(app) = app else {
            widgets.passwords_row.set_sensitive(false);
            widgets.queries_row.set_sensitive(false);
            return;
        };
        let passwords = wording::password_option(app);
        widgets.passwords_row.set_sensitive(passwords.offered);
        widgets
            .passwords_row
            .set_active(passwords.offered && self.inner.wants_passwords.get());
        widgets.passwords_row.set_subtitle(&passwords.subtitle);
        let queries = wording::saved_query_option(app);
        widgets.queries_row.set_sensitive(queries.offered);
        widgets
            .queries_row
            .set_active(queries.offered && self.inner.wants_queries.get());
        widgets.queries_row.set_subtitle(&queries.subtitle);
    }

    fn picked_request(&self, app: ForeignApp) -> ImportRequest {
        let widgets = self.widgets();
        // With the switch unavailable, a keychain app's passwords are still asked for, so the review says they stayed behind.
        let include_passwords = if widgets.passwords_row.is_sensitive() {
            widgets.passwords_row.is_active()
        } else {
            app.password_source() == PasswordSource::Keychain
        };
        ImportRequest {
            include_passwords,
            include_saved_queries: widgets.queries_row.is_sensitive() && widgets.queries_row.is_active(),
            saved_query_byte_limit: SAVED_QUERY_BYTE_LIMIT,
        }
    }

    fn on_continue(&self) {
        let Some(app) = self.selected_app() else {
            return;
        };
        self.read(app, self.picked_request(app));
    }

    fn read_queued(&self, app: ForeignApp) {
        self.read(app, default_request(app));
    }

    fn read(&self, app: ForeignApp, request: ImportRequest) {
        let importer = importer(app, &self.inner.dirs);
        match app.picked_file_extensions() {
            Some(extensions) => self.pick_file(importer, extensions, request),
            None => self.collect(importer, request),
        }
    }

    fn pick_file(&self, importer: ForeignImporter, extensions: &[&str], request: ImportRequest) {
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
        let window = self
            .inner
            .view
            .upgrade()
            .and_then(|view| view.root())
            .and_downcast::<gtk::Window>();
        let weak = self.weak();
        file_dialog.open(window.as_ref(), gio::Cancellable::NONE, move |picked| {
            let Some(pages) = Self::upgrade(&weak) else {
                return;
            };
            match picked.map(|file| file.path()) {
                Ok(Some(path)) => pages.collect(importer.with_file(path), request),
                Ok(None) => pages.show_failure(&gettext("Only files on this computer can be imported.")),
                // In the guide, no file chosen goes past the app; the dialog stays on its list.
                Err(_) if pages.is_queue() => (pages.inner.on_cancel)(),
                Err(_) => {}
            }
        });
    }

    fn collect(&self, importer: ForeignImporter, request: ImportRequest) {
        let widgets = self.widgets();
        let app = importer.app();
        widgets.reading.set_title(&gettext("Reading Connections"));
        widgets.reading_status.set_title(&gettext("Reading Connections"));
        widgets.reading_status.set_description(Some(&gettext_f(
            "Reading connections from {app}…",
            &[("app", app.display_name())],
        )));
        let token = self.inner.cancel.child_token();
        self.inner.read_cancel.replace(Some(token.clone()));
        widgets.reading_cancel.set_visible(self.is_queue());
        self.show_top(READING);
        let read = ReviewRead {
            importer,
            request,
            cancel: token.clone(),
            connections: self.inner.connections.clone(),
            drivers: self.inner.drivers.clone(),
            dirs: self.inner.dirs.clone(),
        };
        let blocking = self.inner.tasks.clone();
        let weak = self.weak();
        spawn_and_deliver(
            &self.inner.tasks,
            async move { blocking.spawn_blocking_task(move || read.run_blocking()).await },
            move |outcome| {
                let Some(pages) = Self::upgrade(&weak) else {
                    return;
                };
                if token.is_cancelled() {
                    return;
                }
                pages.inner.read_cancel.replace(None);
                match outcome {
                    Ok(Ok(Ok(review))) => pages.show_review(review),
                    Ok(Ok(Err(ReadFailure::Import(error)))) => {
                        pages.show_failure(&wording::collect_failure(app, &error));
                    }
                    Ok(Ok(Err(ReadFailure::Library(error)))) => {
                        tracing::warn!(%error, "could not read the saved connections to compare");
                        pages.show_failure(&gettext(
                            "Your saved connections could not be read, so nothing was imported.",
                        ));
                    }
                    Ok(Err(failure)) | Err(failure) => {
                        tracing::warn!(%failure, "the import read did not finish");
                        pages.show_failure(&gettext("The connections could not be read."));
                    }
                }
            },
        );
    }

    fn show_failure(&self, message: &str) {
        if self.inner.cancel.is_cancelled() {
            return;
        }
        self.widgets().failed_status.set_description(Some(message));
        self.show_top(FAILED);
    }

    fn show_review(&self, review: ImportReview) {
        if self.inner.cancel.is_cancelled() {
            return;
        }
        let widgets = self.widgets();
        let app = review.app();
        widgets
            .review
            .set_title(&gettext_f("Import from {app}", &[("app", app.display_name())]));
        match wording::password_banner(app, review.passwords()) {
            Some(text) => {
                widgets.passwords_banner.set_title(&text);
                widgets.passwords_banner.set_revealed(true);
            }
            None => widgets.passwords_banner.set_revealed(false),
        }
        let previous = self.inner.review_rows.take();
        for row in &previous.connections {
            widgets.connections_group.remove(row);
        }
        for row in &previous.queries {
            widgets.queries_group.remove(row);
        }

        let selection = ImportSelection::defaults(&review);
        let connections: Vec<ConnectionWidgets> = review
            .connections()
            .iter()
            .map(|row| self.connection_row(row, &selection))
            .collect();
        let queries: Vec<QueryWidgets> = review
            .saved_queries()
            .iter()
            .map(|row| self.query_row(row, &selection))
            .collect();
        widgets.queries_group.set_visible(!queries.is_empty());
        self.inner.review_rows.replace(ReviewRows {
            connections: connections.iter().map(|shown| shown.row.clone()).collect(),
            queries: queries.iter().map(|shown| shown.row.clone()).collect(),
        });
        self.inner.reviewing.replace(Some(Reviewing {
            review,
            selection,
            connections,
            queries,
        }));
        self.refresh_review();
        self.show_top(REVIEW);
    }

    fn connection_row(&self, row: &ConnectionRow, selection: &ImportSelection) -> ConnectionWidgets {
        let selectable = row.connection.is_some();
        let check = gtk::CheckButton::builder()
            .valign(gtk::Align::Center)
            .active(selection.is_selected(&row.reference))
            .sensitive(selectable)
            .build();
        let widget = adw::ActionRow::builder()
            .title(&row.name)
            .subtitle(wording::connection_subtitle(row, &self.inner.drivers))
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
            let weak = self.weak();
            drop_down.connect_selected_notify(move |drop_down| {
                if let Some(pages) = Self::upgrade(&weak) {
                    pages.on_resolution_changed(&reference, drop_down.selected());
                }
            });
            drop_down
        });
        let reference = row.reference.clone();
        let weak = self.weak();
        check.connect_toggled(move |check| {
            if let Some(pages) = Self::upgrade(&weak) {
                pages.on_connection_toggled(&reference, check.is_active());
            }
        });
        self.widgets().connections_group.add(&widget);
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
        let weak = self.weak();
        check.connect_toggled(move |check| {
            if let Some(pages) = Self::upgrade(&weak) {
                pages.on_query_toggled(&reference, check.is_active());
            }
        });
        self.widgets().queries_group.add(&widget);
        QueryWidgets { check, row: widget }
    }

    // A refresh sets widgets while it holds the review, and their signals land here: those are skipped.
    fn on_connection_toggled(&self, reference: &str, selected: bool) {
        {
            let Ok(mut reviewing) = self.inner.reviewing.try_borrow_mut() else {
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
            let Ok(mut reviewing) = self.inner.reviewing.try_borrow_mut() else {
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
            let Ok(mut reviewing) = self.inner.reviewing.try_borrow_mut() else {
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

    // Each change can move another row: a Replace one row takes leaves the others, and a query follows its connection.
    fn refresh_review(&self) {
        let widgets = self.widgets();
        let reviewing = self.inner.reviewing.borrow();
        let Some(reviewing) = reviewing.as_ref() else {
            return;
        };
        let planned = plan(&reviewing.review, &reviewing.selection);
        for (shown, row) in reviewing.connections.iter().zip(reviewing.review.connections()) {
            let selected = reviewing.selection.is_selected(&row.reference);
            if shown.check.is_active() != selected {
                shown.check.set_active(selected);
            }
            if let Some(drop_down) = &shown.resolution {
                let offered = reviewing.selection.offered_resolutions(row);
                if *shown.offered.borrow() != offered {
                    drop_down.set_model(Some(&resolution_list(&offered)));
                    shown.offered.replace(offered.clone());
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
        for (shown, row) in reviewing.queries.iter().zip(reviewing.review.saved_queries()) {
            let status = planned.query_status(&row.reference);
            // A name another row takes on the same connection waits until that row is unchecked.
            let importable = status.is_some_and(|status| status.availability == QueryAvailability::Available);
            let included = status.is_some_and(|status| status.included);
            shown.row.set_sensitive(importable);
            if shown.check.is_active() != included {
                shown.check.set_active(included);
            }
            shown.row.set_subtitle(&wording::query_subtitle(row, status));
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
        widgets.summary_label.set_label(&summary);
        if self.is_queue() {
            // With nothing ticked, the guide's button goes on to the next app.
            let label = if planned.is_empty() {
                gettext("_Continue")
            } else {
                gettext("_Import")
            };
            widgets.import_button.set_label(&label);
            widgets.import_button.set_sensitive(true);
        } else {
            widgets.import_button.set_sensitive(!planned.is_empty());
        }
    }

    fn on_import(&self) {
        let Some(reviewing) = self.inner.reviewing.take() else {
            return;
        };
        let planned = plan(&reviewing.review, &reviewing.selection);
        if planned.is_empty() {
            self.inner.reviewing.replace(Some(reviewing));
            if self.is_queue() {
                (self.inner.on_cancel)();
            }
            return;
        }
        if self.is_queue() {
            let widgets = self.widgets();
            let app = reviewing.review.app();
            widgets.reading.set_title(&gettext("Importing Connections"));
            widgets.reading_status.set_title(&gettext("Importing Connections"));
            widgets.reading_status.set_description(Some(&gettext_f(
                "Importing connections from {app}…",
                &[("app", app.display_name())],
            )));
            widgets.reading_cancel.set_visible(false);
            self.show_top(READING);
        }
        (self.inner.on_import)(reviewing.review, planned);
    }
}

#[cfg(test)]
impl ImportPages {
    pub(super) fn sources(&self) -> std::cell::Ref<'_, Vec<SourceRow>> {
        self.inner.sources.borrow()
    }

    pub(super) fn reviewing(&self) -> std::cell::Ref<'_, Option<Reviewing>> {
        self.inner.reviewing.borrow()
    }

    pub(super) fn sources_page(&self) -> Option<String> {
        self.widgets()
            .sources_stack
            .visible_child_name()
            .map(|name| name.to_string())
    }

    pub(super) fn continue_button(&self) -> gtk::Button {
        self.widgets().continue_button.clone()
    }

    pub(super) fn import_button(&self) -> gtk::Button {
        self.widgets().import_button.clone()
    }

    pub(super) fn reading_cancel(&self) -> gtk::Button {
        self.widgets().reading_cancel.clone()
    }

    pub(super) fn review_groups(&self) -> (adw::PreferencesGroup, adw::PreferencesGroup) {
        let widgets = self.widgets();
        (widgets.connections_group.clone(), widgets.queries_group.clone())
    }

    pub(super) fn show_sources_for_test(&self, sources: &[ForeignSource]) {
        self.show_sources(sources);
    }
}

fn stack_tags(view: &adw::NavigationView) -> Vec<String> {
    let stack = view.navigation_stack();
    (0..stack.n_items())
        .filter_map(|position| stack.item(position).and_downcast::<adw::NavigationPage>())
        .filter_map(|page| page.tag().map(|tag| tag.to_string()))
        .collect()
}

fn resolution_list(offered: &[Resolution]) -> gtk::StringList {
    let titles: Vec<String> = offered
        .iter()
        .map(|choice| wording::resolution_title(*choice))
        .collect();
    let titles: Vec<&str> = titles.iter().map(String::as_str).collect();
    gtk::StringList::new(&titles)
}
