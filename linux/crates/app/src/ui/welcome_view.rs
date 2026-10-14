//! The picker's saved connections: a preferences page bound to the list
//! every window shares, with a group for the connections in no group
//! and one for each group the user made.

use std::cell::{OnceCell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::ConnectionListState;

use crate::services::saved_connection_list::{SavedConnectionList, StateObserverId};
use crate::services::saved_connection_object::SavedConnectionObject;
use crate::ui::picker::connection_row;

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

glib::wrapper! {
    pub struct WelcomeView(ObjectSubclass<imp::WelcomeView>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(super) struct Parts {
    list: Rc<SavedConnectionList>,
    tasks: Option<Tasks>,
    /// The groups after the ungrouped one, by name, in list order.
    groups: RefCell<Vec<(String, adw::PreferencesGroup)>>,
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
            rows_changed: RefCell::new(None),
            state_changed: RefCell::new(None),
        });
        let ungrouped = view.filtered(None);
        let group = imp.ungrouped.get();
        group.set_visible(ungrouped.n_items() > 0);
        let shown = group.downgrade();
        ungrouped.connect_items_changed(move |model, _, _, _| {
            if let Some(group) = shown.upgrade() {
                group.set_visible(model.n_items() > 0);
            }
        });
        view.bind(&group, &ungrouped);
        let weak = view.downgrade();
        let rows_changed = list.model().connect_items_changed(move |_, _, _, _| {
            if let Some(view) = weak.upgrade() {
                view.refresh();
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

    /// The rows of the connections in `group`, or in none.
    fn filtered(&self, group: Option<&str>) -> gtk::FilterListModel {
        let list = self.imp().parts.get().map(|parts| parts.list.model());
        let group = group.map(str::to_owned);
        let filter = gtk::CustomFilter::new(move |item| {
            item.downcast_ref::<SavedConnectionObject>()
                .is_some_and(|object| object.group() == group)
        });
        gtk::FilterListModel::new(list, Some(filter))
    }

    fn bind(&self, group: &adw::PreferencesGroup, rows: &gtk::FilterListModel) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let (list, tasks) = (parts.list.clone(), parts.tasks.clone());
        group.bind_model(Some(rows), move |object| {
            connection_row(object, &list.groups(), tasks.as_ref())
        });
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
        let unchanged = parts.groups.borrow().iter().map(|(name, _)| name).eq(names.iter());
        if unchanged {
            return;
        }
        for (_, group) in parts.groups.take() {
            imp.page.remove(&group);
        }
        let mut built = Vec::with_capacity(names.len());
        for name in names {
            // A group's title is markup, and the name is the user's text.
            let group = adw::PreferencesGroup::builder()
                .title(glib::markup_escape_text(&name).as_str())
                .build();
            self.bind(&group, &self.filtered(Some(&name)));
            imp.page.add(&group);
            built.push((name, group));
        }
        parts.groups.replace(built);
    }

    /// The empty page only once the list is read and holds nothing. A
    /// list still loading, or one that cannot be read, shows no promise
    /// to add to it; the banner says why.
    fn refresh_page(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let empty = parts.list.model().n_items() == 0 && matches!(parts.list.state(), ConnectionListState::Ready(_));
        imp.stack.set_visible_child_name(if empty { "empty" } else { "list" });
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
