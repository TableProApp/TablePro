use std::rc::Rc;
use std::sync::Arc;

use gtk4::{self as gtk, gio, glib};
use libadwaita::{self as adw, prelude::*};

use crate::services::database_service::DatabaseService;

pub(super) fn install(
    view: &gtk::ColumnView,
    actions: &gio::SimpleActionGroup,
    columns: &[gtk::ColumnViewColumn],
    names: Vec<String>,
    connection: Option<uuid::Uuid>,
    database: Arc<DatabaseService>,
) {
    let columns = Rc::new(columns.iter().map(|column| column.downgrade()).collect::<Vec<_>>());
    let action = gio::SimpleAction::new("jump-column", None);
    action.set_enabled(!columns.is_empty() && connection.is_some());
    let weak_view = view.downgrade();
    let install_database = database.clone();
    action.connect_activate(move |_, _| {
        let Some(view) = weak_view.upgrade().filter(|view| view.is_mapped()) else {
            return;
        };
        if connection.and_then(|id| install_database.get(id)).is_none() {
            return;
        }
        present(&view, columns.clone(), &names, connection, install_database.clone());
    });
    actions.add_action(&action);
    let controller = gtk::ShortcutController::new();
    controller.set_propagation_phase(gtk::PropagationPhase::Capture);
    controller.add_shortcut(
        gtk::Shortcut::builder()
            .trigger(&crate::ui::shortcut::parse("<Primary><Shift>j"))
            .action(&gtk::NamedAction::new("grid.jump-column"))
            .build(),
    );
    view.add_controller(controller);
}

fn present(
    view: &gtk::ColumnView,
    columns: Rc<Vec<glib::WeakRef<gtk::ColumnViewColumn>>>,
    names: &[String],
    connection: Option<uuid::Uuid>,
    database: Arc<DatabaseService>,
) {
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Jump to Column"))
        .content_width(420)
        .content_height(420)
        .build();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
    content.append(&adw::HeaderBar::new());
    let search = gtk::SearchEntry::builder()
        .placeholder_text(crate::tr!("Search columns"))
        .margin_start(12)
        .margin_end(12)
        .build();
    search.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Search columns"))]);
    content.append(&search);
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .activate_on_single_click(true)
        .build();
    list.add_css_class("boxed-list");
    let choices = names
        .iter()
        .enumerate()
        .map(|(ordinal, name)| {
            let label = format!("{} · {}", ordinal + 1, name);
            let row = gtk::ListBoxRow::new();
            let child = gtk::Label::builder()
                .label(&label)
                .xalign(0.0)
                .margin_start(12)
                .margin_end(12)
                .margin_top(8)
                .margin_bottom(8)
                .build();
            row.set_child(Some(&child));
            row.update_property(&[gtk::accessible::Property::Label(&label)]);
            list.append(&row);
            (row, name.to_lowercase())
        })
        .collect::<Vec<_>>();
    list.select_row(list.row_at_index(0).as_ref());
    let empty = gtk::Label::new(Some(&crate::tr!("No matching columns")));
    empty.set_visible(false);
    content.append(&empty);
    content.append(
        &gtk::ScrolledWindow::builder()
            .child(&list)
            .vexpand(true)
            .margin_start(12)
            .margin_end(12)
            .margin_bottom(12)
            .build(),
    );
    let choices = Rc::new(choices);
    search.connect_search_changed({
        let list = list.clone();
        let choices = choices.clone();
        move |search| {
            let needle = search.text().to_lowercase();
            let mut first = None;
            for (row, name) in choices.iter() {
                let matches = name.contains(&needle);
                row.set_visible(matches);
                if matches && first.is_none() {
                    first = Some(row.clone());
                }
            }
            list.select_row(first.as_ref());
            empty.set_visible(first.is_none());
        }
    });
    search.connect_stop_search({
        let dialog = dialog.downgrade();
        move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.close();
            }
        }
    });
    search.connect_activate({
        let list = list.clone();
        move |_| {
            if let Some(row) = list.selected_row().filter(|row| row.is_visible()) {
                row.activate();
            }
        }
    });
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let list = list.clone();
        move |_, key, _, _| {
            let step = match key {
                gtk::gdk::Key::Down => 1,
                gtk::gdk::Key::Up => -1,
                _ => return glib::Propagation::Proceed,
            };
            let mut next = list.selected_row().map_or(-1, |row| row.index()) + step;
            while let Some(row) = list.row_at_index(next) {
                if row.is_visible() {
                    list.select_row(Some(&row));
                    break;
                }
                next += step;
            }
            glib::Propagation::Stop
        }
    });
    search.add_controller(keys);
    list.connect_row_activated({
        let view = view.downgrade();
        let dialog = dialog.downgrade();
        move |_, row| {
            let Some(dialog) = dialog.upgrade() else {
                return;
            };
            if let Some(view) = view.upgrade().filter(|view| view.is_mapped()) {
                let live = connection.and_then(|id| database.get(id)).is_some();
                let column = usize::try_from(row.index())
                    .ok()
                    .and_then(|index| columns.get(index))
                    .and_then(glib::WeakRef::upgrade);
                if live && let Some(column) = column {
                    reveal(&view, &column);
                }
            }
            dialog.close();
        }
    });
    let unmapped = view.connect_unmap({
        let dialog = dialog.downgrade();
        move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.close();
            }
        }
    });
    dialog.connect_closed({
        let view = view.downgrade();
        let unmapped = std::cell::RefCell::new(Some(unmapped));
        move |_| {
            if let (Some(view), Some(handler)) = (view.upgrade(), unmapped.borrow_mut().take()) {
                view.disconnect(handler);
            }
        }
    });
    dialog.set_child(Some(&content));
    dialog.present(Some(view));
    search.grab_focus();
}

fn reveal(view: &gtk::ColumnView, column: &gtk::ColumnViewColumn) -> bool {
    if !view.is_mapped() || column.column_view().as_ref() != Some(view) {
        return false;
    }
    column.set_visible(true);
    if let Some(model) = view.model().filter(|model| model.n_items() > 0) {
        let selected = model.selection();
        let position = if selected.is_empty() { 0 } else { selected.minimum() };
        view.scroll_to(position, Some(column), gtk::ListScrollFlags::FOCUS, None);
    } else if let Some(adjustment) = view.hadjustment() {
        let columns = view.columns();
        let mut x = 0;
        for index in 0..columns.n_items() {
            let Some(current) = columns
                .item(index)
                .and_then(|item| item.downcast::<gtk::ColumnViewColumn>().ok())
            else {
                continue;
            };
            if current == *column {
                break;
            }
            if current.is_visible() {
                x += current.fixed_width().max(0);
            }
        }
        adjustment.set_value(f64::from(x).min((adjustment.upper() - adjustment.page_size()).max(0.0)));
    }
    view.grab_focus();
    true
}

pub(super) fn open_in(widget: &gtk::Widget) -> bool {
    if !widget.is_mapped() {
        return false;
    }
    if let Some(view) = widget.downcast_ref::<gtk::ColumnView>() {
        return view.activate_action("grid.jump-column", None).is_ok();
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if open_in(&current) {
            return true;
        }
        child = current.next_sibling();
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn stale_picker_cannot_target_a_replacement_grid() {
        gtk::init().unwrap();
        let original = gtk::ColumnView::new(None::<gtk::MultiSelection>);
        let first = gtk::ColumnViewColumn::new(Some("duplicate"), None::<gtk::SignalListItemFactory>);
        let second = gtk::ColumnViewColumn::new(Some("duplicate"), None::<gtk::SignalListItemFactory>);
        original.append_column(&first);
        original.append_column(&second);
        let window = gtk::Window::builder().child(&original).build();
        window.present();
        original.remove_column(&first);
        original.append_column(&first);
        second.set_visible(false);
        assert!(reveal(&original, &second));
        assert!(second.is_visible());
        assert_eq!(original.columns().item(0).unwrap(), second);
        let replacement = gtk::ColumnView::new(None::<gtk::MultiSelection>);
        window.set_child(Some(&replacement));
        assert!(!reveal(&original, &second));
        assert!(!reveal(&replacement, &second));
        original.remove_column(&second);
        assert!(!reveal(&replacement, &second));
        window.close();
    }
}
