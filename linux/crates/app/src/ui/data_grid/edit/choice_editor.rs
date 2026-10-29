use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::ColumnKind;

use super::EditController;
use super::cell_editor::InlineStart;
use crate::i18n::gettext;
use crate::services::grid::{CommitResult, EditStart, GridColumn, commit_edit};
use crate::ui::data_grid::{DataGrid, GridCell};
use crate::ui::error_text::edit_parse_message;

/// A set's text lists its labels apart with commas, as MySQL writes it.
const SET_SEPARATOR: char = ',';

impl EditController {
    /// A menu of the column's labels on the cell, as a drop-down shows
    /// them: one click picks an enum's label, and a set's labels are
    /// checked and then set together.
    pub(super) fn open_choice(&self, grid: &DataGrid, cell: &GridCell, start: &InlineStart) {
        let ColumnKind::Enum { labels, multiple } = &start.column.value_type().kind else {
            return;
        };
        grid.commit_editors();
        let popover = gtk::Popover::builder().has_arrow(false).build();
        popover.add_css_class("menu");
        popover.set_parent(grid);
        let commit = {
            let grid = grid.downgrade();
            let column = start.column.clone();
            let opened = start.start.clone();
            let popover = popover.downgrade();
            move |text: String| {
                if let Some(popover) = popover.upgrade() {
                    popover.popdown();
                }
                if let Some(grid) = grid.upgrade() {
                    grid.edit().commit_choice(&grid, &column, &opened, &text);
                }
            }
        };
        let content = match multiple {
            false => single_choice(labels, &start.text, commit),
            true => set_choice(labels, &start.text, commit),
        };
        popover.set_child(Some(&content));
        let returned = cell.downgrade();
        let weak = grid.downgrade();
        popover.connect_closed(move |popover| {
            if let (Some(grid), Some(cell)) = (weak.upgrade(), returned.upgrade()) {
                grid.return_focus(&cell);
            }
            // Out of the grid once the popover's own close is over.
            let popover = popover.clone();
            glib::idle_add_local_once(move || popover.unparent());
        });
        let at = cell.compute_bounds(grid).map(|bounds| {
            gtk::gdk::Rectangle::new(
                bounds.x() as i32,
                bounds.y() as i32,
                bounds.width() as i32,
                bounds.height() as i32,
            )
        });
        popover.set_pointing_to(at.as_ref());
        popover.popup();
    }

    fn commit_choice(&self, grid: &DataGrid, column: &GridColumn, start: &EditStart, text: &str) {
        match commit_edit(column, start, text) {
            CommitResult::Edit(edit) => self.apply_edit(grid, edit),
            CommitResult::Unchanged => {}
            CommitResult::Rejected(error) => grid.toast(edit_parse_message(&error)),
        }
    }
}

/// One row per label, the cell's own marked; activating one picks it.
fn single_choice(labels: &[String], current: &str, commit: impl Fn(String) + 'static) -> gtk::Widget {
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    for label in labels {
        let row = gtk::Box::builder().spacing(12).build();
        let name = gtk::Label::builder().label(label).xalign(0.0).hexpand(true).build();
        row.append(&name);
        let check = gtk::Image::builder()
            .icon_name("object-select-symbolic")
            .accessible_role(gtk::AccessibleRole::Presentation)
            .opacity(if label == current { 1.0 } else { 0.0 })
            .build();
        row.append(&check);
        let item = gtk::ListBoxRow::builder().child(&row).build();
        item.update_property(&[gtk::accessible::Property::Label(label)]);
        if label == current {
            item.update_state(&[gtk::accessible::State::Selected(Some(true))]);
        }
        list.append(&item);
    }
    let labels = labels.to_vec();
    list.connect_row_activated(move |_, row| {
        if let Some(label) = usize::try_from(row.index()).ok().and_then(|index| labels.get(index)) {
            commit(label.clone());
        }
    });
    scrolled(list.upcast())
}

/// A check per label, the cell's own checked, and Set to write them.
fn set_choice(labels: &[String], current: &str, commit: impl Fn(String) + 'static) -> gtk::Widget {
    let held: Vec<&str> = current.split(SET_SEPARATOR).map(str::trim).collect();
    let checks: Vec<gtk::CheckButton> = labels
        .iter()
        .map(|label| {
            gtk::CheckButton::builder()
                .label(label)
                .active(held.contains(&label.as_str()))
                .build()
        })
        .collect();
    let list = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .build();
    for check in &checks {
        list.append(check);
    }
    let set = gtk::Button::builder()
        .label(gettext("Set"))
        .halign(gtk::Align::End)
        .margin_top(6)
        .build();
    set.add_css_class("suggested-action");
    let labels = labels.to_vec();
    set.connect_clicked(move |_| {
        let chosen: Vec<&str> = labels
            .iter()
            .zip(&checks)
            .filter(|(_, check)| check.is_active())
            .map(|(label, _)| label.as_str())
            .collect();
        commit(chosen.join(&SET_SEPARATOR.to_string()));
    });
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(6)
        .margin_end(6)
        .build();
    content.append(&scrolled(list.upcast()));
    content.append(&set);
    content.upcast()
}

/// A long list scrolls rather than run off the screen.
fn scrolled(child: gtk::Widget) -> gtk::Widget {
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(360)
        .child(&child)
        .build()
        .upcast()
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;
    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;

    use super::super::tests::pending;
    use crate::test_support::{descendants, drain_main_context};
    use crate::ui::data_grid::test_grid::{Grid, named};

    fn sizes() -> Grid {
        Grid::open(
            vec![
                named("id", "integer", true),
                named("size", "enum('small','medium','large')", false),
                named("tags", "set('new','sale','gift')", false),
            ],
            vec![vec![
                Value::Int(1),
                Value::Text("small".into()),
                Value::Text("new".into()),
            ]],
        )
    }

    fn shown<W: IsA<gtk::Widget>>(grid: &Grid) -> Vec<W> {
        drain_main_context();
        descendants(&grid.grid)
            .into_iter()
            .filter(|widget| widget.is_mapped())
            .filter_map(|widget| widget.downcast::<W>().ok())
            .collect()
    }

    #[gtk4::test]
    fn an_enum_cell_opens_its_labels_and_takes_the_one_picked() {
        let grid = sizes();
        assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));

        let rows: Vec<gtk::ListBoxRow> = shown(&grid);
        assert_eq!(rows.len(), 3, "one row per label");
        rows[2].emit_activate();
        drain_main_context();

        assert_eq!(
            pending(&grid, 1, 1),
            Some(CellInput::Value(Value::Text("large".into())))
        );
        assert!(shown::<gtk::ListBoxRow>(&grid).is_empty(), "the menu closed");
    }

    #[gtk4::test]
    fn a_set_cell_checks_its_labels_and_sets_them_together() {
        let grid = sizes();
        assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 2)));

        let checks: Vec<gtk::CheckButton> = shown(&grid);
        assert_eq!(checks.len(), 3);
        assert!(checks[0].is_active(), "the cell's own label");
        checks[2].set_active(true);
        let set: Vec<gtk::Button> = shown(&grid);
        set.iter()
            .find(|button| button.label().as_deref() == Some("Set"))
            .expect("Set")
            .emit_clicked();
        drain_main_context();

        assert_eq!(
            pending(&grid, 1, 2),
            Some(CellInput::Value(Value::Text("new,gift".into())))
        );
    }
}
