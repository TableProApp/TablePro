//! The sidebar's Favorites scope: the named queries the user kept for the
//! connection in front, filed in folders that nest, as the macOS sidebar
//! lists them beside its tables. Activating a query opens it in a new
//! query tab; a folder opens and closes.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_storage::saved_queries::{SavedQuery, SavedQueryFolder};

use crate::i18n::gettext;

const LIST: &str = "list";
const EMPTY: &str = "empty";

/// What the user asks of a favorite or a folder.
#[derive(Debug, Clone)]
pub(crate) enum FavoriteAction {
    /// Open its SQL in a new query tab.
    Open(String),
    Rename(SavedQuery),
    Delete(SavedQuery),
    /// File the query in another folder, or at the top.
    MoveTo(SavedQuery),
    /// Make a folder inside `parent`, none for the top.
    NewFolder(Option<SavedQueryFolder>),
    RenameFolder(SavedQueryFolder),
    DeleteFolder(SavedQueryFolder),
}

type Asked = Rc<dyn Fn(FavoriteAction)>;

/// What a row of the tree holds.
#[derive(Debug, Clone)]
enum Node {
    Folder(SavedQueryFolder),
    Query(SavedQuery),
}

impl Node {
    /// The id its row carries as its name: `f` or `q`, then the id.
    fn key(&self) -> String {
        match self {
            Node::Folder(folder) => format!("f{}", folder.id),
            Node::Query(query) => format!("q{}", query.id),
        }
    }
}

/// The nodes by the folder that holds them, subfolders first, then queries.
#[derive(Default)]
struct Index {
    children: HashMap<Option<i64>, Vec<Node>>,
    by_key: HashMap<String, Node>,
}

impl Index {
    fn of(mut queries: Vec<SavedQuery>, folders: Vec<SavedQueryFolder>) -> Self {
        queries.sort_by(|a, b| {
            a.order
                .cmp(&b.order)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        let mut index = Index::default();
        for folder in folders {
            let node = Node::Folder(folder.clone());
            index.by_key.insert(node.key(), node.clone());
            index.children.entry(folder.parent_id).or_default().push(node);
        }
        for query in queries {
            let node = Node::Query(query.clone());
            index.by_key.insert(node.key(), node.clone());
            index.children.entry(query.folder_id).or_default().push(node);
        }
        index
    }

    fn model_of(&self, parent: Option<i64>) -> gio::ListStore {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        for node in self.children.get(&parent).into_iter().flatten() {
            store.append(&glib::BoxedAnyObject::new(node.clone()));
        }
        store
    }

    #[cfg(test)]
    fn queries(&self) -> Vec<SavedQuery> {
        self.by_key
            .values()
            .filter_map(|node| match node {
                Node::Query(query) => Some(query.clone()),
                Node::Folder(_) => None,
            })
            .collect()
    }
}

const ROW: &str = "favorite-row";
const RENAME: &str = "rename";
const DELETE: &str = "delete";
const MOVE: &str = "move";
const NEW_FOLDER: &str = "new-folder";

#[derive(Clone)]
pub(crate) struct FavoritesPane {
    whole: gtk::Box,
    stack: gtk::Stack,
    root: gio::ListStore,
    index: Rc<RefCell<Rc<Index>>>,
}

impl FavoritesPane {
    pub(crate) fn new(asked: impl Fn(FavoriteAction) + 'static) -> Self {
        let asked: Asked = Rc::new(asked);
        let root = gio::ListStore::new::<glib::BoxedAnyObject>();
        let index: Rc<RefCell<Rc<Index>>> = Rc::default();
        let tree = gtk::TreeListModel::new(root.clone(), false, true, {
            let index = index.clone();
            move |item| {
                let node = item.downcast_ref::<glib::BoxedAnyObject>()?.borrow::<Node>().clone();
                match node {
                    Node::Folder(folder) => Some(index.borrow().model_of(Some(folder.id)).upcast()),
                    Node::Query(_) => None,
                }
            }
        });
        let selection = gtk::SingleSelection::builder()
            .model(&tree)
            .autoselect(false)
            .can_unselect(true)
            .build();
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Favorites"))]);
        list.connect_activate({
            let (selection, asked) = (selection.clone(), asked.clone());
            move |_, position| {
                let Some(row) = selection.item(position).and_downcast::<gtk::TreeListRow>() else {
                    return;
                };
                match node_of(&row) {
                    Some(Node::Query(query)) => asked(FavoriteAction::Open(query.query)),
                    Some(Node::Folder(_)) => row.set_expanded(!row.is_expanded()),
                    None => {}
                }
            }
        });
        install_menu(&list, &selection, &index, &asked);

        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
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
        stack.set_vexpand(true);

        let new_folder = gtk::Button::builder()
            .label(gettext("New Folder"))
            .icon_name("folder-new-symbolic")
            .halign(gtk::Align::Start)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .build();
        new_folder.add_css_class("flat");
        new_folder.connect_clicked({
            let asked = asked.clone();
            move |_| asked(FavoriteAction::NewFolder(None))
        });
        let whole = gtk::Box::new(gtk::Orientation::Vertical, 0);
        whole.append(&stack);
        whole.append(&new_folder);
        Self {
            whole,
            stack,
            root,
            index,
        }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.whole.clone().upcast()
    }

    /// List `queries` in `folders`.
    pub(crate) fn show(&self, queries: Vec<SavedQuery>, folders: Vec<SavedQueryFolder>) {
        let empty = queries.is_empty() && folders.is_empty();
        let index = Rc::new(Index::of(queries, folders));
        self.index.replace(index.clone());
        let top = index.model_of(None);
        let items: Vec<glib::Object> = (0..top.n_items()).filter_map(|position| top.item(position)).collect();
        self.root.splice(0, self.root.n_items(), &items);
        self.stack.set_visible_child_name(if empty { EMPTY } else { LIST });
    }

    /// The folders as they are listed, for a dialog that picks one.
    pub(crate) fn folders(&self) -> Vec<SavedQueryFolder> {
        self.index
            .borrow()
            .by_key
            .values()
            .filter_map(|node| match node {
                Node::Folder(folder) => Some(folder.clone()),
                Node::Query(_) => None,
            })
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn ids(&self) -> Vec<i64> {
        let mut ids: Vec<i64> = self.index.borrow().queries().iter().map(|query| query.id).collect();
        ids.sort_unstable();
        ids
    }

    #[cfg(test)]
    pub(crate) fn folder_of_first_query(&self) -> Option<i64> {
        self.index.borrow().queries().first().and_then(|query| query.folder_id)
    }

    #[cfg(test)]
    pub(crate) fn names(&self) -> Vec<String> {
        let mut queries = self.index.borrow().queries();
        queries.sort_by_key(|query| (query.updated_at, query.id));
        queries.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        queries.into_iter().map(|query| query.name).collect()
    }
}

fn node_of(row: &gtk::TreeListRow) -> Option<Node> {
    Some(
        row.item()
            .and_downcast::<glib::BoxedAnyObject>()?
            .borrow::<Node>()
            .clone(),
    )
}

/// Rename, Move to Folder, New Subfolder and Delete, from a right click on
/// a row or F2 and Delete on the selected one. The menu names the row by
/// its key, which no reload moves.
fn install_menu(list: &gtk::ListView, selection: &gtk::SingleSelection, index: &Rc<RefCell<Rc<Index>>>, asked: &Asked) {
    let actions = gio::SimpleActionGroup::new();
    for name in [RENAME, DELETE, MOVE, NEW_FOLDER] {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let (index, asked) = (index.clone(), asked.clone());
        action.connect_activate(move |_, key| {
            let Some(node) = key
                .and_then(|key| key.str())
                .and_then(|key| index.borrow().by_key.get(key).cloned())
            else {
                return;
            };
            asked(match (name, node) {
                (RENAME, Node::Query(query)) => FavoriteAction::Rename(query),
                (RENAME, Node::Folder(folder)) => FavoriteAction::RenameFolder(folder),
                (DELETE, Node::Query(query)) => FavoriteAction::Delete(query),
                (DELETE, Node::Folder(folder)) => FavoriteAction::DeleteFolder(folder),
                (MOVE, Node::Query(query)) => FavoriteAction::MoveTo(query),
                (_, Node::Folder(folder)) => FavoriteAction::NewFolder(Some(folder)),
                (_, Node::Query(query)) => FavoriteAction::Open(query.query),
            });
        });
        actions.add_action(&action);
    }
    list.insert_action_group("favorite", Some(&actions));

    let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
    popover.set_has_arrow(false);
    popover.set_parent(list);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    {
        let (list, index, popover) = (list.downgrade(), index.clone(), popover.clone());
        click.connect_pressed(move |gesture, _, x, y| {
            let Some(list) = list.upgrade() else {
                return;
            };
            let Some(node) = row_at(&list, &index, x, y) else {
                return;
            };
            gesture.set_state(gtk::EventSequenceState::Claimed);
            popover.set_menu_model(Some(&menu_of(&node)));
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        });
    }
    list.add_controller(click);
    // GTK finalizes a parent with a child left over and warns of it.
    list.connect_destroy(move |_| popover.unparent());

    let keys = gtk::EventControllerKey::new();
    let (selection, asked) = (selection.clone(), asked.clone());
    keys.connect_key_pressed(move |_, key, _, _| {
        let Some(node) = selection
            .selected_item()
            .and_downcast::<gtk::TreeListRow>()
            .as_ref()
            .and_then(node_of)
        else {
            return glib::Propagation::Proceed;
        };
        let action = match (key, node) {
            (gtk::gdk::Key::F2, Node::Query(query)) => FavoriteAction::Rename(query),
            (gtk::gdk::Key::F2, Node::Folder(folder)) => FavoriteAction::RenameFolder(folder),
            (gtk::gdk::Key::Delete | gtk::gdk::Key::KP_Delete, Node::Query(query)) => FavoriteAction::Delete(query),
            (gtk::gdk::Key::Delete | gtk::gdk::Key::KP_Delete, Node::Folder(folder)) => {
                FavoriteAction::DeleteFolder(folder)
            }
            _ => return glib::Propagation::Proceed,
        };
        asked(action);
        glib::Propagation::Stop
    });
    list.add_controller(keys);
}

fn menu_of(node: &Node) -> gio::Menu {
    let key = node.key();
    let entries: Vec<(String, &str)> = match node {
        Node::Query(_) => vec![
            (gettext("_Rename…"), RENAME),
            (gettext("_Move to Folder…"), MOVE),
            (gettext("_Delete…"), DELETE),
        ],
        Node::Folder(_) => vec![
            (gettext("New _Subfolder…"), NEW_FOLDER),
            (gettext("_Rename…"), RENAME),
            (gettext("_Delete…"), DELETE),
        ],
    };
    let menu = gio::Menu::new();
    for (label, action) in entries {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(&format!("favorite.{action}")), Some(&key.to_variant()));
        menu.append_item(&item);
    }
    menu
}

/// The node drawn at `(x, y)`. Each row is named by its key as it binds, so
/// a row finds its node however the list has scrolled and recycled.
fn row_at(list: &gtk::ListView, index: &Rc<RefCell<Rc<Index>>>, x: f64, y: f64) -> Option<Node> {
    let mut widget = list.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(candidate) = widget {
        if candidate.has_css_class(ROW) {
            return index.borrow().by_key.get(candidate.widget_name().as_str()).cloned();
        }
        widget = candidate.parent();
    }
    None
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
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let summary = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        summary.add_css_class("caption");
        summary.add_css_class("dimmed");
        let text = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .build();
        text.append(&name);
        text.append(&summary);
        let row = gtk::Box::builder().spacing(8).margin_top(6).margin_bottom(6).build();
        row.add_css_class(ROW);
        row.append(&icon);
        row.append(&text);
        let expander = gtk::TreeExpander::new();
        expander.set_child(Some(&row));
        item.set_child(Some(&expander));
    });
    factory.connect_bind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(list_row), Some(expander)) = (
            item.item().and_downcast::<gtk::TreeListRow>(),
            item.child().and_downcast::<gtk::TreeExpander>(),
        ) else {
            return;
        };
        expander.set_list_row(Some(&list_row));
        let (Some(node), Some(row)) = (node_of(&list_row), expander.child()) else {
            return;
        };
        row.set_widget_name(&node.key());
        let (Some(icon), Some(text)) = (row.first_child().and_downcast::<gtk::Image>(), row.last_child()) else {
            return;
        };
        let (Some(name), Some(summary)) = (
            text.first_child().and_downcast::<gtk::Label>(),
            text.last_child().and_downcast::<gtk::Label>(),
        ) else {
            return;
        };
        match &node {
            Node::Folder(folder) => {
                icon.set_icon_name(Some("folder-symbolic"));
                name.set_label(&folder.name);
                summary.set_visible(false);
                item.set_accessible_label(&folder.name);
            }
            Node::Query(query) => {
                icon.set_icon_name(Some("text-x-generic-symbolic"));
                name.set_label(&query.name);
                summary.set_label(query.summary());
                summary.set_visible(true);
                item.set_accessible_label(&query.name);
            }
        }
    });
    factory
}
