//! The sidebar's Favorites scope: the named queries the user kept for the
//! connection in front, as the macOS sidebar lists them beside its
//! tables. Activating one opens it in a new query tab.

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_storage::saved_queries::SavedQuery;

use crate::i18n::gettext;

const LIST: &str = "list";
const EMPTY: &str = "empty";

/// What activating a favorite asks for: its SQL.
type Opened = Rc<dyn Fn(String)>;

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    stack: gtk::Stack,
    store: gio::ListStore,
}

impl FavoritesPane {
    pub(crate) fn new(opened: impl Fn(String) + 'static) -> Self {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let selection = gtk::SingleSelection::builder()
            .model(&store)
            .autoselect(false)
            .can_unselect(true)
            .build();
        let list = gtk::ListView::new(Some(selection), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Favorites"))]);
        let opened: Opened = Rc::new(opened);
        let model = store.clone();
        list.connect_activate(move |_, position| {
            if let Some(favorite) = favorite_at(&model, position) {
                opened(favorite.query);
            }
        });
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&list)
            .build();
        let empty = adw::StatusPage::builder()
            .title(gettext("No Favorites"))
            .description(gettext("Save a query from the SQL editor to find it here."))
            .build();
        empty.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.add_named(&scrolled, Some(LIST));
        stack.add_named(&empty, Some(EMPTY));
        stack.set_visible_child_name(EMPTY);
        Self { stack, store }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.stack.clone().upcast()
    }

    /// List `favorites`, the newest save first.
    pub(crate) fn show(&self, mut favorites: Vec<SavedQuery>) {
        favorites.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        let items: Vec<glib::BoxedAnyObject> = favorites.into_iter().map(glib::BoxedAnyObject::new).collect();
        self.store.splice(0, self.store.n_items(), &items);
        self.stack
            .set_visible_child_name(if items.is_empty() { EMPTY } else { LIST });
    }

    #[cfg(test)]
    pub(crate) fn names(&self) -> Vec<String> {
        (0..self.store.n_items())
            .filter_map(|position| favorite_at(&self.store, position))
            .map(|favorite| favorite.name)
            .collect()
    }
}

fn favorite_at(store: &gio::ListStore, position: u32) -> Option<SavedQuery> {
    let item = store.item(position).and_downcast::<glib::BoxedAnyObject>()?;
    Some(item.borrow::<SavedQuery>().clone())
}

fn factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let name = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let summary = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        summary.add_css_class("caption");
        summary.add_css_class("dimmed");
        let row = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .margin_top(6)
            .margin_bottom(6)
            .build();
        row.append(&name);
        row.append(&summary);
        item.set_child(Some(&row));
    });
    factory.connect_bind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(object), Some(row)) = (item.item().and_downcast::<glib::BoxedAnyObject>(), item.child()) else {
            return;
        };
        let favorite = object.borrow::<SavedQuery>().clone();
        if let (Some(name), Some(summary)) = (
            row.first_child().and_downcast::<gtk::Label>(),
            row.last_child().and_downcast::<gtk::Label>(),
        ) {
            name.set_label(&favorite.name);
            summary.set_label(favorite.summary());
        }
        item.set_accessible_label(&favorite.name);
    });
    factory
}
