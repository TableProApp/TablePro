use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_storage::saved_queries::SavedQuery;

use crate::i18n::{gettext, gettext_f};

const LIST: &str = "list";
const EMPTY: &str = "empty";

#[derive(Debug, Clone)]
pub(crate) enum FavoriteAction {
    Open(String),
    Rename(SavedQuery),
    Delete(SavedQuery),
}

type Asked = Rc<dyn Fn(FavoriteAction)>;

const ROW: &str = "favorite-row";
const RENAME: &str = "rename";
const DELETE: &str = "delete";
const KEYS: &str = "favorite-keys";

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    stack: gtk::Stack,
    store: gio::ListStore,
    selection: gtk::SingleSelection,
    menu: gtk::PopoverMenu,
    error: adw::StatusPage,
    retry: gtk::Button,
    stale: adw::Banner,
}

impl FavoritesPane {
    pub(crate) fn new(asked: impl Fn(FavoriteAction) + 'static, retry: impl Fn() + 'static) -> Self {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let selection = gtk::SingleSelection::builder()
            .model(&store)
            .autoselect(false)
            .can_unselect(true)
            .build();
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Favorites"))]);
        let asked: Asked = Rc::new(asked);
        let opened = asked.clone();
        let model = store.clone();
        list.connect_activate(move |_, position| {
            if let Some(favorite) = favorite_at(&model, position) {
                opened(FavoriteAction::Open(favorite.query));
            }
        });
        let menu = install_menu(&list, &store, &selection, &asked);
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&list)
            .build();
        let retry = Rc::new(retry);
        let retry_button = gtk::Button::with_label(&gettext("Try Again"));
        retry_button.set_halign(gtk::Align::Center);
        retry_button.connect_clicked({
            let retry = retry.clone();
            move |_| retry()
        });
        let error = adw::StatusPage::builder()
            .title(gettext("Favorites Unavailable"))
            .icon_name("dialog-warning-symbolic")
            .child(&retry_button)
            .build();
        error.add_css_class("compact");
        let stale = adw::Banner::builder()
            .title(gettext("Favorites could not be refreshed."))
            .button_label(gettext("Try Again"))
            .build();
        stale.connect_button_clicked(move |_| retry());
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&stale);
        scrolled.set_vexpand(true);
        content.append(&scrolled);
        let empty = adw::StatusPage::builder()
            .title(gettext("No Favorites"))
            .icon_name("starred-symbolic")
            .description(gettext("Save a query from the SQL editor to find it here."))
            .build();
        empty.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.add_named(&content, Some(LIST));
        stack.add_named(&error, Some("error"));
        let loading = adw::StatusPage::builder()
            .title(gettext("Loading Favorites"))
            .child(&adw::Spinner::new())
            .build();
        loading.add_css_class("compact");
        stack.add_named(&loading, Some("loading"));
        let disconnected = adw::StatusPage::builder()
            .title(gettext("No Connection Selected"))
            .description(gettext("Open a connection to see its saved queries."))
            .icon_name("starred-symbolic")
            .build();
        disconnected.add_css_class("compact");
        stack.add_named(&disconnected, Some("disconnected"));
        stack.add_named(&empty, Some(EMPTY));
        stack.set_visible_child_name(EMPTY);
        Self {
            stack,
            store,
            selection,
            menu,
            error,
            retry: retry_button,
            stale,
        }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.stack.clone().upcast()
    }

    pub(crate) fn clear(&self) {
        self.menu.popdown();
        self.store.remove_all();
        self.stale.set_revealed(false);
    }

    pub(crate) fn no_connection(&self) {
        self.clear();
        self.stack.set_visible_child_name("disconnected");
    }

    pub(crate) fn loading(&self) {
        self.stale.set_revealed(false);
        if self.store.n_items() == 0 {
            self.stack.set_visible_child_name("loading");
        }
    }

    pub(crate) fn unavailable(&self) {
        self.clear();
        self.error.set_description(Some(&gettext(
            "The query history file could not be opened. Check the file and restart TablePro.",
        )));
        self.retry.set_visible(false);
        self.stack.set_visible_child_name("error");
    }

    pub(crate) fn failed(&self) {
        if self.store.n_items() > 0 {
            self.stale.set_revealed(true);
            return;
        }
        self.error
            .set_description(Some(&gettext("Saved queries could not be read. Try again.")));
        self.retry.set_visible(true);
        self.stack.set_visible_child_name("error");
    }

    pub(crate) fn show(&self, favorites: Vec<SavedQuery>) {
        self.menu.popdown();
        let selected = favorite_at(&self.store, self.selection.selected()).map(|saved| saved.id);
        let selected_position = favorites.iter().position(|saved| Some(saved.id) == selected);
        let items: Vec<glib::BoxedAnyObject> = favorites.into_iter().map(glib::BoxedAnyObject::new).collect();
        self.store.splice(0, self.store.n_items(), &items);
        self.selection
            .set_selected(selected_position.map_or(gtk::INVALID_LIST_POSITION, |position| position as u32));
        self.stale.set_revealed(false);
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
        let labels = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .hexpand(true)
            .valign(gtk::Align::Center)
            .build();
        labels.append(&name);
        labels.append(&summary);
        let menu = gtk::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .valign(gtk::Align::Center)
            .build();
        menu.add_css_class("flat");
        let row = gtk::Box::builder().spacing(6).margin_top(6).margin_bottom(6).build();
        row.add_css_class(ROW);
        row.append(&labels);
        row.append(&menu);
        item.set_child(Some(&row));
    });
    factory.connect_bind(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(object), Some(row)) = (item.item().and_downcast::<glib::BoxedAnyObject>(), item.child()) else {
            return;
        };
        let favorite = object.borrow::<SavedQuery>().clone();
        row.set_widget_name(&favorite.id.to_string());
        if let Some(labels) = row.first_child() {
            if let Some(name) = labels.first_child().and_downcast::<gtk::Label>() {
                name.set_label(&favorite.name);
            }
            if let Some(summary) = labels.last_child().and_downcast::<gtk::Label>() {
                summary.set_label(favorite.summary());
                summary.set_visible(!favorite.summary().is_empty());
            }
        }
        if let Some(menu) = row.last_child().and_downcast::<gtk::MenuButton>() {
            let label = gettext_f("Options for “{name}”", &[("name", &favorite.name)]);
            menu.set_tooltip_text(Some(&label));
            menu.update_property(&[gtk::accessible::Property::Label(&label)]);
            menu.set_menu_model(Some(&menu_of(favorite.id)));
        }
        item.set_accessible_label(&favorite.name);
    });
    factory.connect_unbind(|_, item| {
        let Some(row) = item.downcast_ref::<gtk::ListItem>().and_then(|item| item.child()) else {
            return;
        };
        row.set_widget_name("");
        if let Some(menu) = row.last_child().and_downcast::<gtk::MenuButton>() {
            menu.popdown();
            menu.set_menu_model(None::<&gio::MenuModel>);
        }
    });
    factory
}

fn install_menu(
    list: &gtk::ListView,
    store: &gio::ListStore,
    selection: &gtk::SingleSelection,
    asked: &Asked,
) -> gtk::PopoverMenu {
    let actions = gio::SimpleActionGroup::new();
    for (name, make) in [
        (RENAME, FavoriteAction::Rename as fn(SavedQuery) -> FavoriteAction),
        (DELETE, FavoriteAction::Delete),
    ] {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::INT64));
        let (store, asked) = (store.clone(), asked.clone());
        action.connect_activate(move |_, target| {
            let Some(id) = target.and_then(|target| target.get::<i64>()) else {
                return;
            };
            if let Some(favorite) = favorite_by_id(&store, id) {
                asked(make(favorite));
            }
        });
        actions.add_action(&action);
    }
    list.insert_action_group("favorite", Some(&actions));

    let menu = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
    menu.set_has_arrow(false);
    menu.set_parent(list);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    {
        let (list, store, menu) = (list.downgrade(), store.clone(), menu.clone());
        click.connect_pressed(move |gesture, _, x, y| {
            let Some(list) = list.upgrade() else {
                return;
            };
            let Some(favorite) = row_at(&list, &store, x, y) else {
                return;
            };
            gesture.set_state(gtk::EventSequenceState::Claimed);
            menu.set_menu_model(Some(&menu_of(favorite.id)));
            menu.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            menu.popup();
        });
    }
    list.add_controller(click);
    // GTK requires manually parented popovers to leave before their parent is finalized.
    list.connect_destroy({
        let menu = menu.clone();
        move |_| menu.unparent()
    });

    install_keys(list, store, selection, asked, &menu);
    menu
}

fn install_keys(
    list: &gtk::ListView,
    store: &gio::ListStore,
    selection: &gtk::SingleSelection,
    asked: &Asked,
    menu: &gtk::PopoverMenu,
) {
    let keys = gtk::EventControllerKey::new();
    keys.set_name(Some(KEYS));
    let (selection, store, asked, menu_for_key, list_weak) = (
        selection.clone(),
        store.clone(),
        asked.clone(),
        menu.clone(),
        list.downgrade(),
    );
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let modifiers = modifiers.intersection(gtk::accelerator_get_default_mod_mask());
        let Some(favorite) = favorite_at(&store, selection.selected()) else {
            return glib::Propagation::Proceed;
        };
        if (key == gtk::gdk::Key::Menu && modifiers.is_empty())
            || (key == gtk::gdk::Key::F10 && modifiers == gtk::gdk::ModifierType::SHIFT_MASK)
        {
            let Some(list) = list_weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            let bounds = find_row(&list, favorite.id).and_then(|row| row.compute_bounds(&list));
            let anchor = bounds.map(|bounds| {
                gtk::gdk::Rectangle::new(
                    bounds.x() as i32,
                    bounds.y() as i32,
                    bounds.width() as i32,
                    bounds.height() as i32,
                )
            });
            menu_for_key.set_menu_model(Some(&menu_of(favorite.id)));
            menu_for_key.set_pointing_to(anchor.as_ref());
            menu_for_key.popup();
            return glib::Propagation::Stop;
        }
        if !modifiers.is_empty() {
            return glib::Propagation::Proceed;
        }
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

fn favorite_by_id(store: &gio::ListStore, id: i64) -> Option<SavedQuery> {
    (0..store.n_items())
        .filter_map(|position| favorite_at(store, position))
        .find(|favorite| favorite.id == id)
}

fn row_at(list: &gtk::ListView, store: &gio::ListStore, x: f64, y: f64) -> Option<SavedQuery> {
    let mut widget = list.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(candidate) = widget {
        if candidate.has_css_class(ROW) {
            return candidate
                .widget_name()
                .parse()
                .ok()
                .and_then(|id| favorite_by_id(store, id));
        }
        widget = candidate.parent();
    }
    None
}

fn find_row(widget: &impl IsA<gtk::Widget>, id: i64) -> Option<gtk::Widget> {
    let widget = widget.as_ref();
    if widget.has_css_class(ROW) && widget.widget_name() == id.to_string() {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if let Some(row) = find_row(&current, id) {
            return Some(row);
        }
        child = current.next_sibling();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;
    use uuid::Uuid;

    fn saved(id: i64, name: &str) -> SavedQuery {
        SavedQuery {
            id,
            name: name.to_owned(),
            query: "SELECT 1".to_owned(),
            connection_id: Uuid::nil(),
            connection_name: "Database".to_owned(),
            keyword: None,
            folder_id: None,
            order: 0,
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    #[gtk4::test]
    fn favorites_keep_selection_by_id_after_rename_and_reorder() {
        let pane = FavoritesPane::new(|_| {}, || {});
        pane.show(vec![saved(1, "One"), saved(2, "Two")]);
        pane.selection.set_selected(1);
        pane.show(vec![saved(2, "Renamed"), saved(1, "One")]);
        assert_eq!(pane.selection.selected(), 0);
        pane.show(vec![saved(1, "One")]);
        assert_eq!(pane.selection.selected(), gtk::INVALID_LIST_POSITION);
    }

    #[gtk4::test]
    fn favorites_distinguish_loading_empty_unavailable_and_failed_refresh() {
        let retried = Rc::new(std::cell::Cell::new(false));
        let retry = retried.clone();
        let pane = FavoritesPane::new(|_| {}, move || retry.set(true));
        pane.loading();
        assert_eq!(pane.stack.visible_child_name().as_deref(), Some("loading"));
        pane.failed();
        assert_eq!(pane.stack.visible_child_name().as_deref(), Some("error"));
        pane.retry.emit_clicked();
        assert!(retried.get());
        pane.show(vec![]);
        assert_eq!(pane.stack.visible_child_name().as_deref(), Some(EMPTY));
        pane.show(vec![saved(1, "One")]);
        pane.failed();
        assert!(pane.stale.is_revealed());
        assert_eq!(pane.names(), ["One"]);
        pane.unavailable();
        assert!(!pane.retry.is_visible());
        assert!(pane.names().is_empty());
        pane.no_connection();
        assert_eq!(pane.stack.visible_child_name().as_deref(), Some("disconnected"));
    }

    type Actions = Rc<std::cell::RefCell<Vec<FavoriteAction>>>;
    const WAIT: std::time::Duration = std::time::Duration::from_secs(30);

    fn shown() -> (FavoritesPane, crate::test_support::OwnedWindow<gtk::Window>, Actions) {
        adw::init().expect("libadwaita");
        let actions = Actions::default();
        let sink = actions.clone();
        let pane = FavoritesPane::new(move |action| sink.borrow_mut().push(action), || {});
        pane.show(vec![saved(1, "One"), saved(2, "Two")]);
        let window = gtk::Window::builder()
            .default_width(360)
            .default_height(360)
            .child(&pane.widget())
            .build();
        let window = crate::test_support::OwnedWindow::presented(window);
        crate::test_support::wait_until(WAIT, || find_row(&list(&pane), 2).is_some_and(|row| row.height() > 0))
            .expect("rows laid out");
        (pane, window, actions)
    }

    fn list(pane: &FavoritesPane) -> gtk::ListView {
        pane.menu
            .parent()
            .and_downcast::<gtk::ListView>()
            .expect("menu belongs to list")
    }

    fn press(pane: &FavoritesPane, key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> bool {
        let controllers = list(pane).observe_controllers();
        let keys = (0..controllers.n_items())
            .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
            .find(|keys| keys.name().as_deref() == Some(KEYS))
            .expect("favorite key handler");
        keys.emit_by_name::<bool>("key-pressed", &[&key, &0u32, &modifiers])
    }

    fn target(menu: &impl IsA<gio::MenuModel>, position: i32) -> glib::Variant {
        menu.as_ref()
            .item_attribute_value(position, "target", None)
            .expect("menu target")
    }

    fn requested(actions: &Actions) -> Vec<(&'static str, i64, String)> {
        actions
            .borrow()
            .iter()
            .filter_map(|action| match action {
                FavoriteAction::Rename(saved) => Some(("rename", saved.id, saved.name.clone())),
                FavoriteAction::Delete(saved) => Some(("delete", saved.id, saved.name.clone())),
                FavoriteAction::Open(_) => None,
            })
            .collect()
    }

    #[gtk4::test]
    fn a_favorite_has_a_named_menu_button_that_acts_on_its_row() {
        let (pane, _window, actions) = shown();
        let row = find_row(&list(&pane), 2).expect("second row");
        let button = row
            .last_child()
            .and_downcast::<gtk::MenuButton>()
            .expect("row menu button");
        assert_eq!(crate::test_support::assert_labelled(&button), Ok(()));
        assert_eq!(button.tooltip_text().as_deref(), Some("Options for “Two”"));
        button.popup();
        assert!(button.popover().expect("row popover").is_visible());
        let menu = button.menu_model().expect("row menu");
        assert_eq!(menu.n_items(), 2);
        crate::test_support::assert_access_keys(&menu);
        let action = menu
            .item_attribute_value(0, "action", None)
            .and_then(|value| value.get::<String>())
            .expect("rename action");
        button
            .activate_action(&action, Some(&target(&menu, 0)))
            .expect("rename from menu");
        assert_eq!(requested(&actions), [("rename", 2, "Two".to_owned())]);
    }

    #[gtk4::test]
    fn favorite_shortcuts_use_selection_and_ignore_modifiers() {
        use gtk::gdk::{Key, ModifierType};
        let (pane, _window, actions) = shown();
        pane.selection.set_selected(1);
        for modifier in [
            ModifierType::SHIFT_MASK,
            ModifierType::CONTROL_MASK,
            ModifierType::ALT_MASK,
            ModifierType::SUPER_MASK,
        ] {
            for key in [Key::F2, Key::Delete, Key::KP_Delete] {
                assert!(!press(&pane, key, modifier));
            }
        }
        assert!(actions.borrow().is_empty());
        assert!(press(&pane, Key::F2, ModifierType::empty()));
        assert!(press(&pane, Key::Delete, ModifierType::empty()));
        assert!(press(&pane, Key::KP_Delete, ModifierType::empty()));
        assert_eq!(
            requested(&actions),
            [
                ("rename", 2, "Two".to_owned()),
                ("delete", 2, "Two".to_owned()),
                ("delete", 2, "Two".to_owned()),
            ]
        );
        pane.selection.set_selected(gtk::INVALID_LIST_POSITION);
        assert!(!press(&pane, Key::F2, ModifierType::empty()));
    }

    #[gtk4::test]
    fn the_keyboard_opens_the_selected_favorites_context_menu() {
        use gtk::gdk::{Key, ModifierType};
        let (pane, _window, actions) = shown();
        pane.selection.set_selected(1);
        for (key, modifiers) in [(Key::F10, ModifierType::SHIFT_MASK), (Key::Menu, ModifierType::empty())] {
            assert!(press(&pane, key, modifiers));
            assert!(pane.menu.is_visible());
            let model = pane.menu.menu_model().expect("context menu");
            let target = target(&model, 1);
            assert_eq!(target.get::<i64>(), Some(2));
            pane.menu.popdown();
        }
        assert!(actions.borrow().is_empty());
        assert!(!press(
            &pane,
            Key::F10,
            ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK
        ));
    }

    #[gtk4::test]
    fn a_secondary_click_targets_the_clicked_favorite() {
        let (pane, _window, actions) = shown();
        let list = list(&pane);
        pane.selection.set_selected(0);
        let row = find_row(&list, 2).expect("second row");
        let bounds = row.compute_bounds(&list).expect("row bounds");
        let controllers = list.observe_controllers();
        let click = (0..controllers.n_items())
            .filter_map(|position| controllers.item(position).and_downcast::<gtk::GestureClick>())
            .find(|click| click.button() == gtk::gdk::BUTTON_SECONDARY)
            .expect("secondary click");
        click.emit_by_name::<()>(
            "pressed",
            &[&1i32, &f64::from(bounds.x() + 4.0), &f64::from(bounds.y() + 4.0)],
        );
        assert!(pane.menu.is_visible());
        let model = pane.menu.menu_model().expect("context menu");
        list.activate_action("favorite.delete", Some(&target(&model, 1)))
            .expect("delete");
        assert_eq!(requested(&actions), [("delete", 2, "Two".to_owned())]);
    }

    #[gtk4::test]
    fn reordered_menu_targets_keep_their_id_and_removed_targets_do_nothing() {
        let (pane, _window, actions) = shown();
        let list = list(&pane);
        let previous = target(&menu_of(2), 0);
        pane.selection.set_selected(1);
        pane.show(vec![saved(2, "Renamed"), saved(1, "One")]);
        list.activate_action("favorite.rename", Some(&previous))
            .expect("old action routed");
        assert_eq!(requested(&actions), [("rename", 2, "Renamed".to_owned())]);
        assert!(press(&pane, gtk::gdk::Key::F2, gtk::gdk::ModifierType::empty()));
        assert_eq!(
            requested(&actions),
            [("rename", 2, "Renamed".to_owned()), ("rename", 2, "Renamed".to_owned()),]
        );
        let before_switch = target(&menu_of(2), 1);
        pane.clear();
        list.activate_action("favorite.delete", Some(&before_switch))
            .expect("stale target routed");
        assert_eq!(actions.borrow().len(), 2);
        pane.show(vec![saved(3, "Different connection")]);
        list.activate_action("favorite.delete", Some(&before_switch))
            .expect("stale target routed");
        assert_eq!(actions.borrow().len(), 2);
        let current = target(&menu_of(3), 1);
        pane.show(vec![]);
        list.activate_action("favorite.delete", Some(&current))
            .expect("removed target routed");
        assert_eq!(actions.borrow().len(), 2);
    }
}
