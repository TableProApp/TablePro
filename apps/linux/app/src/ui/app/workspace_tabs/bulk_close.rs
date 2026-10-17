use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use uuid::Uuid;

use super::{AppMsg, read_workspace_tab_id};

pub(super) fn add_bulk_close_actions(
    group: &gtk::gio::SimpleActionGroup,
    menu_target: Rc<RefCell<Option<adw::TabPage>>>,
    dispatch: impl Fn(AppMsg) + 'static,
) {
    let dispatch = Rc::new(dispatch);
    for (name, message) in [
        ("close-others", AppMsg::CloseOtherWorkspaceTabs as fn(Uuid) -> AppMsg),
        ("close-right", AppMsg::CloseWorkspaceTabsToRight as fn(Uuid) -> AppMsg),
    ] {
        let target = menu_target.clone();
        let dispatch = dispatch.clone();
        let action = gtk::gio::SimpleAction::new(name, None);
        action.connect_activate(move |_, _| {
            let page = target.borrow().clone();
            if let Some(id) = page.as_ref().and_then(read_workspace_tab_id) {
                dispatch(message(id));
            }
        });
        group.add_action(&action);
    }
}

pub(super) fn bulk_close_menu_model() -> gtk::gio::Menu {
    let menu = gtk::gio::Menu::new();
    menu.append(Some(&crate::tr!("Keep Tab")), Some("tab.keep"));
    menu.append_section(None, &gtk::gio::Menu::new());
    menu.append(Some(&crate::tr!("Close Other Tabs")), Some("tab.close-others"));
    menu.append(Some(&crate::tr!("Close Tabs to the Right")), Some("tab.close-right"));
    menu
}

#[cfg(test)]
mod tests {
    use super::super::write_workspace_tab_id;
    use super::*;
    use relm4::gtk::prelude::WidgetExt;

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn bulk_close_actions_dispatch_the_selected_page_id() {
        relm4::adw::init().unwrap();
        let view = adw::TabView::new();
        let menu = bulk_close_menu_model();
        assert_eq!(menu.n_items(), 4);
        assert_eq!(
            menu.item_attribute_value(2, "action", None)
                .and_then(|value| value.get::<String>()),
            Some("tab.close-others".into())
        );
        assert_eq!(
            menu.item_attribute_value(3, "action", None)
                .and_then(|value| value.get::<String>()),
            Some("tab.close-right".into())
        );
        view.set_menu_model(Some(&menu));
        let page = view.append(&gtk::Box::new(gtk::Orientation::Vertical, 0));
        let id = Uuid::new_v4();
        write_workspace_tab_id(&page, id);
        let target = Rc::new(RefCell::new(Some(page)));
        let (sender, receiver) = std::sync::mpsc::channel();
        let group = gtk::gio::SimpleActionGroup::new();
        add_bulk_close_actions(&group, target, move |message| {
            sender.send(message).unwrap();
        });
        view.insert_action_group("tab", Some(&group));

        assert!(view.activate_action("tab.close-others", None).is_ok());
        assert!(matches!(
            receiver.recv().unwrap(),
            AppMsg::CloseOtherWorkspaceTabs(target_id) if target_id == id
        ));
        assert!(view.activate_action("tab.close-right", None).is_ok());
        assert!(matches!(
            receiver.recv().unwrap(),
            AppMsg::CloseWorkspaceTabsToRight(target_id) if target_id == id
        ));
    }
}
