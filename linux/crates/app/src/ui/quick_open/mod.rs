mod matching;
mod search_index;
#[cfg(test)]
mod tests;

use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::{ObjectKind, ObjectScope};
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{ObjectListSnapshot, Session};

use crate::i18n::{gettext, gettext_f};
use crate::runtime::{RequestSequencer, spawn_and_deliver};
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::icons;
pub(crate) use search_index::Target;
use search_index::{Candidate, SearchIndex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Pick {
    pub(crate) target: Target,
    pub(crate) structure: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Request {
    Index,
    Search,
}

struct Context {
    session: Arc<Session>,
    tasks: Tasks,
    chosen: Rc<dyn Fn(Pick)>,
}

struct Widgets {
    entry: gtk::SearchEntry,
    store: gio::ListStore,
    selection: gtk::SingleSelection,
    list: gtk::ListView,
    stack: gtk::Stack,
    status: adw::StatusPage,
    banner: adw::Banner,
}

glib::wrapper! {
    pub struct QuickOpen(ObjectSubclass<imp::QuickOpen>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

mod imp {
    use super::*;
    use gtk4::subclass::prelude::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default)]
    pub struct QuickOpen {
        pub(super) widgets: OnceCell<Widgets>,
        pub(super) context: RefCell<Option<Context>>,
        pub(super) watches: RefCell<Vec<WatchForwarder>>,
        pub(super) requests: RefCell<RequestSequencer<Request>>,
        pub(super) index: RefCell<Arc<SearchIndex>>,
        pub(super) generation: Cell<Option<u64>>,
        pub(super) rendered: RefCell<Option<String>>,
        pub(super) pending_pick: Cell<Option<bool>>,
        pub(super) pending_steps: RefCell<Vec<i32>>,
        pub(super) scroll_layout: RefCell<Option<HandlerGuard>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for QuickOpen {
        const NAME: &'static str = "TableProQuickOpen";
        type Type = super::QuickOpen;
        type ParentType = adw::Dialog;
    }

    impl ObjectImpl for QuickOpen {
        fn dispose(&self) {
            self.obj().stop();
        }
    }
    impl WidgetImpl for QuickOpen {}
    impl AdwDialogImpl for QuickOpen {}
}

impl QuickOpen {
    pub(crate) fn new(session: Arc<Session>, tasks: Tasks, chosen: impl Fn(Pick) + 'static) -> Self {
        let dialog: Self = glib::Object::new();
        dialog.set_title(&gettext("Open Quickly"));
        dialog.set_content_width(520);
        dialog.set_content_height(440);
        dialog.build();
        dialog.imp().context.replace(Some(Context {
            session: session.clone(),
            tasks,
            chosen: Rc::new(chosen),
        }));
        dialog.connect_closed(|dialog| dialog.stop());
        let weak = dialog.downgrade();
        let catalog = WatchForwarder::new(
            session.subscribe_objects(ObjectScope::AllSchemas),
            move |snapshot| {
                if let Some(dialog) = weak.upgrade() {
                    dialog.catalog_changed(snapshot);
                }
            },
            spawn_local,
        );
        let weak = dialog.downgrade();
        let mut link = *session.link_changes().borrow();
        let reconnect = WatchForwarder::new(
            session.link_changes(),
            move |generation| {
                if generation != link {
                    link = generation;
                    if let Some(dialog) = weak.upgrade() {
                        dialog.load(false);
                    }
                }
            },
            spawn_local,
        );
        dialog.imp().watches.replace(vec![catalog, reconnect]);
        dialog.load(false);
        dialog
    }

    fn build(&self) {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let selection = gtk::SingleSelection::new(Some(store.clone()));
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Tables and views"))]);
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();
        let status = adw::StatusPage::builder()
            .title(gettext("Loading Tables and Views"))
            .build();
        status.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.set_vexpand(true);
        stack.add_named(&scrolled, Some("list"));
        stack.add_named(&status, Some("status"));
        stack.set_visible_child_name("status");
        let entry = gtk::SearchEntry::builder()
            .placeholder_text(gettext("Search tables and views"))
            .hexpand(true)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(&gettext("Search tables and views"))]);
        let banner = adw::Banner::builder()
            .title(gettext("Could not load tables and views."))
            .button_label(gettext("Retry"))
            .revealed(false)
            .build();
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        body.append(&entry);
        body.append(&banner);
        body.append(&stack);
        let view = adw::ToolbarView::new();
        view.add_top_bar(&adw::HeaderBar::new());
        view.set_content(Some(&body));
        self.set_child(Some(&view));
        self.set_focus(Some(&entry));
        self.connect_controls(&entry, &list, &banner, &view);
        self.connect_scroll_layout(&list);
        let _ = self.imp().widgets.set(Widgets {
            entry,
            store,
            selection,
            list,
            stack,
            status,
            banner,
        });
    }

    fn connect_controls(
        &self,
        entry: &gtk::SearchEntry,
        list: &gtk::ListView,
        banner: &adw::Banner,
        view: &adw::ToolbarView,
    ) {
        entry.connect_changed(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| {
                dialog.imp().pending_pick.set(None);
                dialog.imp().pending_steps.borrow_mut().clear();
                dialog.imp().requests.borrow_mut().cancel(Request::Search);
            }
        ));
        entry.connect_search_changed(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.search()
        ));
        entry.connect_activate(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.activate(false)
        ));
        entry.connect_stop_search(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.dismiss()
        ));
        entry.connect_next_match(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.step(1)
        ));
        entry.connect_previous_match(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.step(-1)
        ));
        list.connect_activate(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_, position| {
                if !dialog.current() {
                    dialog.search();
                    return;
                }
                if let Some(widgets) = dialog.imp().widgets.get() {
                    widgets.selection.set_selected(position);
                }
                dialog.activate(false);
            }
        ));
        banner.connect_button_clicked(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.load(true)
        ));
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        keys.connect_key_pressed(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            #[upgrade_or]
            glib::Propagation::Proceed,
            move |_, key, _, modifiers| dialog.key(key, modifiers)
        ));
        view.add_controller(keys);
    }

    fn connect_scroll_layout(&self, list: &gtk::ListView) {
        list.connect_map(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| dialog.scroll_selection_after_layout()
        ));
        list.connect_unmap(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_| {
                dialog.imp().scroll_layout.borrow_mut().take();
            }
        ));
    }

    fn scroll_selection_after_layout(&self) {
        let imp = self.imp();
        if imp.context.borrow().is_none() || imp.scroll_layout.borrow().is_some() {
            return;
        }
        let Some(widgets) = imp.widgets.get().filter(|widgets| widgets.list.is_mapped()) else {
            return;
        };
        let Some(surface) = widgets.list.native().and_then(|native| native.surface()) else {
            return;
        };
        // GtkNative's earlier layout handler allocates rows before scrolling reads their geometry.
        let handler = surface.connect_layout(glib::clone!(
            #[weak(rename_to=dialog)]
            self,
            move |_, _, _| dialog.scroll_allocated_selection()
        ));
        imp.scroll_layout.replace(Some(HandlerGuard::new(&surface, handler)));
        widgets.list.queue_allocate();
        surface.request_layout();
    }

    fn scroll_allocated_selection(&self) {
        let imp = self.imp();
        let Some(widgets) = imp.widgets.get() else {
            return;
        };
        if imp.context.borrow().is_none() || !widgets.list.is_mapped() || !self.current() {
            imp.scroll_layout.borrow_mut().take();
            return;
        }
        let allocated = widgets
            .list
            .hadjustment()
            .is_some_and(|adjustment| adjustment.page_size() > 0.0)
            && widgets
                .list
                .vadjustment()
                .is_some_and(|adjustment| adjustment.page_size() > 0.0);
        if !allocated {
            return;
        }
        imp.scroll_layout.borrow_mut().take();
        let selected = widgets.selection.selected();
        if selected < widgets.store.n_items() {
            widgets.list.scroll_to(selected, gtk::ListScrollFlags::NONE, None);
        }
    }

    fn key(&self, key: gdk::Key, modifiers: gdk::ModifierType) -> glib::Propagation {
        let matches = |action| crate::application::component_matches(action, key, modifiers);
        if matches("quick-open.structure") {
            self.activate(true);
        } else if self.entry_has_focus() && matches("quick-open.next") {
            self.step(1);
        } else if self.entry_has_focus() && matches("quick-open.previous") {
            self.step(-1);
        } else {
            return glib::Propagation::Proceed;
        }
        glib::Propagation::Stop
    }

    fn entry_has_focus(&self) -> bool {
        self.imp().widgets.get().is_some_and(|w| {
            self.focus()
                .is_some_and(|focus| focus == w.entry || focus.is_ancestor(&w.entry))
        })
    }

    pub(crate) fn dismiss(&self) {
        self.stop();
        if self.parent().is_some() {
            self.close();
        }
    }

    fn stop(&self) {
        self.imp().scroll_layout.borrow_mut().take();
        self.imp().context.borrow_mut().take();
        self.imp().watches.borrow_mut().clear();
        self.imp().requests.borrow_mut().cancel_all();
        self.imp().pending_pick.set(None);
        self.imp().pending_steps.borrow_mut().clear();
    }

    fn load(&self, refresh: bool) {
        let Some((session, tasks)) = self
            .imp()
            .context
            .borrow()
            .as_ref()
            .map(|context| (context.session.clone(), context.tasks.clone()))
        else {
            return;
        };
        if refresh {
            self.imp().generation.set(None);
        }
        let weak = self.downgrade();
        spawn_and_deliver(
            &tasks,
            async move {
                if refresh {
                    session.refresh_objects(ObjectScope::AllSchemas).await
                } else {
                    session.objects(ObjectScope::AllSchemas).await
                }
            },
            move |result| {
                if let Err(error) = result {
                    tracing::warn!(%error, "could not load quick open catalog");
                    if let Some(dialog) = weak.upgrade() {
                        dialog.search_failed();
                    }
                }
            },
        );
    }

    fn catalog_changed(&self, snapshot: ObjectListSnapshot) {
        let imp = self.imp();
        if imp.context.borrow().is_none() {
            return;
        }
        let Some(widgets) = imp.widgets.get() else {
            return;
        };
        widgets.banner.set_revealed(snapshot.last_error.is_some());
        if snapshot.generation == 0 {
            if snapshot.last_error.is_some() {
                widgets.status.set_title(&gettext("Could Not Load Tables and Views"));
                widgets
                    .status
                    .set_description(Some(&gettext("Use Retry to try again.")));
            }
            return;
        }
        if imp.generation.replace(Some(snapshot.generation)) == Some(snapshot.generation) {
            return;
        }
        imp.requests.borrow_mut().cancel(Request::Search);
        let ticket = imp.requests.borrow_mut().issue(Request::Index);
        let Some(tasks) = imp.context.borrow().as_ref().map(|context| context.tasks.clone()) else {
            return;
        };
        let running = tasks.spawn_blocking_task(move || SearchIndex::tables(&snapshot.objects));
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let result = running.await;
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            if !dialog.imp().requests.borrow_mut().accept(Request::Index, ticket.stamp) {
                return;
            }
            match result {
                Ok(index) => {
                    dialog.imp().index.replace(Arc::new(index));
                    dialog.search();
                }
                Err(error) => {
                    tracing::warn!(%error, "could not index quick open results");
                    dialog.search_failed();
                }
            }
        });
    }

    fn search(&self) {
        let imp = self.imp();
        let Some(widgets) = imp.widgets.get() else {
            return;
        };
        let Some(tasks) = imp.context.borrow().as_ref().map(|context| context.tasks.clone()) else {
            return;
        };
        if imp.requests.borrow().is_pending(Request::Index)
            || imp.requests.borrow().is_pending(Request::Search)
            || imp.generation.get().is_none()
        {
            return;
        }
        let text = widgets.entry.text().to_string();
        let ticket = imp.requests.borrow_mut().issue(Request::Search);
        let index = imp.index.borrow().clone();
        let query = text.clone();
        let running = tasks.spawn_blocking_task(move || index.search(&query));
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let result = running.await;
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            if !dialog.imp().requests.borrow_mut().accept(Request::Search, ticket.stamp) {
                return;
            }
            match result {
                Ok(found) => dialog.show_results(text, found),
                Err(error) => {
                    tracing::warn!(%error, "could not search quick open results");
                    dialog.search_failed();
                }
            }
        });
    }

    fn search_failed(&self) {
        self.imp().rendered.replace(None);
        self.imp().pending_pick.set(None);
        self.imp().pending_steps.borrow_mut().clear();
        if let Some(widgets) = self.imp().widgets.get() {
            widgets.banner.set_revealed(true);
        }
    }

    fn selected(&self) -> Option<Candidate> {
        let widgets = self.imp().widgets.get()?;
        widgets
            .selection
            .selected_item()
            .and_downcast::<glib::BoxedAnyObject>()
            .map(|item| item.borrow::<Candidate>().clone())
    }

    fn show_results(&self, text: String, found: Vec<Candidate>) {
        let imp = self.imp();
        let Some(widgets) = imp.widgets.get() else {
            return;
        };
        let previous = (imp.rendered.borrow().as_deref() == Some(text.as_str()))
            .then(|| self.selected())
            .flatten()
            .map(|candidate| candidate.target());
        let selected = previous
            .and_then(|target| found.iter().position(|candidate| candidate.target() == target))
            .unwrap_or(0);
        let items: Vec<_> = found.into_iter().map(glib::BoxedAnyObject::new).collect();
        widgets.store.splice(0, widgets.store.n_items(), &items);
        widgets.selection.set_selected(if items.is_empty() {
            gtk::INVALID_LIST_POSITION
        } else {
            u32::try_from(selected).unwrap_or(0)
        });
        if items.is_empty() {
            widgets.status.set_title(&gettext("No Matches"));
            widgets
                .status
                .set_description(Some(&gettext("No table or view matches what you typed.")));
        }
        widgets
            .stack
            .set_visible_child_name(if items.is_empty() { "status" } else { "list" });
        imp.rendered.replace(Some(text));
        if !items.is_empty() {
            self.scroll_selection_after_layout();
        }
        let steps = std::mem::take(&mut *imp.pending_steps.borrow_mut());
        for by in steps {
            self.step(by);
        }
        if let Some(structure) = imp.pending_pick.take() {
            self.activate(structure);
        }
    }

    fn current(&self) -> bool {
        let imp = self.imp();
        imp.widgets
            .get()
            .is_some_and(|widgets| imp.rendered.borrow().as_deref() == Some(widgets.entry.text().as_str()))
            && !imp.requests.borrow().is_pending(Request::Index)
            && !imp.requests.borrow().is_pending(Request::Search)
    }

    fn activate(&self, structure: bool) {
        if self.imp().context.borrow().is_none() {
            return;
        }
        if !self.current() {
            self.imp().pending_pick.set(Some(structure));
            self.search();
            return;
        }
        let Some(candidate) = self.selected() else {
            return;
        };
        let chosen = {
            let context = self.imp().context.borrow();
            let Some(context) = context.as_ref() else {
                return;
            };
            if structure
                && (!candidate.object.kind.is_structure_editable()
                    || !context
                        .session
                        .current_dialect()
                        .is_some_and(|dialect| dialect.ddl().is_some()))
            {
                return;
            }
            context.chosen.clone()
        };
        let pick = Pick {
            target: candidate.target(),
            structure,
        };
        self.dismiss();
        chosen(pick);
    }

    fn step(&self, by: i32) {
        if !self.current() {
            self.imp().pending_steps.borrow_mut().push(by);
            self.search();
            return;
        }
        let Some(widgets) = self.imp().widgets.get() else {
            return;
        };
        let count = widgets.selection.n_items();
        if count == 0 {
            return;
        }
        let current = i64::from(widgets.selection.selected().min(count - 1));
        let next = (current + i64::from(by)).clamp(0, i64::from(count) - 1);
        let position = u32::try_from(next).unwrap_or(0);
        widgets.selection.set_selected(position);
        self.scroll_selection_after_layout();
    }
}

fn spawn_local(future: futures::future::LocalBoxFuture<'static, ()>) {
    glib::spawn_future_local(future);
}
fn factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let icon = gtk::Image::new();
        icon.add_css_class("dimmed");
        icon.set_accessible_role(gtk::AccessibleRole::Presentation);
        let name = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let place = gtk::Label::builder()
            .xalign(1.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        place.add_css_class("dimmed");
        place.add_css_class("caption");
        let row = gtk::Box::builder()
            .spacing(10)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .margin_end(6)
            .build();
        row.append(&icon);
        row.append(&name);
        row.append(&place);
        item.set_child(Some(&row));
    });
    factory.connect_bind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(object), Some(row)) = (item.item().and_downcast::<glib::BoxedAnyObject>(), item.child()) else {
            return;
        };
        let object = object.borrow::<Candidate>().object.clone();
        let (Some(icon), Some(name), Some(place)) = (
            row.first_child().and_downcast::<gtk::Image>(),
            row.first_child()
                .and_then(|icon| icon.next_sibling())
                .and_downcast::<gtk::Label>(),
            row.last_child().and_downcast::<gtk::Label>(),
        ) else {
            return;
        };
        icon.set_icon_name(Some(match object.kind {
            ObjectKind::View | ObjectKind::MaterializedView => icons::VIEW_GRID,
            _ => icons::TABLE_RELATION,
        }));
        name.set_label(&object.name);
        place.set_label(object.schema.as_deref().unwrap_or_default());
        let kind = match object.kind {
            ObjectKind::View | ObjectKind::MaterializedView => gettext("View"),
            _ => gettext("Table"),
        };
        let described = match object.schema.as_deref() {
            Some(schema) => gettext_f(
                "{table}, {kind}, in {schema}",
                &[("table", &object.name), ("kind", &kind), ("schema", schema)],
            ),
            None => gettext_f("{table}, {kind}", &[("table", &object.name), ("kind", &kind)]),
        };
        item.set_accessible_label(&described);
    });
    factory
}
