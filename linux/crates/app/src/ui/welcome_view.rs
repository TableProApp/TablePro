//! The picker's saved connections: a preferences page bound to the list
//! every window shares, with a group for the connections in no group
//! and one for each group the user made.

use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionGroupName, ConnectionListState};
use uuid::Uuid;

use crate::services::connection_search::ConnectionSearch;
use crate::services::saved_connection_list::{SavedConnectionList, StateObserverId};
use crate::services::saved_connection_object::SavedConnectionObject;
use crate::ui::picker::{RowChoices, connection_row};

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/welcome-view.ui")]
    pub struct WelcomeView {
        #[template_child]
        pub stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub page: TemplateChild<adw::PreferencesPage>,
        #[template_child]
        pub ungrouped: TemplateChild<adw::PreferencesGroup>,
        pub(super) parts: OnceCell<super::Parts>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for WelcomeView {
        const NAME: &'static str = "TableProWelcomeView";
        type Type = super::WelcomeView;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for WelcomeView {
        fn dispose(&self) {
            self.obj().shutdown();
        }
    }

    impl WidgetImpl for WelcomeView {}
    impl BinImpl for WelcomeView {}
}

/// The first row under `root` that shows.
fn first_row(root: &gtk::Widget) -> Option<adw::ActionRow> {
    let mut child = root.first_child();
    while let Some(widget) = child {
        if widget.is_visible() {
            if let Some(row) = widget.downcast_ref::<adw::ActionRow>() {
                return Some(row.clone());
            }
            if let Some(row) = first_row(&widget) {
                return Some(row);
            }
        }
        child = widget.next_sibling();
    }
    None
}

/// The row under `root` whose activation connects to `target`.
fn row_for(root: &gtk::Widget, target: &str) -> Option<adw::ActionRow> {
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(row) = widget.downcast_ref::<adw::ActionRow>()
            && row
                .action_target_value()
                .and_then(|value| value.get::<String>())
                .is_some_and(|value| value == target)
        {
            return Some(row.clone());
        }
        if let Some(row) = row_for(&widget, target) {
            return Some(row);
        }
        child = widget.next_sibling();
    }
    None
}

glib::wrapper! {
    pub struct WelcomeView(ObjectSubclass<imp::WelcomeView>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(super) struct Parts {
    list: Rc<SavedConnectionList>,
    tasks: Option<Tasks>,
    /// The groups after the ungrouped one, by name, in list order.
    groups: RefCell<Vec<(ConnectionGroupName, adw::PreferencesGroup)>>,
    /// What the picker's search asks for; every section's filter reads it.
    search: Rc<RefCell<ConnectionSearch>>,
    /// The ungrouped section's filter, then each group's.
    filters: RefCell<Vec<gtk::CustomFilter>>,
    /// A connection whose row takes the focus once the list shows it.
    focus: Cell<Option<Uuid>>,
    rows_changed: RefCell<Option<glib::SignalHandlerId>>,
    state_changed: RefCell<Option<StateObserverId>>,
}

impl WelcomeView {
    /// A view of `list`. `tasks` reads the file a portal path stands for.
    pub(crate) fn new(list: Rc<SavedConnectionList>, tasks: Option<Tasks>) -> Self {
        let view: Self = glib::Object::new();
        let imp = view.imp();
        let _ = imp.parts.set(Parts {
            list: list.clone(),
            tasks,
            groups: RefCell::new(Vec::new()),
            search: Rc::default(),
            filters: RefCell::new(Vec::new()),
            focus: Cell::new(None),
            rows_changed: RefCell::new(None),
            state_changed: RefCell::new(None),
        });
        let ungrouped = view.filtered(None);
        let group = imp.ungrouped.get();
        view.bind(&group, &ungrouped);
        let weak = view.downgrade();
        let rows_changed = list.model().connect_items_changed(move |_, _, _, _| {
            if let Some(view) = weak.upgrade() {
                view.refresh();
                view.take_focus();
            }
        });
        let weak = view.downgrade();
        let state_changed = list.connect_state_changed(move |_| {
            if let Some(view) = weak.upgrade() {
                view.refresh_page();
            }
        });
        if let Some(parts) = imp.parts.get() {
            parts.rows_changed.replace(Some(rows_changed));
            parts.state_changed.replace(Some(state_changed));
        }
        view.refresh();
        view
    }

    /// Stop following the list, which outlives every window.
    pub(crate) fn shutdown(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        if let Some(handler) = parts.rows_changed.take() {
            parts.list.model().disconnect(handler);
        }
        if let Some(observer) = parts.state_changed.take() {
            parts.list.disconnect_state_changed(observer);
        }
    }

    /// The rows of the connections in `group`, or in none, that the
    /// search matches.
    fn filtered(&self, group: Option<&str>) -> gtk::FilterListModel {
        let Some(parts) = self.imp().parts.get() else {
            return gtk::FilterListModel::new(None::<gio::ListModel>, None::<gtk::Filter>);
        };
        let group = group.map(str::to_owned);
        let (list, search) = (Rc::downgrade(&parts.list), parts.search.clone());
        let filter = gtk::CustomFilter::new(move |item| {
            let Some(object) = item.downcast_ref::<SavedConnectionObject>() else {
                return false;
            };
            let (Some(saved), Some(list)) = (object.saved(), list.upgrade()) else {
                return false;
            };
            saved.group.as_ref().map(ConnectionGroupName::as_str) == group.as_deref()
                && search.borrow().matches(saved, &list.tags())
        });
        parts.filters.borrow_mut().push(filter.clone());
        gtk::FilterListModel::new(Some(parts.list.model()), Some(filter))
    }

    /// Show `group` while its section has a row to show.
    fn bind(&self, group: &adw::PreferencesGroup, rows: &gtk::FilterListModel) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let (list, tasks) = (parts.list.clone(), parts.tasks.clone());
        group.bind_model(Some(rows), move |object| {
            let choices = RowChoices {
                groups: list.groups(),
                tags: list.tags(),
            };
            connection_row(object, &choices, tasks.as_ref())
        });
        group.set_visible(rows.n_items() > 0);
        let (shown, view) = (group.downgrade(), self.downgrade());
        rows.connect_items_changed(move |rows, _, _, _| {
            if let Some(group) = shown.upgrade() {
                group.set_visible(rows.n_items() > 0);
            }
            // A section can change after the list's own handler ran.
            if let Some(view) = view.upgrade() {
                view.refresh_page();
            }
        });
    }

    /// Show only the connections `text` matches, in every section.
    pub(crate) fn set_search(&self, text: &str) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let search = ConnectionSearch::new(text);
        if *parts.search.borrow() == search {
            return;
        }
        parts.search.replace(search);
        for filter in parts.filters.borrow().iter() {
            filter.changed(gtk::FilterChange::Different);
        }
        self.refresh_page();
    }

    /// Connect to the first connection the list shows, as Enter in the
    /// search does.
    pub(crate) fn activate_first(&self) {
        let Some(row) = first_row(self.imp().page.upcast_ref()) else {
            return;
        };
        let (Some(action), target) = (row.action_name(), row.action_target_value()) else {
            return;
        };
        if let Err(error) = row.activate_action(&action, target.as_ref()) {
            tracing::warn!(%error, "the first connection's row reached no picker");
        }
    }

    /// Put the focus on the row of the connection `id`, now or once the
    /// list shows it: a copy reaches the list after the write that
    /// made it.
    pub(crate) fn focus_connection(&self, id: Uuid) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        parts.focus.set(Some(id));
        self.take_focus();
    }

    fn take_focus(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some(id) = parts.focus.get() else {
            return;
        };
        if let Some(row) = row_for(self.imp().page.upcast_ref(), &id.to_string()) {
            parts.focus.set(None);
            row.grab_focus();
        }
    }

    fn refresh(&self) {
        self.refresh_groups();
        self.refresh_page();
    }

    /// A group of its own for each group the list has, after the
    /// connections in none, rebuilt only when the set of groups changes.
    fn refresh_groups(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let names = parts.list.groups();
        // Next to named groups, "Saved Connections" would read as all of them.
        imp.ungrouped.set_title(&if names.is_empty() {
            crate::i18n::gettext("Saved Connections")
        } else {
            crate::i18n::gettext("Connections")
        });
        let unchanged = parts.groups.borrow().iter().map(|(name, _)| name).eq(names.iter());
        if unchanged {
            return;
        }
        for (_, group) in parts.groups.take() {
            imp.page.remove(&group);
        }
        // The ungrouped section's filter stays; the old groups' go.
        parts.filters.borrow_mut().truncate(1);
        let mut built = Vec::with_capacity(names.len());
        for name in names {
            // A group's title is markup, and the name is the user's text.
            let group = adw::PreferencesGroup::builder()
                .title(glib::markup_escape_text(name.as_str()).as_str())
                .build();
            self.bind(&group, &self.filtered(Some(name.as_str())));
            imp.page.add(&group);
            built.push((name, group));
        }
        parts.groups.replace(built);
    }

    /// The empty page only once the list is read and holds nothing. A
    /// list still loading, or one that cannot be read, shows no promise
    /// to add to it; the banner says why. A search that matches nothing
    /// says so rather than showing an empty list.
    fn refresh_page(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let empty = parts.list.model().n_items() == 0 && matches!(parts.list.state(), ConnectionListState::Ready(_));
        let unmatched = !parts.search.borrow().is_empty() && first_row(imp.page.upcast_ref()).is_none();
        imp.stack.set_visible_child_name(match (empty, unmatched) {
            (true, _) => "empty",
            (false, true) => "no-results",
            (false, false) => "list",
        });
    }

    #[cfg(test)]
    pub(crate) fn sections(&self) -> Vec<(String, Vec<String>)> {
        let imp = self.imp();
        let mut groups = vec![imp.ungrouped.get()];
        if let Some(parts) = imp.parts.get() {
            groups.extend(parts.groups.borrow().iter().map(|(_, group)| group.clone()));
        }
        groups
            .into_iter()
            .filter(|group| group.is_visible())
            .map(|group| {
                let rows = crate::test_support::descendants(&group)
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                    .map(|row| row.title().to_string())
                    .collect();
                (group.title().to_string(), rows)
            })
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn visible_page(&self) -> Option<String> {
        self.imp().stack.visible_child_name().map(|name| name.to_string())
    }
}
