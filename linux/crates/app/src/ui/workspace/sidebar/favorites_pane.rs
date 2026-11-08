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

/// What the user asks of a favorite.
#[derive(Debug, Clone)]
pub(crate) enum FavoriteAction {
    /// Open its SQL in a new query tab.
    Open(String),
    Rename(SavedQuery),
    Delete(SavedQuery),
}

type Asked = Rc<dyn Fn(FavoriteAction)>;

/// The class that marks a favorite's row, which carries its id as its name.
const ROW: &str = "favorite-row";
const RENAME: &str = "rename";
const DELETE: &str = "delete";

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    stack: gtk::Stack,
    store: gio::ListStore,
}

impl FavoritesPane {
    pub(crate) fn new(asked: impl Fn(FavoriteAction) + 'static) -> Self {
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
        let asked: Asked = Rc::new(asked);
        let model = store.clone();
        let open = asked.clone();
        list.connect_activate(move |_, position| {
            if let Some(favorite) = favorite_at(&model, position) {
                open(FavoriteAction::Open(favorite.query));
            }
        });
        install_menu(&list, &store, &selection_of(&list), &asked);
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
    pub(crate) fn ids(&self) -> Vec<i64> {
        (0..self.store.n_items())
            .filter_map(|position| favorite_at(&self.store, position))
            .map(|favorite| favorite.id)
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn names(&self) -> Vec<String> {
        (0..self.store.n_items())
            .filter_map(|position| favorite_at(&self.store, position))
            .map(|favorite| favorite.name)
            .collect()
    }
}

fn selection_of(list: &gtk::ListView) -> gtk::SingleSelection {
    list.model()
        .and_downcast::<gtk::SingleSelection>()
        .unwrap_or_else(|| gtk::SingleSelection::new(None::<gio::ListModel>))
}

/// Rename and Delete, from a right click on a row or F2 and Delete on the
/// selected one. The menu names the row by its id, which no reload moves.
fn install_menu(list: &gtk::ListView, store: &gio::ListStore, selection: &gtk::SingleSelection, asked: &Asked) {
    let find = {
        let store = store.clone();
        move |id: i64| {
            (0..store.n_items())
                .filter_map(|position| favorite_at(&store, position))
                .find(|favorite| favorite.id == id)
        }
    };
    let actions = gio::SimpleActionGroup::new();
    for (name, make) in [
        (RENAME, FavoriteAction::Rename as fn(SavedQuery) -> FavoriteAction),
        (DELETE, FavoriteAction::Delete),
    ] {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::INT64));
        let (find, asked) = (find.clone(), asked.clone());
        action.connect_activate(move |_, id| {
            if let Some(favorite) = id.and_then(|id| id.get::<i64>()).and_then(&find) {
                asked(make(favorite));
            }
        });
        actions.add_action(&action);
    }
    list.insert_action_group("favorite", Some(&actions));

    let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
    popover.set_has_arrow(false);
    popover.set_parent(list);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    {
        let (list, store, popover) = (list.downgrade(), store.clone(), popover.clone());
        click.connect_pressed(move |gesture, _, x, y| {
            let Some(list) = list.upgrade() else {
                return;
            };
            let Some(favorite) = row_at(&list, &store, x, y) else {
                return;
            };
            gesture.set_state(gtk::EventSequenceState::Claimed);
            popover.set_menu_model(Some(&menu_of(favorite.id)));
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        });
    }
    list.add_controller(click);
    // GTK finalizes a parent with a child left over and warns of it.
    list.connect_destroy(move |_| popover.unparent());

    let keys = gtk::EventControllerKey::new();
    let (selection, store, asked) = (selection.clone(), store.clone(), asked.clone());
    keys.connect_key_pressed(move |_, key, _, _| {
        let Some(favorite) = favorite_at(&store, selection.selected()) else {
            return glib::Propagation::Proceed;
        };
        match key {
            gtk::gdk::Key::F2 => asked(FavoriteAction::Rename(favorite)),
            gtk::gdk::Key::Delete | gtk::gdk::Key::KP_Delete => asked(FavoriteAction::Delete(favorite)),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    list.add_controller(keys);
}

fn menu_of(id: i64) -> gio::Menu {
    let menu = gio::Menu::new();
    for (label, action) in [(gettext("_Rename…"), RENAME), (gettext("_Delete…"), DELETE)] {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(&format!("favorite.{action}")), Some(&id.to_variant()));
        menu.append_item(&item);
    }
    menu
}

/// The favorite drawn at `(x, y)` in the list. Each row is named by its
/// favorite's id as it binds, so a row finds its favorite however the
/// list has scrolled and recycled.
fn row_at(list: &gtk::ListView, store: &gio::ListStore, x: f64, y: f64) -> Option<SavedQuery> {
    let mut widget = list.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(candidate) = widget {
        if candidate.has_css_class(ROW) {
            let id: i64 = candidate.widget_name().parse().ok()?;
            return (0..store.n_items())
                .filter_map(|position| favorite_at(store, position))
                .find(|favorite| favorite.id == id);
        }
        widget = candidate.parent();
    }
    None
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
        row.add_css_class(ROW);
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
        row.set_widget_name(&favorite.id.to_string());
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
