#[path = "favorites_index.rs"]
mod index;
#[path = "favorites_rows.rs"]
mod rows;
#[cfg(test)]
#[path = "favorites_pane_tests.rs"]
mod tests;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_storage::saved_queries::{SavedQueriesSnapshot, SavedQuery, SavedQueryFolder};

use crate::i18n::gettext;
use index::{Index, Key, Node};

const LIST: &str = "list";
const EMPTY: &str = "empty";
const ROW: &str = "favorite-row";
const KEYS: &str = "favorite-keys";
const RENAME: &str = "rename";
const DELETE: &str = "delete";
const MOVE: &str = "move";
const SHARE: &str = "share";
const NEW_FOLDER: &str = "new-folder";

#[derive(Debug, Clone)]
pub(crate) enum FavoriteAction {
    Open(String),
    Rename(SavedQuery),
    Delete(SavedQuery),
    MoveTo(SavedQuery),
    Share(SavedQuery),
    NewFolder(Option<SavedQueryFolder>),
    RenameFolder(SavedQueryFolder),
    DeleteFolder(SavedQueryFolder),
}

type Asked = Rc<dyn Fn(FavoriteAction)>;
type SharedIndex = Rc<RefCell<Rc<Index>>>;

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    whole: gtk::Box,
    stack: gtk::Stack,
    store: gio::ListStore,
    tree: gtk::TreeListModel,
    index: SharedIndex,
    expansion: Rc<Expansion>,
    selection: gtk::SingleSelection,
    menu: gtk::PopoverMenu,
    error: adw::StatusPage,
    retry: gtk::Button,
    stale: adw::Banner,
    new_folder: gtk::Button,
}

impl FavoritesPane {
    pub(crate) fn new(asked: impl Fn(FavoriteAction) + 'static, retry: impl Fn() + 'static) -> Self {
        let asked: Asked = Rc::new(asked);
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let index: SharedIndex = Rc::default();
        let tree = gtk::TreeListModel::new(store.clone(), false, false, {
            let index = index.clone();
            move |item| match *item.downcast_ref::<glib::BoxedAnyObject>()?.borrow::<Key>() {
                Key::Folder(id) => Some(model_of(&index.borrow(), Some(id)).upcast()),
                Key::Query(_) => None,
            }
        });
        let expansion = Rc::new(Expansion::default());

        let selection = gtk::SingleSelection::builder()
            .model(&tree)
            .autoselect(false)
            .can_unselect(true)
            .build();
        let list = gtk::ListView::new(Some(selection.clone()), Some(rows::factory(index.clone())));
        // Selection and view must process an insertion before restoring expansion emits nested insertions.
        tree.connect_items_changed({
            let expansion = Rc::downgrade(&expansion);
            move |tree, _, _, _| {
                if let Some(expansion) = expansion.upgrade() {
                    expansion.observe(tree);
                }
            }
        });
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Favorites"))]);
        list.connect_activate({
            let (tree, index, asked) = (tree.clone(), index.clone(), asked.clone());
            move |_, position| {
                let Some(row) = tree.row(position) else {
                    return;
                };
                match key_of(&row).and_then(|key| index.borrow().nodes.get(&key).cloned()) {
                    Some(Node::Query(query)) => asked(FavoriteAction::Open(query.query)),
                    Some(Node::Folder(_)) => row.set_expanded(!row.is_expanded()),
                    None => {}
                }
            }
        });
        let menu = rows::install_menu(&list, &tree, &index, &selection, &asked);
        let (stack, error, retry, stale) = status_pages(&list, Rc::new(retry));
        let new_folder = gtk::Button::builder()
            .icon_name("folder-new-symbolic")
            .halign(gtk::Align::Start)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .sensitive(false)
            .build();
        new_folder.add_css_class("flat");
        new_folder.set_tooltip_text(Some(&gettext("New Folder")));
        new_folder.update_property(&[gtk::accessible::Property::Label(&gettext("New Folder"))]);
        new_folder.connect_clicked(move |_| asked(FavoriteAction::NewFolder(None)));
        let whole = gtk::Box::new(gtk::Orientation::Vertical, 0);
        whole.append(&stack);
        whole.append(&new_folder);
        Self {
            whole,
            stack,
            store,
            tree,
            index,
            expansion,
            selection,
            menu,
            error,
            retry,
            stale,
            new_folder,
        }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.whole.clone().upcast()
    }

    pub(crate) fn clear(&self) {
        self.menu.popdown();
        self.expansion.reset_rows();
        self.expansion.expanded.borrow_mut().clear();
        self.index.replace(Rc::default());
        self.store.remove_all();
        self.expansion.updating.set(false);
        self.selection.set_selected(gtk::INVALID_LIST_POSITION);
        self.stale.set_revealed(false);
        self.new_folder.set_sensitive(false);
    }

    pub(crate) fn no_connection(&self) {
        self.clear();
        self.stack.set_visible_child_name("disconnected");
    }

    pub(crate) fn loading(&self) {
        self.new_folder.set_sensitive(false);
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
        self.new_folder.set_sensitive(false);
        if self.store.n_items() > 0 {
            self.stale.set_revealed(true);
            return;
        }
        self.error
            .set_description(Some(&gettext("Saved queries could not be read. Try again.")));
        self.retry.set_visible(true);
        self.stack.set_visible_child_name("error");
    }

    pub(crate) fn show(&self, snapshot: SavedQueriesSnapshot) {
        let Some(index) = Index::new(snapshot) else {
            tracing::warn!("invalid saved query folder hierarchy");
            self.failed();
            return;
        };
        self.menu.popdown();
        let selected = self.tree.row(self.selection.selected()).as_ref().and_then(key_of);
        self.expansion.reset_rows();
        self.expansion
            .expanded
            .borrow_mut()
            .retain(|id| index.nodes.contains_key(&Key::Folder(*id)));
        let items: Vec<_> = index
            .children(None)
            .iter()
            .copied()
            .map(glib::BoxedAnyObject::new)
            .collect();
        self.index.replace(Rc::new(index));
        self.store.splice(0, self.store.n_items(), &items);
        self.expansion.updating.set(false);
        self.expansion.observe(&self.tree);
        self.selection.set_selected(
            selected
                .and_then(|key| position_of(&self.tree, key))
                .unwrap_or(gtk::INVALID_LIST_POSITION),
        );
        self.stale.set_revealed(false);
        self.new_folder.set_sensitive(true);
        self.stack
            .set_visible_child_name(if items.is_empty() { EMPTY } else { LIST });
    }

    pub(crate) fn folder_destinations(&self) -> Vec<(i64, String)> {
        self.index.borrow().destinations()
    }

    #[cfg(test)]
    pub(crate) fn ids(&self) -> Vec<i64> {
        self.index.borrow().queries().iter().map(|query| query.id).collect()
    }

    #[cfg(test)]
    pub(crate) fn names(&self) -> Vec<String> {
        self.index
            .borrow()
            .queries()
            .into_iter()
            .map(|query| query.name)
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn folder_of_first_query(&self) -> Option<i64> {
        self.index.borrow().queries().first().and_then(|query| query.folder_id)
    }
}

fn status_pages(list: &gtk::ListView, retry: Rc<dyn Fn()>) -> (gtk::Stack, adw::StatusPage, gtk::Button, adw::Banner) {
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
    content.append(
        &gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(list)
            .build(),
    );
    let empty = adw::StatusPage::builder()
        .title(gettext("No Favorites"))
        .icon_name("starred-symbolic")
        .description(gettext(
            "Save a query from the SQL editor or create a folder to organize favorites.",
        ))
        .build();
    empty.add_css_class("compact");
    let stack = gtk::Stack::builder().vexpand(true).build();
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
    (stack, error, retry_button, stale)
}

fn model_of(index: &Index, parent: Option<i64>) -> gio::ListStore {
    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    for key in index.children(parent) {
        store.append(&glib::BoxedAnyObject::new(*key));
    }
    store
}

fn key_of(row: &gtk::TreeListRow) -> Option<Key> {
    Some(*row.item().and_downcast::<glib::BoxedAnyObject>()?.borrow::<Key>())
}

fn position_of(tree: &gtk::TreeListModel, key: Key) -> Option<u32> {
    (0..tree.n_items()).find(|position| tree.row(*position).as_ref().and_then(key_of) == Some(key))
}

#[derive(Default)]
struct Expansion {
    expanded: RefCell<HashSet<i64>>,
    watched: RefCell<HashMap<i64, (gtk::TreeListRow, glib::SignalHandlerId)>>,
    updating: Cell<bool>,
}

impl Expansion {
    fn reset_rows(&self) {
        self.updating.set(true);
        for (_, (row, watch)) in self.watched.take() {
            row.disconnect(watch);
        }
    }

    fn observe(self: &Rc<Self>, tree: &gtk::TreeListModel) {
        if self.updating.replace(true) {
            return;
        }
        let mut position = 0;
        while position < tree.n_items() {
            let Some(row) = tree.row(position) else {
                break;
            };
            position += 1;
            let Some(Key::Folder(id)) = key_of(&row) else {
                continue;
            };
            if self.watched.borrow().get(&id).is_some_and(|(held, _)| held == &row) {
                continue;
            }
            if let Some((old, watch)) = self.watched.borrow_mut().remove(&id) {
                old.disconnect(watch);
            }
            let weak = Rc::downgrade(self);
            let watch = row.connect_expanded_notify(move |row| {
                // Collapsing an ancestor detaches its rows and emits false without changing the user's choice.
                if !row.is_expandable() {
                    return;
                }
                let Some(state) = weak.upgrade().filter(|state| !state.updating.get()) else {
                    return;
                };
                if row.is_expanded() {
                    state.expanded.borrow_mut().insert(id);
                } else {
                    state.expanded.borrow_mut().remove(&id);
                }
            });
            let expanded = self.expanded.borrow().contains(&id);
            self.watched.borrow_mut().insert(id, (row.clone(), watch));
            row.set_expanded(expanded);
        }
        self.updating.set(false);
    }
}

impl Drop for Expansion {
    fn drop(&mut self) {
        self.reset_rows();
    }
}
