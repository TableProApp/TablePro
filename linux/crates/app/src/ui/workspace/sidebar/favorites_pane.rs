use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_storage::saved_queries::SavedQuery;

use crate::i18n::gettext;

const LIST: &str = "list";
const EMPTY: &str = "empty";

type Opened = Rc<dyn Fn(String)>;

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    stack: gtk::Stack,
    store: gio::ListStore,
    selection: gtk::SingleSelection,
    error: adw::StatusPage,
    retry: gtk::Button,
    stale: adw::Banner,
}

impl FavoritesPane {
    pub(crate) fn new(opened: impl Fn(String) + 'static, retry: impl Fn() + 'static) -> Self {
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
            error,
            retry: retry_button,
            stale,
        }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.stack.clone().upcast()
    }

    pub(crate) fn clear(&self) {
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
}
