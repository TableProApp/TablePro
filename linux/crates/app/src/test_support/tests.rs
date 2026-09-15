use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::test_support::{
    SignalLog, UnlabelledWidget, WaitTimedOut, assert_labelled, descendants, drain_main_context, find_by_action_name,
    first_descendant_of_type, wait_until,
};

fn init_adwaita() {
    adw::init().unwrap();
}

#[gtk4::test]
fn wait_until_returns_once_an_idle_source_sets_the_flag() {
    let flag = Rc::new(Cell::new(false));
    let setter = Rc::clone(&flag);
    glib::idle_add_local_once(move || setter.set(true));
    assert_eq!(wait_until(Duration::from_secs(2), || flag.get()), Ok(()));
    drain_main_context();
}

#[gtk4::test]
fn wait_until_times_out_instead_of_blocking() {
    let timeout = Duration::from_millis(50);
    assert_eq!(wait_until(timeout, || false), Err(WaitTimedOut { timeout }));
}

#[gtk4::test]
fn signal_log_records_clicked_emissions() {
    let button = gtk4::Button::new();
    let log = SignalLog::connect(&button, "clicked", |_| ());
    button.emit_clicked();
    button.emit_clicked();
    assert_eq!(log.count(), 2);
    assert_eq!(log.take().len(), 2);
    assert_eq!(log.count(), 0);
}

#[gtk4::test]
fn signal_log_disconnects_on_drop() {
    let button = gtk4::Button::new();
    let clicked = glib::subclass::SignalId::lookup("clicked", gtk4::Button::static_type()).unwrap();
    let log = SignalLog::connect(&button, "clicked", |_| ());
    assert!(glib::signal::signal_has_handler_pending(&button, clicked, None, false));
    drop(log);
    assert!(!glib::signal::signal_has_handler_pending(&button, clicked, None, false));
}

#[gtk4::test]
fn find_by_action_name_finds_a_nested_button() {
    let outer = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    let inner = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    let button = gtk4::Button::with_label("Save");
    button.set_action_name(Some("win.save"));
    inner.append(&gtk4::Label::new(Some("Unsaved changes")));
    inner.append(&button);
    outer.append(&inner);

    assert_eq!(find_by_action_name(&outer, "win.save"), Some(button.clone().upcast()));
    assert_eq!(find_by_action_name(&outer, "win.missing"), None);
    assert_eq!(first_descendant_of_type::<gtk4::Button>(&outer), Some(button));
    assert!(descendants(&outer).len() >= 3);
}

#[gtk4::test]
fn icon_button_without_label_is_reported() {
    let button = gtk4::Button::from_icon_name(crate::ui::icons::LIST_ADD);
    assert_eq!(
        assert_labelled(&button),
        Err(UnlabelledWidget::MissingLabel {
            type_name: "GtkButton".to_owned()
        })
    );
}

#[gtk4::test]
fn icon_button_with_accessible_label_passes() {
    let button = gtk4::Button::from_icon_name(crate::ui::icons::LIST_ADD);
    button.update_property(&[gtk4::accessible::Property::Label("Add connection")]);
    assert_eq!(assert_labelled(&button), Ok(()));
}

#[gtk4::test]
fn entry_labelled_by_a_label_passes() {
    let label = gtk4::Label::new(Some("Host"));
    let entry = gtk4::Entry::new();
    entry.update_relation(&[gtk4::accessible::Relation::LabelledBy(&[label.upcast_ref()])]);
    assert_eq!(assert_labelled(&entry), Ok(()));
}

#[gtk4::test]
fn entry_row_with_title_passes() {
    init_adwaita();
    let row = adw::EntryRow::builder().title("Host").build();
    assert_eq!(assert_labelled(&row), Ok(()));
}

#[gtk4::test]
fn entry_row_without_title_is_reported() {
    init_adwaita();
    let row = adw::EntryRow::new();
    assert_eq!(
        assert_labelled(&row),
        Err(UnlabelledWidget::EmptyRowTitle {
            type_name: "AdwEntryRow".to_owned()
        })
    );
}

#[gtk4::test]
fn password_entry_row_with_title_passes() {
    init_adwaita();
    let row = adw::PasswordEntryRow::builder().title("Password").build();
    assert_eq!(assert_labelled(&row), Ok(()));
}

#[gtk4::test]
fn action_row_with_activatable_check_button_passes() {
    init_adwaita();
    let check = gtk4::CheckButton::new();
    let row = adw::ActionRow::builder().title("Read only").build();
    row.add_suffix(&check);
    row.set_activatable_widget(Some(&check));
    assert_eq!(assert_labelled(&row), Ok(()));
}
