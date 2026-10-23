use relm4::gtk::prelude::*;
use relm4::{ComponentController, Controller, gtk};
use tablepro_core::Value;
use uuid::Uuid;

use super::save_in_flight_tests::{column, launch_with_read_only, load_two_rows, pump};
use super::{BrowseTab, BrowseTabInput, BrowseTabOutput};

fn descendants(root: &gtk::Widget) -> Vec<gtk::Widget> {
    let mut out = Vec::new();
    let mut child = root.first_child();
    while let Some(widget) = child {
        out.extend(descendants(&widget));
        child = widget.next_sibling();
        out.push(widget);
    }
    out
}

fn launch_tab(read_only: bool) -> (Controller<BrowseTab>, std::sync::mpsc::Receiver<BrowseTabOutput>) {
    relm4::gtk::init().unwrap();
    launch_with_read_only(Uuid::new_v4(), read_only)
}

#[test]
#[ignore = "requires isolated GTK display"]
fn a_row_count_queued_before_refresh_is_not_shown() {
    let (controller, outputs) = launch_tab(false);
    controller
        .sender()
        .send(BrowseTabInput::ColumnsLoaded(vec![column("id", true)]))
        .unwrap();
    pump(&outputs);
    let stale = controller.model().row_count_requests.begin();
    controller.sender().send(BrowseTabInput::Refresh).unwrap();
    controller
        .sender()
        .send(BrowseTabInput::RowCountLoaded {
            request: stale,
            count: 7,
        })
        .unwrap();
    pump(&outputs);
    assert_eq!(controller.model().current_total_rows, None);
}

#[test]
#[ignore = "requires isolated GTK display"]
fn page_size_changes_apply_after_a_failed_first_load() {
    let (controller, outputs) = launch_tab(false);
    controller
        .sender()
        .send(BrowseTabInput::ShowError("connection lost".into()))
        .unwrap();
    controller.sender().send(BrowseTabInput::PageSizeChanged(500)).unwrap();
    pump(&outputs);
    assert_eq!(controller.model().page_size, 500);
}

#[test]
#[ignore = "requires isolated GTK display"]
fn read_only_selection_does_not_offer_delete() {
    let (controller, outputs) = launch_tab(true);
    load_two_rows(&controller, &outputs);
    controller.model().current_selection.as_ref().unwrap().select_all();
    pump(&outputs);
    let label = controller.model().selection_count_label.label();
    assert!(label.contains('2'));
    assert!(!label.contains("Delete"));
}

#[test]
#[ignore = "requires isolated GTK display"]
fn load_error_page_retries_the_fetch() {
    let (controller, outputs) = launch_tab(false);
    controller
        .sender()
        .send(BrowseTabInput::ShowError("connection lost".into()))
        .unwrap();
    pump(&outputs);
    while outputs.try_recv().is_ok() {}
    let page = controller.model().inner_stack.child_by_name("error").unwrap();
    let retry = descendants(&page)
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Button>().ok())
        .unwrap();
    retry.emit_clicked();
    let fetched = pump(&outputs);
    assert!(
        fetched
            .iter()
            .any(|output| matches!(output, BrowseTabOutput::FetchPage))
    );
    assert!(
        fetched
            .iter()
            .any(|output| matches!(output, BrowseTabOutput::FetchRowCount))
    );
}

#[test]
#[ignore = "requires isolated GTK display"]
fn paginator_controls_have_accessible_names() {
    let (controller, _outputs) = launch_tab(false);
    let bar = controller
        .model()
        .first_button
        .ancestor(gtk::ActionBar::static_type())
        .unwrap();
    let controls = descendants(&bar);
    let icon_buttons: Vec<_> = controls
        .iter()
        .filter_map(|widget| widget.downcast_ref::<gtk::Button>())
        .filter(|button| button.icon_name().is_some())
        .collect();
    assert!(icon_buttons.len() >= 6);
    for button in icon_buttons {
        assert!(
            gtk::test_accessible_has_property(button, gtk::AccessibleProperty::Label),
            "{:?} has no accessible label",
            button.icon_name()
        );
    }
    let dropdown = controls
        .iter()
        .find_map(|widget| widget.downcast_ref::<gtk::DropDown>())
        .unwrap();
    assert!(gtk::test_accessible_has_relation(
        dropdown,
        gtk::AccessibleRelation::LabelledBy
    ));
}

#[test]
#[ignore = "requires isolated GTK display"]
fn an_edit_for_a_saved_row_does_not_land_on_a_draft_inserted_at_its_position() {
    let (controller, outputs) = launch_tab(false);
    load_two_rows(&controller, &outputs);
    assert!(controller.model().row_position_still_holds(0, &[Value::Int(1)]));
    controller.sender().send(BrowseTabInput::InsertRow).unwrap();
    pump(&outputs);
    assert!(!controller.model().row_position_still_holds(0, &[Value::Int(1)]));
}
