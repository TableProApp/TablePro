use gtk4::prelude::*;
use gtk4::{self as gtk};

use super::GridMsg;
use super::display::{POPOVER_SLOT, POSITION_SLOT, ROW_KEY_SLOT};
use crate::ui::cell_editor::CellEditor;

pub(super) fn enum_commit_text(label: &str) -> String {
    if label.is_empty() {
        "''".to_owned()
    } else {
        label.to_owned()
    }
}

pub(super) fn set_commit_text(labels: &[String], checked: &[bool]) -> String {
    let members: Vec<&str> = labels
        .iter()
        .zip(checked)
        .filter(|(_, on)| **on)
        .map(|(label, _)| label.as_str())
        .collect();
    if members.is_empty() {
        "''".to_owned()
    } else {
        members.join(",")
    }
}

pub(super) fn checked_members(labels: &[String], current: &str) -> Vec<bool> {
    let members: Vec<&str> = current.split(',').collect();
    labels.iter().map(|label| members.contains(&label.as_str())).collect()
}

#[derive(Clone)]
struct Picker {
    cell: CellEditor,
    col_index: usize,
    sender: relm4::Sender<GridMsg>,
    popover: gtk::Popover,
}

impl Picker {
    fn commit(&self, text: String) {
        let row_position = POSITION_SLOT.get(&self.cell).unwrap_or(0);
        let row_key = ROW_KEY_SLOT.cloned(&self.cell).unwrap_or_default();
        self.sender
            .send(GridMsg::CellEdited {
                row_position,
                col_index: self.col_index,
                new_value: text,
                row_key,
            })
            .ok();
        self.popover.popdown();
    }
}

fn shown(label: &str) -> String {
    if label.is_empty() {
        crate::tr!("(empty)")
    } else {
        label.to_owned()
    }
}

fn enum_content(picker: Picker, labels: Vec<String>, current: &str) -> gtk::Widget {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .build();
    list.add_css_class("boxed-list");
    for label in &labels {
        let row = gtk::Label::builder()
            .label(shown(label))
            .xalign(0.0)
            .margin_top(6)
            .margin_bottom(6)
            .build();
        if label == current {
            row.add_css_class("accent");
        }
        list.append(&row);
    }
    list.connect_row_activated(move |_, row| {
        if let Some(label) = labels.get(row.index() as usize) {
            picker.commit(enum_commit_text(label));
        }
    });
    list.upcast()
}

fn set_content(picker: Picker, labels: Vec<String>, current: &str) -> gtk::Widget {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .build();
    list.add_css_class("boxed-list");
    let boxes: Vec<gtk::CheckButton> = labels
        .iter()
        .zip(checked_members(&labels, current))
        .map(|(label, on)| {
            let check = gtk::CheckButton::builder().label(shown(label)).active(on).build();
            check.set_can_focus(false);
            check.set_can_target(false);
            list.append(&check);
            check
        })
        .collect();
    let toggled = boxes.clone();
    list.connect_row_activated(move |_, row| {
        if let Some(check) = toggled.get(row.index() as usize) {
            check.set_active(!check.is_active());
        }
    });
    let apply = gtk::Button::builder().label(crate::tr!("Apply")).build();
    apply.add_css_class("suggested-action");
    apply.connect_clicked(move |_| {
        let checked: Vec<bool> = boxes.iter().map(|check| check.is_active()).collect();
        picker.commit(set_commit_text(&labels, &checked));
    });
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .build();
    body.append(&list);
    body.append(&apply);
    body.upcast()
}

pub(super) fn show_choice_popover(
    cell: &CellEditor,
    col_index: usize,
    sender: &relm4::Sender<GridMsg>,
    labels: Vec<String>,
    is_set: bool,
) {
    let popover = gtk::Popover::new();
    popover.set_parent(cell);
    POPOVER_SLOT.set(cell, popover.clone());
    let picker = Picker {
        cell: cell.clone(),
        col_index,
        sender: sender.clone(),
        popover: popover.clone(),
    };
    let current = cell.text().to_string();
    let content = if is_set {
        set_content(picker, labels, &current)
    } else {
        enum_content(picker, labels, &current)
    };
    let scrolled = gtk::ScrolledWindow::builder()
        .max_content_height(320)
        .propagate_natural_height(true)
        .margin_top(8)
        .margin_bottom(8)
        .margin_start(8)
        .margin_end(8)
        .child(&content)
        .build();
    popover.set_child(Some(&scrolled));
    let cell_for_close = cell.clone();
    popover.connect_closed(move |p| {
        p.unparent();
        POPOVER_SLOT.take(&cell_for_close);
    });
    popover.popup();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| item.to_string()).collect()
    }

    #[test]
    fn an_empty_enum_member_is_sent_as_the_explicit_empty_marker_so_it_never_means_null() {
        assert_eq!(enum_commit_text(""), "''");
        assert_eq!(enum_commit_text("red"), "red");
    }

    #[test]
    fn a_set_value_lists_the_checked_members_in_declared_order() {
        let all = labels(&["a", "b", "c"]);
        assert_eq!(set_commit_text(&all, &[true, false, true]), "a,c");
        assert_eq!(set_commit_text(&all, &[false, false, false]), "''");
    }

    #[test]
    fn the_members_come_from_the_column_type_with_quotes_unescaped() {
        let (is_set, found) = crate::ui::browse_tab::mysql_enum_set_labels("set('a','b''c')").unwrap();
        assert!(is_set);
        assert_eq!(found, labels(&["a", "b'c"]));
        assert!(!crate::ui::browse_tab::mysql_enum_set_labels("enum('x')").unwrap().0);
        assert!(crate::ui::browse_tab::mysql_enum_set_labels("enum(broken").is_none());
    }

    #[test]
    fn the_current_set_value_pre_checks_its_members() {
        let all = labels(&["a", "b", "c"]);
        assert_eq!(checked_members(&all, "a,c"), [true, false, true]);
        assert_eq!(checked_members(&all, ""), [false, false, false]);
        assert_eq!(checked_members(&all, "b"), [false, true, false]);
    }
}
