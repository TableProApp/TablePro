//! One key's value, a window at a time: what type it is, how long it is
//! and when it expires, its entries in a read-only grid, and Load More
//! for the next window.

mod key_summary;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::column::ResultColumn;
use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyWindow};
use tablepro_core::meta::KeyKind;
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::ui::export::{ExportOffer, ExportOrigin, ExportSource};
use crate::ui::grid::{GridMsg, GridSink, RowObject, build_result_grid, present_row_json};
use crate::ui::tab_load::{ContentLoad, ContentPage, FirstLoad, LoadFailure, LoadPresentation, StaleBanner};

pub(crate) use self::key_summary::key_kind_name;

const LOADING: &str = "loading";
const CONTENT: &str = "content";
const ERROR: &str = "error";

/// What a key tab asks of the workspace around it.
#[derive(Debug)]
pub(crate) enum KeyTabEvent {
    Toast(String),
    Export(Box<ExportOffer>),
    LoadingChanged(bool),
}

/// Where a key tab sends its events.
type EventSink = Box<dyn Fn(KeyTabEvent)>;

pub(crate) struct KeyTabInit {
    /// The key's name as the sidebar lists it.
    pub key: String,
    pub session: Arc<Session>,
    pub tasks: Tasks,
    pub first_load: FirstLoad,
}

#[derive(Clone)]
pub(crate) struct KeyTab {
    inner: Rc<Inner>,
}

struct Inner {
    key: String,
    session: Arc<Session>,
    tasks: Tasks,
    root: gtk::Box,
    stack: gtk::Stack,
    error: adw::StatusPage,
    banner: StaleBanner,
    type_label: gtk::Label,
    summary: gtk::Label,
    body: adw::Bin,
    footer: gtk::Label,
    more: gtk::Button,
    state: RefCell<State>,
    events: RefCell<Option<EventSink>>,
    shut_down: Cell<bool>,
}

#[derive(Default)]
struct State {
    load: ContentLoad,
    /// Counts the reads asked for, so only the last one lands.
    read: u64,
    tab_loading: bool,
    /// What the grid on screen holds.
    shown: Option<Shown>,
}

struct Shown {
    columns: Arc<[ResultColumn]>,
    store: gio::ListStore,
    rows: u64,
    length: Option<u64>,
    next: Option<KeyCursor>,
    appending: bool,
}

/// Whether a read starts the value again or adds the next window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReadMode {
    Replace,
    Append,
}

impl KeyTab {
    pub(crate) fn new(init: KeyTabInit) -> Self {
        let KeyTabInit {
            key,
            session,
            tasks,
            first_load,
        } = init;
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let banner_widget = adw::Banner::new(&crate::i18n::gettext("This key could not be read again."));
        root.append(&banner_widget);
        let stack = gtk::Stack::new();
        stack.set_vexpand(true);
        root.append(&stack);
        let spinner = adw::Spinner::builder()
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .width_request(32)
            .height_request(32)
            .build();
        stack.add_named(&spinner, Some(LOADING));
        let error = adw::StatusPage::builder()
            .icon_name(crate::ui::icons::DIALOG_ERROR)
            .title(crate::i18n::gettext("Could Not Read the Key"))
            .build();
        let retry = gtk::Button::builder()
            .label(crate::i18n::gettext("Try Again"))
            .halign(gtk::Align::Center)
            .build();
        retry.add_css_class("pill");
        error.set_child(Some(&retry));
        stack.add_named(&error, Some(ERROR));
        let (content, parts) = content_page();
        stack.add_named(&content, Some(CONTENT));

        let inner = Rc::new_cyclic(|this: &Weak<Inner>| {
            let banner = StaleBanner::new(banner_widget, {
                let this = this.clone();
                move || reload(&this)
            });
            Inner {
                key,
                session,
                tasks,
                root,
                stack,
                error,
                banner,
                type_label: parts.type_label,
                summary: parts.summary,
                body: parts.body,
                footer: parts.footer,
                more: parts.more,
                state: RefCell::new(State::default()),
                events: RefCell::new(None),
                shut_down: Cell::new(false),
            }
        });
        let weak = Rc::downgrade(&inner);
        retry.connect_clicked(move |_| reload(&weak));
        let weak = Rc::downgrade(&inner);
        parts.refresh.connect_clicked(move |_| reload(&weak));
        let weak = Rc::downgrade(&inner);
        inner.more.connect_clicked(move |_| load_more(&weak));
        let weak = Rc::downgrade(&inner);
        crate::ui::tab_load::start_first_load(&inner.root, first_load, move || reload(&weak));
        Self { inner }
    }

    pub(crate) fn widget(&self) -> &gtk::Box {
        &self.inner.root
    }

    pub(crate) fn key(&self) -> &str {
        &self.inner.key
    }

    pub(crate) fn is_loading(&self) -> bool {
        self.inner.state.borrow().tab_loading
    }

    /// Where the tab sends what it asks of the workspace. The workspace
    /// holds the tab, so `events` holds the workspace's queue, not it.
    pub(crate) fn connect_events(&self, events: impl Fn(KeyTabEvent) + 'static) {
        self.inner.events.replace(Some(Box::new(events)));
    }

    /// Read the key again from its first window.
    pub(crate) fn refresh(&self) {
        reload(&Rc::downgrade(&self.inner));
    }

    /// Drop what a read still on its way would show.
    pub(crate) fn shutdown(&self) {
        self.inner.shut_down.set(true);
        self.inner.events.replace(None);
    }
}

struct ContentParts {
    type_label: gtk::Label,
    summary: gtk::Label,
    refresh: gtk::Button,
    body: adw::Bin,
    footer: gtk::Label,
    more: gtk::Button,
}

/// The key's type and what it holds over its entries, and how many of
/// them the tab holds under them.
fn content_page() -> (gtk::Box, ContentParts) {
    let page = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_start(12)
        .margin_end(6)
        .margin_top(6)
        .margin_bottom(6)
        .build();
    let type_label = gtk::Label::builder().xalign(0.0).build();
    type_label.add_css_class("heading");
    let summary = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    summary.add_css_class("dimmed");
    let refresh = gtk::Button::builder().icon_name(crate::ui::icons::VIEW_REFRESH).build();
    refresh.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&refresh, &crate::i18n::gettext("Refresh"), None);
    header.append(&type_label);
    header.append(&summary);
    header.append(&refresh);
    let body = adw::Bin::builder().vexpand(true).build();
    let footer_bar = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_start(12)
        .margin_end(6)
        .margin_top(4)
        .margin_bottom(4)
        .build();
    let footer = gtk::Label::builder().xalign(0.0).hexpand(true).build();
    footer.add_css_class("dimmed");
    footer.add_css_class("caption");
    let more = gtk::Button::builder()
        .label(crate::i18n::gettext("Load More"))
        .visible(false)
        .build();
    more.add_css_class("flat");
    footer_bar.append(&footer);
    footer_bar.append(&more);
    page.append(&header);
    page.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    page.append(&body);
    page.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    page.append(&footer_bar);
    (
        page,
        ContentParts {
            type_label,
            summary,
            refresh,
            body,
            footer,
            more,
        },
    )
}

/// Read the key from its first window, keeping what is on screen until
/// the read lands.
fn reload(this: &Weak<Inner>) {
    let Some(inner) = this.upgrade() else {
        return;
    };
    let presentation = inner.state.borrow_mut().load.begin();
    inner.present(presentation);
    inner.read(KeyWindow::first(), ReadMode::Replace);
}

fn load_more(this: &Weak<Inner>) {
    let Some(inner) = this.upgrade() else {
        return;
    };
    let next = {
        let mut state = inner.state.borrow_mut();
        let Some(shown) = state.shown.as_mut().filter(|shown| !shown.appending) else {
            return;
        };
        let Some(next) = shown.next.clone() else {
            return;
        };
        shown.appending = true;
        next
    };
    inner.more.set_sensitive(false);
    inner.set_tab_loading(true);
    inner.read(KeyWindow::after(next), ReadMode::Append);
}

impl Inner {
    fn read(self: &Rc<Self>, window: KeyWindow, mode: ReadMode) {
        let read = {
            let mut state = self.state.borrow_mut();
            state.read += 1;
            state.read
        };
        let (session, key) = (self.session.clone(), self.key.clone());
        let work = async move {
            session
                .run(OperationKind::Page, move |lease, options| {
                    let (key, window) = (key.clone(), window.clone());
                    async move {
                        lease
                            .read_key(&key, &window, options)
                            .await
                            .map_err(OperationError::from)
                    }
                })
                .await
        };
        let this = Rc::downgrade(self);
        crate::runtime::spawn_and_deliver(&self.tasks, work, move |joined| {
            let outcome = joined.unwrap_or_else(|failure| Err(OperationError::from(failure)));
            if let Some(inner) = this.upgrade() {
                inner.landed(read, mode, outcome);
            }
        });
    }

    fn landed(self: &Rc<Self>, read: u64, mode: ReadMode, outcome: Result<Option<KeyPage>, OperationError>) {
        if self.shut_down.get() || read != self.state.borrow().read {
            return;
        }
        let presentation = match outcome {
            Ok(Some(page)) => {
                match mode {
                    ReadMode::Replace => self.show(page),
                    ReadMode::Append => self.append(page),
                }
                self.state.borrow_mut().load.succeed()
            }
            Ok(None) => self.fail(LoadFailure::KeyMissing),
            Err(error) => self.fail(LoadFailure::Page(Arc::new(error))),
        };
        self.present(presentation);
    }

    fn fail(&self, failure: LoadFailure) -> LoadPresentation {
        let mut state = self.state.borrow_mut();
        if let Some(shown) = state.shown.as_mut() {
            shown.appending = false;
        }
        state.load.fail(failure)
    }

    /// The key's first window, in a grid of its own: another type than
    /// the last read has other columns.
    fn show(self: &Rc<Self>, page: KeyPage) {
        let kind = key_kind_name(page.kind);
        self.type_label.set_label(&kind);
        let parts: Vec<String> = [
            page.length.and_then(|length| key_summary::length_text(page.kind, length)),
            Some(key_summary::ttl_text(page.ttl)),
        ]
        .into_iter()
        .flatten()
        .collect();
        self.summary.set_label(&parts.join(" · "));
        if page.kind == KeyKind::Other {
            self.body.set_child(Some(&unreadable_type(&page.type_name)));
            self.footer.set_label("");
            self.more.set_visible(false);
            self.state.borrow_mut().shown = None;
            return;
        }
        let columns = page.rows.columns.clone();
        let cut = (page.kind == KeyKind::String && page.rows.truncated)
            .then(|| (cell_bytes(page.rows.cell(0, 0)), page.length.unwrap_or_default()));
        let rows: Vec<RowObject> = page
            .rows
            .rows
            .into_iter()
            .map(|cells| RowObject::result(cells.into()))
            .collect();
        let count = rows.len() as u64;
        let (view, selection) = build_result_grid(columns.clone(), rows, self.grid_sink(), false);
        view.update_property(&[gtk::accessible::Property::Label(&self.key)]);
        let store = store_of(&selection);
        let scrolled = gtk::ScrolledWindow::builder()
            .child(&view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.body.set_child(Some(&scrolled));
        let Some(store) = store else {
            return;
        };
        self.state.borrow_mut().shown = Some(Shown {
            columns,
            store,
            rows: count,
            length: page.length,
            next: page.next,
            appending: false,
        });
        match cut {
            Some((read, total)) => {
                self.footer.set_label(&crate::i18n::gettext_f(
                    "Only the first {read} of {total} are read.",
                    &[
                        ("read", glib::format_size(read).as_ref()),
                        ("total", glib::format_size(total).as_ref()),
                    ],
                ));
                self.more.set_visible(false);
            }
            None => self.show_footer(page.kind),
        }
    }

    fn append(&self, page: KeyPage) {
        let kind = page.kind;
        {
            let mut state = self.state.borrow_mut();
            let Some(shown) = state.shown.as_mut() else {
                return;
            };
            let rows: Vec<RowObject> = page
                .rows
                .rows
                .into_iter()
                .map(|cells| RowObject::result(cells.into()))
                .collect();
            shown.rows += rows.len() as u64;
            shown.store.splice(shown.store.n_items(), 0, &rows);
            shown.length = page.length;
            shown.next = page.next;
            shown.appending = false;
        }
        self.show_footer(kind);
    }

    /// How many entries the tab holds, of how many. A string is one
    /// value and says nothing.
    fn show_footer(&self, kind: KeyKind) {
        let state = self.state.borrow();
        let Some(shown) = state.shown.as_ref() else {
            return;
        };
        let text = match kind {
            KeyKind::String => String::new(),
            _ => key_summary::shown_text(shown.rows, shown.length),
        };
        self.footer.set_label(&text);
        self.more.set_visible(shown.next.is_some());
        self.more.set_sensitive(!shown.appending);
    }

    /// The grid's copies, its row as JSON and its export.
    fn grid_sink(self: &Rc<Self>) -> GridSink {
        let this = Rc::downgrade(self);
        Rc::new(move |message| {
            let Some(inner) = this.upgrade() else {
                return;
            };
            match message {
                GridMsg::Copy(request) => {
                    let toasts = Rc::downgrade(&inner);
                    crate::ui::clipboard::copy_rows(&inner.root, &inner.tasks, request, move |text| {
                        if let Some(inner) = toasts.upgrade() {
                            inner.emit(KeyTabEvent::Toast(text.to_owned()));
                        }
                    });
                }
                GridMsg::ShowRowJson(request) => {
                    let (parent, tasks) = (inner.root.clone().upcast(), inner.tasks.clone());
                    glib::spawn_future_local(async move { present_row_json(parent, tasks, request).await });
                }
                GridMsg::ShowToast(text) => inner.emit(KeyTabEvent::Toast(text)),
                GridMsg::ExportResults(rows) => inner.export(rows),
                _ => {}
            }
        })
    }

    fn export(&self, rows: ExportSource) {
        let columns = self.state.borrow().shown.as_ref().map(|shown| shown.columns.clone());
        if columns.is_none() {
            return;
        }
        self.emit(KeyTabEvent::Export(Box::new(ExportOffer {
            origin: ExportOrigin::Shown { rows },
            session: None,
            name: self.key.clone(),
            target: None,
        })));
    }

    fn present(&self, presentation: LoadPresentation) {
        match &presentation.page {
            ContentPage::Spinner => self.stack.set_visible_child_name(LOADING),
            ContentPage::Content => self.stack.set_visible_child_name(CONTENT),
            ContentPage::Error(failure) => {
                // The page reads its description as markup.
                self.error
                    .set_description(Some(&glib::markup_escape_text(&failure.message())));
                self.stack.set_visible_child_name(ERROR);
            }
        }
        self.banner.show(presentation.stale.as_ref());
        let appending = self
            .state
            .borrow()
            .shown
            .as_ref()
            .is_some_and(|shown| shown.appending);
        self.set_tab_loading(presentation.tab_loading || appending);
    }

    fn set_tab_loading(&self, loading: bool) {
        let changed = {
            let mut state = self.state.borrow_mut();
            let changed = state.tab_loading != loading;
            state.tab_loading = loading;
            changed
        };
        if changed {
            self.emit(KeyTabEvent::LoadingChanged(loading));
        }
    }

    fn emit(&self, event: KeyTabEvent) {
        if let Some(events) = self.events.borrow().as_ref() {
            events(event);
        }
    }
}

/// The bytes a string's cell holds.
fn cell_bytes(cell: Option<&tablepro_core::Value>) -> u64 {
    match cell {
        Some(tablepro_core::Value::Text(text)) => text.len() as u64,
        Some(tablepro_core::Value::Bytes(bytes)) => bytes.len() as u64,
        _ => 0,
    }
}

/// The store a result grid's rows are in, under its sorter.
fn store_of(selection: &gtk::MultiSelection) -> Option<gio::ListStore> {
    let model = selection.model()?;
    if let Ok(store) = model.clone().downcast::<gio::ListStore>() {
        return Some(store);
    }
    model
        .downcast::<gtk::SortListModel>()
        .ok()?
        .model()?
        .downcast::<gio::ListStore>()
        .ok()
}

/// A module's type, such as a JSON document, which the tab names and
/// leaves to the editor.
fn unreadable_type(type_name: &str) -> adw::StatusPage {
    adw::StatusPage::builder()
        .icon_name(crate::ui::icons::TEXT_X_GENERIC)
        .title(crate::i18n::gettext("No Viewer for This Type"))
        .description(glib::markup_escape_text(&crate::i18n::gettext_f(
            "TablePro does not read values of type {type}. Read it with the module's own commands in a query tab.",
            &[("type", type_name)],
        )))
        .build()
}

#[cfg(test)]
impl KeyTab {
    pub(crate) fn shown_page(&self) -> Option<String> {
        self.inner.stack.visible_child_name().map(|name| name.to_string())
    }

    pub(crate) fn type_text(&self) -> String {
        self.inner.type_label.label().to_string()
    }

    pub(crate) fn summary_text(&self) -> String {
        self.inner.summary.label().to_string()
    }

    pub(crate) fn footer_text(&self) -> String {
        self.inner.footer.label().to_string()
    }

    pub(crate) fn error_text(&self) -> Option<String> {
        self.inner.error.description().map(|text| text.to_string())
    }

    /// The rows the grid holds.
    pub(crate) fn rows(&self) -> u32 {
        self.inner
            .state
            .borrow()
            .shown
            .as_ref()
            .map_or(0, |shown| shown.store.n_items())
    }

    pub(crate) fn offers_more(&self) -> bool {
        self.inner.more.is_visible() && self.inner.more.is_sensitive()
    }

    pub(crate) fn load_more(&self) {
        self.inner.more.emit_clicked();
    }
}
