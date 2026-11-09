use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use libadwaita as adw;
use tablepro_core::DriverError;
use tablepro_test_support::FakeReply;

use super::{
    BrowseTab, Harness, PagingInput, Shown, WAIT, full_page, grid_cell_of, not_null_name, rows, serving_table, text,
    type_into,
};
use crate::test_support::{SignalLog, descendants, wait_until};

fn json_text(tab: &BrowseTab) -> Option<String> {
    let state = tab.imp().json_view.borrow();
    let view = state.as_ref()?;
    if !view.copy_action().is_enabled() {
        return None;
    }
    let buffer = view.view().buffer();
    Some(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string())
}

fn json_rows(tab: &BrowseTab) -> Option<serde_json::Value> {
    serde_json::from_str(&json_text(tab)?).ok()
}

fn json_widgets(tab: &BrowseTab) -> Vec<gtk4::Widget> {
    let state = tab.imp().json_view.borrow();
    descendants(state.as_ref().expect("the JSON view").widget())
}

#[gtk4::test]
fn the_bottom_bar_shows_the_rows_as_json_without_structure_support() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    let _shown = Shown::new(tab);
    wait_until(WAIT, || harness.shown() == text(&["Ada", "Grace"])).expect("the page");
    let imp = tab.imp();
    assert!(imp.view_toggle.is_visible());
    assert!(!imp.view_stack.page(&imp.structure_host.get()).is_visible());
    assert!(imp.view_stack.page(&imp.json_host.get()).is_visible());
    imp.view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some()).expect("the JSON preview");
    let json = json_rows(tab).unwrap();
    assert_eq!(json[0]["name"], "Ada");
    assert_eq!(json[1]["name"], "Grace");
    let view = imp.json_view.borrow().as_ref().unwrap().view().clone();
    assert!(!view.is_editable());
    assert!(view.is_cursor_visible(), "keyboard selection needs a cursor");
    assert!(!imp.data_start.is_visible() && !imp.data_end.is_visible());
    assert!(imp.rows_start.is_visible() && imp.json_end.is_visible());
    assert!(tab.activate_action("grid.insert-row", None).is_err());
    assert!(tab.activate_action("grid.delete-rows", None).is_err());
    imp.view_stack.set_visible_child_name("data");
    assert!(imp.insert_button.is_visible());
    assert!(!imp.json_end.is_visible());
}

#[gtk4::test]
fn json_follows_equal_length_pages_and_refreshes() {
    let mut script = serving_table();
    script.count_rows.always(FakeReply::ok(1_000));
    script
        .query_bound
        .once(FakeReply::ok(full_page(0)))
        .once(FakeReply::ok(full_page(100)))
        .always(FakeReply::ok(full_page(200)));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    tab.imp().view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["id"] == 0)).expect("the first JSON page");
    tab.activate_action("browse.next-page", None).unwrap();
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["id"] == 100)).expect("the next JSON page");
    tab.send(PagingInput::Refresh);
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["id"] == 200)).expect("the refreshed JSON page");
    assert_eq!(json_rows(tab).unwrap().as_array().unwrap().len(), 100);
    assert!(tab.activate_action("grid.insert-row", None).is_err());
    assert!(!tab.imp().data_start.is_visible());
}

#[gtk4::test]
fn json_replaces_failed_filter_results_with_error_and_retry() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["old"])))
        .once(FakeReply::err(DriverError::server("relation <users> is gone")))
        .always(FakeReply::ok(rows(&["fresh"])));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    let _shown = Shown::new(tab);
    tab.imp().view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some()).expect("the JSON preview");
    tab.send(PagingInput::FilterApplied(not_null_name()));
    wait_until(WAIT, || {
        json_widgets(tab).iter().any(|widget| {
            widget
                .downcast_ref::<adw::StatusPage>()
                .is_some_and(|page| page.is_mapped() && page.title() == "Couldn't Load Rows")
        })
    })
    .expect("the JSON error page");
    assert!(
        json_text(tab).is_none(),
        "old rows could still be copied as current results"
    );
    let error = json_widgets(tab)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::StatusPage>().ok())
        .find(|page| page.is_mapped())
        .unwrap();
    assert!(error.description().unwrap().contains("relation &lt;users&gt; is gone"));
    let retry = error.child().unwrap().downcast::<gtk4::Button>().unwrap();
    let refreshes = SignalLog::connect(tab, "refresh-requested", |_| ());
    retry.emit_clicked();
    assert_eq!(refreshes.count(), 1);
    // This harness has no workspace to approve the request for its clean draft.
    tab.send(PagingInput::Refresh);
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["name"] == "fresh")).expect("retry refreshed JSON");
}

#[gtk4::test]
fn json_keeps_failed_refresh_visible_under_its_stale_banner() {
    let mut script = serving_table();
    script
        .query_bound
        .once(FakeReply::ok(rows(&["kept"])))
        .once(FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(rows(&["fresh"])));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    let _shown = Shown::new(tab);
    tab.imp().view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some()).expect("the JSON preview");
    tab.send(PagingInput::Refresh);
    let stale = || {
        json_widgets(tab)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::Banner>().ok())
            .find(|banner| banner.is_revealed() && banner.title().starts_with("Couldn't refresh rows."))
    };
    wait_until(WAIT, || stale().is_some()).expect("the JSON stale banner");
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["name"] == "kept")).expect("last good rows remain");
    let refreshes = SignalLog::connect(tab, "refresh-requested", |_| ());
    stale().unwrap().emit_by_name::<()>("button-clicked", &[]);
    assert_eq!(refreshes.count(), 1);
    // This harness has no workspace to approve the request for its clean draft.
    tab.send(PagingInput::Refresh);
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["name"] == "fresh")).expect("Retry updates JSON");
    assert!(stale().is_none());
}

#[gtk4::test]
fn selecting_json_commits_the_open_cell_without_exposing_row_write_commands() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    let _shown = Shown::new(tab);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the row");
    let cell = grid_cell_of(tab, 0, 1);
    let _editor = type_into(&harness, &cell, "Edited");
    let saves = SignalLog::connect(tab, "save-requested", |_| ());
    tab.imp().view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some_and(|rows| rows[0]["name"] == "Edited"))
        .expect("the pending edit in JSON");
    assert!(!harness.grid().is_editing());
    assert_eq!(harness.tracker.pending_count(), 1);
    let view = tab.imp().json_view.borrow().as_ref().unwrap().view().clone();
    wait_until(WAIT, || view.is_mapped()).expect("the JSON text is mapped");
    assert!(view.grab_focus());
    use crate::application::ShortcutOwner;
    use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
    let ctrl_s = shortcuts(&owner_controller(tab, ShortcutOwner::BrowseTab).unwrap())
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke("<Primary>s")))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("Ctrl+S is bound");
    assert!(ctrl_s.activate(gtk4::ShortcutActionFlags::empty(), &view, None));
    for action in [
        "browse.save",
        "browse.undo",
        "browse.redo",
        "grid.insert-row",
        "grid.delete-rows",
    ] {
        assert!(
            tab.activate_action(action, None).is_err(),
            "{action} reached hidden rows"
        );
    }
    assert_eq!(saves.count(), 0);
    assert_eq!(harness.tracker.pending_count(), 1);
    tab.activate_action("browse.filter", None).unwrap();
    assert!(tab.shows_data());
    assert!(tab.read(|model| model.filter_strip.revealed()).unwrap());
}

#[gtk4::test]
fn json_keeps_read_only_insert_policy_and_fits_the_window_floor() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_read_only(script);
    let tab = harness.tab();
    tab.offer_structure();
    let window = crate::test_support::OwnedWindow::presented(
        adw::Window::builder()
            .default_width(360)
            .default_height(400)
            .content(tab)
            .build(),
    );
    let imp = tab.imp();
    wait_until(WAIT, || harness.shown().len() == 1 && imp.more_button.is_mapped()).expect("the compact Data bar");
    assert!(!imp.insert_button.is_visible());
    let (data_width, ..) = imp.action_bar.measure(gtk4::Orientation::Horizontal, -1);
    assert!(data_width <= 360, "the three-view Data bar needs {data_width}px");
    imp.view_stack.set_visible_child_name("json");
    wait_until(WAIT, || json_rows(tab).is_some() && imp.json_more.is_mapped()).expect("the compact JSON bar");
    let (json_width, ..) = imp.action_bar.measure(gtk4::Orientation::Horizontal, -1);
    assert!(json_width <= 360, "the JSON bar needs {json_width}px");
    tab.send(PagingInput::Refresh);
    wait_until(WAIT, || !tab.is_loading() && json_rows(tab).is_some()).expect("the refreshed preview");
    assert!(!imp.insert_button.is_visible());
    imp.view_stack.set_visible_child_name("data");
    assert!(
        !imp.insert_button.is_visible(),
        "returning from JSON exposed Insert on a read-only table"
    );
    window.set_size_request(1_000, 400);
    wait_until(WAIT, || !imp.more_button.is_mapped()).expect("the wide bar");
    assert_eq!(
        imp.view_toggle.display_mode(),
        adw::InlineViewSwitcherDisplayMode::Labels
    );
}

fn switch_labels(tab: &BrowseTab) -> Vec<gtk4::Label> {
    descendants(&tab.imp().view_toggle.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk4::Label>().ok())
        .filter(|label| !label.label().is_empty())
        .collect()
}

fn bar_shortfall(tab: &BrowseTab) -> Option<String> {
    let cut: Vec<String> = switch_labels(tab)
        .iter()
        .filter(|label| label.layout().is_ellipsized() || label.layout().pixel_size().0 > label.width())
        .map(|label| label.label().to_string())
        .collect();
    let (needs, ..) = tab.imp().action_bar.measure(gtk4::Orientation::Horizontal, -1);
    (!cut.is_empty() || needs > tab.width())
        .then(|| format!("cut {cut:?}, the bar needs {needs} px of {}", tab.width()))
}

fn menu_actions(menu: &gtk4::gio::MenuModel) -> Vec<String> {
    (0..menu.n_items())
        .filter_map(|index| menu.item_link(index, gtk4::gio::MENU_LINK_SECTION))
        .flat_map(|section| {
            (0..section.n_items())
                .filter_map(|index| {
                    section
                        .item_attribute_value(index, gtk4::gio::MENU_ATTRIBUTE_ACTION, None)
                        .and_then(|value| value.get::<String>())
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

#[gtk4::test]
fn the_view_switch_keeps_its_names_in_a_1200_px_window() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open(script, []);
    let tab = harness.tab();
    tab.offer_structure();
    let window = crate::test_support::OwnedWindow::presented(
        adw::Window::builder()
            .default_width(1_200)
            .default_height(400)
            .content(tab)
            .build(),
    );
    let imp = tab.imp();
    let columns = crate::test_support::find_by_action_name(tab, "grid.columns")
        .and_downcast::<gtk4::Button>()
        .expect("a Columns button");
    wait_until(WAIT, || {
        window.is_mapped() && tab.width() >= 1_200 && harness.shown().len() == 1
    })
    .expect("the tab fills the window");
    let names: Vec<String> = switch_labels(tab)
        .iter()
        .map(|label| label.label().to_string())
        .collect();
    assert_eq!(names, ["Data", "Structure", "JSON"]);
    assert!(
        wait_until(WAIT, || bar_shortfall(tab).is_none()).is_ok(),
        "{:?}",
        bar_shortfall(tab)
    );
    assert!(columns.is_visible() && imp.export_button.is_visible() && imp.page_size_dropdown.is_mapped());
    assert!(!imp.overflow_button.is_visible());

    // What a 1200 px window leaves the tab beside the sidebar at its widest.
    window.set_default_size(920, 400);
    wait_until(WAIT, || {
        tab.width() > 0 && tab.width() <= 920 && imp.overflow_button.is_mapped()
    })
    .expect("the tab beside the sidebar");
    assert!(
        wait_until(WAIT, || bar_shortfall(tab).is_none()).is_ok(),
        "{:?}",
        bar_shortfall(tab)
    );
    assert_eq!(
        imp.view_toggle.display_mode(),
        adw::InlineViewSwitcherDisplayMode::Labels
    );
    assert!(!columns.is_visible() && !imp.export_button.is_visible() && !imp.page_size_dropdown.is_mapped());
    assert!(!imp.more_button.is_visible());
    let moved = menu_actions(&imp.overflow_button.menu_model().expect("the overflow menu"));
    for action in ["grid.columns", "browse.export", "browse.page-size"] {
        assert!(
            moved.iter().any(|found| found == action),
            "the overflow menu lacks {action}"
        );
    }
}
