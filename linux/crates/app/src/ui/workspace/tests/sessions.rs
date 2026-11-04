//! Two sessions in one shell: which one is in front, and the tab bar
//! they share.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{open_editor, two_sessions};
use crate::test_support::{descendants, wait_until};
use crate::ui::session_window::tests::WAIT;

#[gtk4::test]
fn the_front_follows_the_tab_on_screen() {
    let sessions = two_sessions("FrontFollowsTab", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let heading = shell.imp().window_title.get();
    assert_eq!(
        shell.front().as_ref(),
        Some(second),
        "with no tab on screen the session that joined last speaks for the window"
    );

    let ours = open_editor(first);
    assert_eq!(
        shell.front().as_ref(),
        Some(first),
        "the first tab of an empty bar left its session behind"
    );
    let theirs = open_editor(second);
    assert_eq!(shell.front().as_ref(), Some(second));
    wait_until(WAIT, || heading.subtitle() == "Other").expect("the header to name the other connection");

    shell.tab_view().set_selected_page(&ours);

    assert_eq!(
        shell.front().as_ref(),
        Some(first),
        "the front waited for the main loop"
    );
    assert_eq!(heading.title(), "Query 1");
    assert_eq!(heading.subtitle(), "Fake");
    wait_until(WAIT, || {
        sessions.test.window.title().as_deref() == Some("Query 1 (Fake) - TablePro")
    })
    .expect("the window's title to follow");
    shell.tab_view().set_selected_page(&theirs);
    assert_eq!(heading.subtitle(), "Other");
}

#[gtk4::test]
fn showing_a_session_brings_its_tab_or_opens_an_editor_for_it() {
    let sessions = two_sessions("ShowSession", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let view = shell.tab_view();
    let ours = open_editor(first);

    shell.show_session(second);

    assert_eq!(
        shell.front().as_ref(),
        Some(second),
        "the window's actions still went to the other session"
    );
    wait_until(WAIT, || {
        view.selected_page().is_some_and(|page| second.tab_id(&page).is_some())
    })
    .expect("an editor for the session with no tab");

    shell.show_session(first);

    assert_eq!(
        view.selected_page(),
        Some(ours),
        "the session came back without the tab it was left on"
    );
    assert_eq!(shell.front().as_ref(), Some(first));
}

#[gtk4::test]
fn reopen_brings_back_a_tab_closed_in_the_session_behind() {
    let sessions = two_sessions("ReopenAcross", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let view = shell.tab_view();
    let theirs = open_editor(second);
    let ours = open_editor(first);

    view.close_page(&ours);
    wait_until(WAIT, || !first.has_tabs()).expect("the tab to close");
    assert_eq!(view.selected_page(), Some(theirs));
    assert_eq!(
        shell.front().as_ref(),
        Some(second),
        "the tab shown next speaks for the window"
    );

    WidgetExt::activate_action(&sessions.test.window, "win.reopen-closed-tab", None).expect("win.reopen-closed-tab");

    wait_until(WAIT, || first.has_tabs()).expect("the tab back in the session it was closed in");
    assert_eq!(shell.front().as_ref(), Some(first));
    assert_eq!(view.n_pages(), 2, "the reopen went to the other session");
}

#[gtk4::test]
fn close_other_tabs_closes_the_tabs_of_every_session() {
    let sessions = two_sessions("CloseOthersAcross", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let view = shell.tab_view();
    let kept = open_editor(first);
    open_editor(first);
    open_editor(second);
    shell.imp().menu_target.replace(Some(kept.clone()));

    WidgetExt::activate_action(&view, "tab.close-others", None).expect("Close Other Tabs");

    wait_until(WAIT, || view.n_pages() == 1).expect("every other tab to close");
    assert_eq!(view.nth_page(0), kept);
    assert!(!second.has_tabs(), "the other session's tab stayed");
}

#[gtk4::test]
fn the_tab_menu_closes_later_tabs_of_any_session_and_ends_with_close() {
    let sessions = two_sessions("CloseAfterAcross", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let view = shell.tab_view();
    let before = open_editor(first);
    let anchor = open_editor(second);
    open_editor(first);
    open_editor(second);
    shell.imp().menu_target.replace(Some(anchor.clone()));

    WidgetExt::activate_action(&view, "tab.close-after", None).expect("Close Tabs After This One");

    wait_until(WAIT, || view.n_pages() == 2).expect("the later tabs to close");
    assert_eq!((view.nth_page(0), view.nth_page(1)), (before, anchor));
    let menu = view.menu_model().expect("the tab menu");
    let sections: Vec<gio::MenuModel> = (0..menu.n_items())
        .filter_map(|section| menu.item_link(section, "section"))
        .collect();
    let attribute = |items: &gio::MenuModel, item: i32, name: &str| {
        items
            .item_attribute_value(item, name, None)
            .and_then(|value| value.get::<String>())
            .unwrap_or_default()
    };
    let last = sections.last().expect("a section");
    assert_eq!(
        attribute(last, last.n_items() - 1, "action"),
        "tab.close",
        "Close is not the last item"
    );
    for items in &sections {
        for item in 0..items.n_items() {
            let label = attribute(items, item, "label");
            assert!(!label.contains("Left") && !label.contains("Right"), "{label}");
        }
    }
}

/// libadwaita parents the tab menu to a tab box in the bar and to a
/// tab grid in the overview, never to the view.
#[gtk4::test]
fn the_tab_menu_reaches_its_actions_from_the_bar_and_the_overview() {
    let sessions = two_sessions("TabMenuReach", "Other");
    let shell = &sessions.shell;
    open_editor(&sessions.first);
    let parents: Vec<gtk4::Widget> = descendants(&shell.imp().tab_overview.get())
        .into_iter()
        .filter(|widget| ["AdwTabBox", "AdwTabGrid"].contains(&widget.type_().name()))
        .collect();
    assert!(
        parents.iter().any(|widget| widget.type_().name() == "AdwTabBox")
            && parents.iter().any(|widget| widget.type_().name() == "AdwTabGrid"),
        "no tab box or tab grid to open the menu from"
    );
    for parent in &parents {
        for action in ["close-others", "close-after", "close"] {
            assert!(
                parent.activate_action(&format!("tab.{action}"), None).is_ok(),
                "tab.{action} is out of reach of {}",
                parent.type_().name()
            );
        }
    }
}

#[gtk4::test]
fn the_tab_menu_dims_what_would_close_nothing() {
    let sessions = two_sessions("TabMenuDims", "Other");
    let shell = &sessions.shell;
    let view = shell.tab_view();
    let only = open_editor(&sessions.first);
    let enabled = |action: &str| {
        shell
            .imp()
            .tab_actions
            .get()
            .is_some_and(|group| group.is_action_enabled(action))
    };

    view.emit_by_name::<()>("setup-menu", &[&Some(only.clone())]);
    assert!(
        !enabled("close-others") && !enabled("close-after"),
        "one tab has nothing else to close"
    );
    assert!(enabled("close"));

    let last = open_editor(&sessions.second);
    view.emit_by_name::<()>("setup-menu", &[&Some(only)]);
    assert!(enabled("close-others") && enabled("close-after"));
    view.emit_by_name::<()>("setup-menu", &[&Some(last)]);
    assert!(
        enabled("close-others") && !enabled("close-after"),
        "the last tab has none after it"
    );
}

#[gtk4::test]
fn close_all_tabs_closes_the_tabs_of_every_session() {
    let sessions = two_sessions("CloseAllAcross", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    let view = shell.tab_view();
    open_editor(first);
    open_editor(second);
    open_editor(first);

    WidgetExt::activate_action(&sessions.test.window, "win.close-all-tabs", None).expect("win.close-all-tabs");

    wait_until(WAIT, || view.n_pages() == 0).expect("every tab to close");
    assert!(!first.has_tabs() && !second.has_tabs());
}

/// As in GNOME Web: the overview lists every tab, and the tab menu
/// holds what acts on its own tab.
#[gtk4::test]
fn close_all_tabs_is_in_the_overview_menu_and_off_with_no_tab() {
    let sessions = two_sessions("CloseAllInOverview", "Other");
    let window = &sessions.test.window;
    let actions_of = |menu: &gio::MenuModel| -> Vec<String> {
        (0..menu.n_items())
            .filter_map(|section| menu.item_link(section, "section"))
            .flat_map(|items| {
                (0..items.n_items())
                    .filter_map(|item| {
                        items
                            .item_attribute_value(item, "action", None)
                            .and_then(|value| value.get::<String>())
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    };
    let overview_menu = sessions
        .shell
        .imp()
        .tab_overview
        .secondary_menu()
        .expect("the overview's menu");
    assert!(actions_of(&overview_menu).contains(&"win.close-all-tabs".to_owned()));
    let tab_menu = sessions.shell.tab_view().menu_model().expect("the tab menu");
    assert!(!actions_of(&tab_menu).iter().any(|action| action.contains("close-all")));
    let enabled = || {
        window
            .lookup_action("close-all-tabs")
            .is_some_and(|action| action.is_enabled())
    };

    assert!(!enabled(), "Close All Tabs is on with no tab to close");
    let only = open_editor(&sessions.first);
    assert!(enabled(), "Close All Tabs is off with a tab open");
    sessions.shell.tab_view().close_page(&only);
    wait_until(WAIT, || !enabled()).expect("Close All Tabs to go off with the last tab");
}
