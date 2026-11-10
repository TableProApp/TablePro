use super::*;
use crate::i18n::gettext_f;

pub(super) fn factory(index: SharedIndex) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| setup(item));
    factory.connect_bind(move |_, item| bind(item, &index));
    factory.connect_unbind(|_, item| unbind(item));
    factory
}

fn setup(item: &glib::Object) {
    let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
        return;
    };
    item.set_focusable(false);
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
    row.append(&gtk::Image::from_icon_name("folder-symbolic"));
    row.append(&labels);
    row.append(&menu);
    let expander = gtk::TreeExpander::new();
    expander.set_indent_for_icon(true);
    expander.set_child(Some(&row));
    follow_expansion(&expander);
    item.set_child(Some(&expander));
}

fn bind(item: &glib::Object, index: &SharedIndex) {
    let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
        return;
    };
    let (Some(tree_row), Some(expander)) = (
        item.item().and_downcast::<gtk::TreeListRow>(),
        item.child().and_downcast::<gtk::TreeExpander>(),
    ) else {
        return;
    };
    let index = index.borrow();
    let Some(node) = key_of(&tree_row).and_then(|key| index.nodes.get(&key)) else {
        return;
    };
    expander.set_list_row(Some(&tree_row));
    expander.set_hide_expander(matches!(node, Node::Folder(folder) if index.children(Some(folder.id)).is_empty()));
    let Some(row) = expander.child() else {
        return;
    };
    row.set_widget_name(&node.key().target());
    if let Some(icon) = row.first_child().and_downcast::<gtk::Image>() {
        icon.set_icon_name(Some(match node {
            Node::Folder(_) => "folder-symbolic",
            Node::Query(_) => "text-x-generic-symbolic",
        }));
    }
    if let Some(labels) = row.first_child().and_then(|icon| icon.next_sibling()) {
        if let Some(name) = labels.first_child().and_downcast::<gtk::Label>() {
            name.set_label(node.name());
        }
        if let Some(summary) = labels.last_child().and_downcast::<gtk::Label>() {
            let text = match node {
                Node::Folder(_) => "",
                Node::Query(query) => query.summary(),
            };
            summary.set_label(text);
            summary.set_visible(!text.is_empty());
        }
    }
    if let Some(menu) = row.last_child().and_downcast::<gtk::MenuButton>() {
        let label = gettext_f("Options for “{name}”", &[("name", node.name())]);
        menu.set_tooltip_text(Some(&label));
        menu.update_property(&[gtk::accessible::Property::Label(&label)]);
        menu.set_menu_model(Some(&menu_of(node.key())));
    }
    let label = accessible_label(node, &index);
    item.set_accessible_label(&label);
    expander.update_property(&[gtk::accessible::Property::Label(&label)]);
}

fn unbind(item: &glib::Object) {
    let Some(expander) = item
        .downcast_ref::<gtk::ListItem>()
        .and_then(|item| item.child())
        .and_downcast::<gtk::TreeExpander>()
    else {
        return;
    };
    if let Some(row) = expander.child() {
        row.set_widget_name("");
        if let Some(menu) = row.last_child().and_downcast::<gtk::MenuButton>() {
            menu.popdown();
            menu.set_menu_model(None::<&gio::MenuModel>);
        }
    }
    expander.set_list_row(None);
    expander.update_property(&[gtk::accessible::Property::Label("")]);
}

fn accessible_label(node: &Node, index: &Index) -> String {
    let label = match node {
        Node::Folder(_) => gettext_f("Folder “{name}”", &[("name", node.name())]),
        Node::Query(_) => gettext_f("Saved query “{name}”", &[("name", node.name())]),
    };
    match node.parent().and_then(|parent| index.path(parent)) {
        Some(path) => gettext_f("{item} in {folder}", &[("item", &label), ("folder", path)]),
        None => label,
    }
}

fn follow_expansion(expander: &gtk::TreeExpander) {
    // GTK updates the arrow's expanded state; the row's accessible node needs it too.
    let watched: Rc<RefCell<Option<(gtk::TreeListRow, glib::SignalHandlerId)>>> = Rc::default();
    expander.connect_list_row_notify({
        let watched = watched.clone();
        move |expander| {
            if let Some((row, watch)) = watched.take() {
                row.disconnect(watch);
            }
            let Some(row) = expander.list_row().filter(|row| row.is_expandable()) else {
                expander.update_state(&[gtk::accessible::State::Expanded(None)]);
                return;
            };
            expander.update_state(&[gtk::accessible::State::Expanded(Some(row.is_expanded()))]);
            let weak = expander.downgrade();
            let watch = row.connect_expanded_notify(move |row| {
                if let Some(expander) = weak.upgrade() {
                    expander.update_state(&[gtk::accessible::State::Expanded(Some(row.is_expanded()))]);
                }
            });
            watched.replace(Some((row, watch)));
        }
    });
    expander.connect_destroy(move |_| {
        if let Some((row, watch)) = watched.take() {
            row.disconnect(watch);
        }
    });
}

pub(super) fn install_menu(
    list: &gtk::ListView,
    tree: &gtk::TreeListModel,
    index: &SharedIndex,
    selection: &gtk::SingleSelection,
    asked: &Asked,
) -> gtk::PopoverMenu {
    let actions = gio::SimpleActionGroup::new();
    for name in [RENAME, DELETE, MOVE, NEW_FOLDER] {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let (tree, index, asked) = (tree.clone(), index.clone(), asked.clone());
        action.connect_activate(move |_, target| {
            let Some(key) = target
                .and_then(|target| target.get::<String>())
                .as_deref()
                .and_then(Key::parse)
            else {
                return;
            };
            if position_of(&tree, key).is_none() {
                return;
            }
            if let Some(node) = index.borrow().nodes.get(&key).cloned() {
                request(&asked, name, node);
            }
        });
        actions.add_action(&action);
    }
    list.insert_action_group("favorite", Some(&actions));
    let menu = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
    menu.set_has_arrow(false);
    menu.set_parent(list);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    click.connect_pressed({
        let (list, index, menu) = (list.downgrade(), index.clone(), menu.clone());
        move |gesture, _, x, y| {
            let Some(list) = list.upgrade() else {
                return;
            };
            let Some(key) = row_at(&list, &index, x, y) else {
                return;
            };
            gesture.set_state(gtk::EventSequenceState::Claimed);
            menu.set_menu_model(Some(&menu_of(key)));
            menu.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            menu.popup();
        }
    });
    list.add_controller(click);
    // A manually parented popover must leave before its parent is finalized.
    list.connect_destroy({
        let menu = menu.clone();
        move |_| menu.unparent()
    });
    install_keys(list, tree, index, selection, asked, &menu);
    menu
}

fn request(asked: &Asked, name: &str, node: Node) {
    let action = match (name, node) {
        (RENAME, Node::Query(query)) => FavoriteAction::Rename(query),
        (DELETE, Node::Query(query)) => FavoriteAction::Delete(query),
        (MOVE, Node::Query(query)) => FavoriteAction::MoveTo(query),
        (RENAME, Node::Folder(folder)) => FavoriteAction::RenameFolder(folder),
        (DELETE, Node::Folder(folder)) => FavoriteAction::DeleteFolder(folder),
        (NEW_FOLDER, Node::Folder(folder)) => FavoriteAction::NewFolder(Some(folder)),
        _ => return,
    };
    asked(action);
}

fn install_keys(
    list: &gtk::ListView,
    tree: &gtk::TreeListModel,
    index: &SharedIndex,
    selection: &gtk::SingleSelection,
    asked: &Asked,
    menu: &gtk::PopoverMenu,
) {
    let keys = gtk::EventControllerKey::new();
    keys.set_name(Some(KEYS));
    let (selection, tree, index, asked, menu, list_weak) = (
        selection.clone(),
        tree.clone(),
        index.clone(),
        asked.clone(),
        menu.clone(),
        list.downgrade(),
    );
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let modifiers = modifiers.intersection(gtk::accelerator_get_default_mod_mask());
        let Some(row_key) = tree.row(selection.selected()).as_ref().and_then(key_of) else {
            return glib::Propagation::Proceed;
        };
        let Some(node) = index.borrow().nodes.get(&row_key).cloned() else {
            return glib::Propagation::Proceed;
        };
        if (key == gtk::gdk::Key::Menu && modifiers.is_empty())
            || (key == gtk::gdk::Key::F10 && modifiers == gtk::gdk::ModifierType::SHIFT_MASK)
        {
            let Some(list) = list_weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            let anchor = find_row(&list, row_key)
                .and_then(|row| row.compute_bounds(&list))
                .map(|bounds| {
                    gtk::gdk::Rectangle::new(
                        bounds.x() as i32,
                        bounds.y() as i32,
                        bounds.width() as i32,
                        bounds.height() as i32,
                    )
                });
            menu.set_menu_model(Some(&menu_of(row_key)));
            menu.set_pointing_to(anchor.as_ref());
            menu.popup();
            return glib::Propagation::Stop;
        }
        if !modifiers.is_empty() {
            return glib::Propagation::Proceed;
        }
        match key {
            gtk::gdk::Key::F2 => request(&asked, RENAME, node),
            gtk::gdk::Key::Delete | gtk::gdk::Key::KP_Delete => request(&asked, DELETE, node),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    list.add_controller(keys);
}

pub(super) fn menu_of(key: Key) -> gio::Menu {
    let menu = gio::Menu::new();
    let entries = match key {
        Key::Query(_) => [
            (gettext("_Rename…"), RENAME),
            (gettext("_Move to Folder…"), MOVE),
            (gettext("_Delete…"), DELETE),
        ],
        Key::Folder(_) => [
            (gettext("New _Subfolder…"), NEW_FOLDER),
            (gettext("_Rename…"), RENAME),
            (gettext("_Delete…"), DELETE),
        ],
    };
    for (label, action) in entries {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(&format!("favorite.{action}")), Some(&key.target().to_variant()));
        menu.append_item(&item);
    }
    menu
}

fn row_at(list: &gtk::ListView, index: &SharedIndex, x: f64, y: f64) -> Option<Key> {
    let mut widget = list.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(candidate) = widget {
        if candidate.has_css_class(ROW) {
            let key = Key::parse(&candidate.widget_name())?;
            return index.borrow().nodes.contains_key(&key).then_some(key);
        }
        widget = candidate.parent();
    }
    None
}

pub(super) fn find_row(widget: &impl IsA<gtk::Widget>, key: Key) -> Option<gtk::Widget> {
    let widget = widget.as_ref();
    if widget.has_css_class(ROW) && widget.widget_name() == key.target() {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if let Some(row) = find_row(&current, key) {
            return Some(row);
        }
        child = current.next_sibling();
    }
    None
}
