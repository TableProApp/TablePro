use std::cell::{Cell, OnceCell, RefCell};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::prelude::BinExt;
use libadwaita::subclass::prelude::*;

use super::{DataGrid, GridCell};

mod imp {
    use super::*;

    #[derive(glib::Properties)]
    #[properties(wrapper_type = super::PinnedNumbers)]
    pub struct PinnedNumbers {
        #[property(override_interface = gtk::Scrollable, get, set = Self::set_hadjustment)]
        hadjustment: RefCell<Option<gtk::Adjustment>>,
        #[property(override_interface = gtk::Scrollable, get, set = Self::set_vadjustment)]
        vadjustment: RefCell<Option<gtk::Adjustment>>,
        #[property(override_interface = gtk::Scrollable, get, set = Self::set_hscroll_policy)]
        hscroll_policy: Cell<gtk::ScrollablePolicy>,
        #[property(override_interface = gtk::Scrollable, get, set = Self::set_vscroll_policy)]
        vscroll_policy: Cell<gtk::ScrollablePolicy>,
        pub view: OnceCell<gtk::ColumnView>,
        pub grid: glib::WeakRef<DataGrid>,
        pub focus: RefCell<Option<glib::WeakRef<GridCell>>>,
    }

    impl Default for PinnedNumbers {
        fn default() -> Self {
            Self {
                hadjustment: RefCell::default(),
                vadjustment: RefCell::default(),
                hscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
                vscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
                view: OnceCell::new(),
                grid: glib::WeakRef::new(),
                focus: RefCell::default(),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for PinnedNumbers {
        const NAME: &'static str = "TableProPinnedNumbers";
        type Type = super::PinnedNumbers;
        type ParentType = adw::Bin;
        type Interfaces = (gtk::Scrollable,);
    }

    #[glib::derived_properties]
    impl ObjectImpl for PinnedNumbers {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().set_layout_manager(None::<gtk::LayoutManager>);
        }
    }

    impl WidgetImpl for PinnedNumbers {
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            self.obj()
                .child()
                .map_or((0, 0, -1, -1), |child| child.measure(orientation, for_size))
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let Some(child) = self.obj().child() else {
                return;
            };
            child.allocate(width, height, baseline, None);
            // Native keyboard navigation updates the adjustment before allocation.
            // Correct its reveal only after the new cell geometry is available.
            let pending = self.focus.borrow_mut().take();
            if let Some(cell) = pending.and_then(|cell| cell.upgrade())
                && let Some(grid) = self.grid.upgrade()
                && grid.focused_cell().as_ref() == Some(&cell)
                && super::reveal_allocated(&grid, &cell)
            {
                child.allocate(width, height, baseline, None);
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            self.parent_snapshot(snapshot);
            if let Some(grid) = self.grid.upgrade() {
                super::snapshot_numbers(&grid, snapshot);
            }
        }
    }

    impl BinImpl for PinnedNumbers {}
    impl ScrollableImpl for PinnedNumbers {
        fn border(&self) -> Option<gtk::Border> {
            self.view.get().and_then(|view| view.border())
        }
    }

    impl PinnedNumbers {
        fn set_hadjustment(&self, adjustment: Option<gtk::Adjustment>) {
            self.hadjustment.replace(adjustment);
            if let Some(view) = self.view.get() {
                view.set_hadjustment(self.hadjustment.borrow().as_ref());
            }
        }

        fn set_vadjustment(&self, adjustment: Option<gtk::Adjustment>) {
            self.vadjustment.replace(adjustment);
            if let Some(view) = self.view.get() {
                view.set_vadjustment(self.vadjustment.borrow().as_ref());
            }
        }

        fn set_hscroll_policy(&self, policy: gtk::ScrollablePolicy) {
            self.hscroll_policy.set(policy);
            if let Some(view) = self.view.get() {
                view.set_hscroll_policy(policy);
            }
        }

        fn set_vscroll_policy(&self, policy: gtk::ScrollablePolicy) {
            self.vscroll_policy.set(policy);
            if let Some(view) = self.view.get() {
                view.set_vscroll_policy(policy);
            }
        }
    }
}

glib::wrapper! {
    pub struct PinnedNumbers(ObjectSubclass<imp::PinnedNumbers>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Scrollable;
}

pub(super) fn install(grid: &DataGrid) {
    let imp = grid.imp();
    let viewport = &imp.viewport;
    let view = grid.column_view();
    viewport.imp().grid.set(Some(grid));
    let _ = viewport.imp().view.set(view.clone());
    view.set_hadjustment(viewport.hadjustment().as_ref());
    view.set_vadjustment(viewport.vadjustment().as_ref());
    view.set_hscroll_policy(viewport.hscroll_policy());
    view.set_vscroll_policy(viewport.vscroll_policy());
    imp.gutter_backing.update_state(&[gtk::accessible::State::Hidden(true)]);
    imp.scrolled.hadjustment().connect_value_changed(glib::clone!(
        #[weak]
        grid,
        move |_| {
            cancel_reveal(&grid);
            sync(&grid);
        }
    ));
}

pub(super) fn sync(grid: &DataGrid) {
    let imp = grid.imp();
    if let Some(column) = grid.row_numbers_column() {
        imp.gutter_backing.set_width_request(column.fixed_width());
    }
    imp.gutter_backing.set_visible(imp.scrolled.hadjustment().value() > 0.0);
    imp.viewport.queue_draw();
    grid.edit().queue_editor_allocate();
}

pub(super) fn bounds(grid: &DataGrid) -> Option<gtk::graphene::Rect> {
    let gutter = &grid.imp().gutter_backing;
    gutter
        .is_visible()
        .then(|| gutter.compute_bounds(&grid.column_view()))
        .flatten()
}

pub(super) fn covered_edge(grid: &DataGrid) -> Option<f32> {
    if !grid.imp().gutter_backing.is_visible() {
        return None;
    }
    let width = grid.row_numbers_column()?.fixed_width() as f32;
    let view = grid.column_view();
    // The backing is allocated after the view, so its previous bounds can be stale.
    Some(match view.direction() {
        gtk::TextDirection::Rtl => view.width() as f32 - width,
        _ => width,
    })
}

pub(super) fn covers(grid: &DataGrid, x: f64) -> bool {
    bounds(grid).is_some_and(|rect| x >= f64::from(rect.x()) && x < f64::from(rect.x() + rect.width()))
}

pub(super) fn cancel_reveal(grid: &DataGrid) {
    grid.imp().viewport.imp().focus.take();
}

pub(super) fn reveal_focus(grid: &DataGrid) {
    if let Some(cell) = grid.focused_cell() {
        grid.imp().viewport.imp().focus.replace(Some(cell.downgrade()));
        grid.imp().viewport.queue_allocate();
    }
}

fn reveal_allocated(grid: &DataGrid, cell: &GridCell) -> bool {
    let Some(cell) = cell.compute_bounds(&grid.column_view()) else {
        return false;
    };
    let Some(gutter) = bounds(grid) else {
        return false;
    };
    let covered = match grid.column_view().direction() {
        gtk::TextDirection::Rtl => cell.x() + cell.width() - gutter.x(),
        _ => gutter.x() + gutter.width() - cell.x(),
    };
    if covered <= 0.0 {
        return false;
    }
    let adjustment = grid.imp().scrolled.hadjustment();
    let before = adjustment.value();
    adjustment.set_value(before - f64::from(covered));
    adjustment.value() != before
}

fn snapshot_numbers(grid: &DataGrid, snapshot: &gtk::Snapshot) {
    let Some(gutter) = bounds(grid) else {
        return;
    };
    let view = grid.column_view();
    let mut child = view.first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        let Some(area) = widget.compute_bounds(&view) else {
            continue;
        };
        snapshot.push_clip(&gtk::graphene::Rect::new(
            gutter.x(),
            area.y(),
            gutter.width(),
            area.height(),
        ));
        if widget.css_name() == "header" {
            if let Some(column) = widget.first_child() {
                snapshot_column(&view, &widget, &column, gutter.x(), snapshot);
            }
        } else if widget.is::<gtk::ListView>() {
            let mut row = widget.first_child();
            while let Some(current) = row {
                row = current.next_sibling();
                if let Some(column) = current.first_child()
                    && let Some(content) = column.first_child()
                    && content.has_css_class("row-number-cell")
                    && let Some(rect) = current.compute_bounds(&view)
                    && rect.y() < view.height() as f32
                    && rect.y() + rect.height() > area.y()
                {
                    snapshot_column(&view, &current, &column, gutter.x(), snapshot);
                }
            }
        }
        snapshot.pop();
    }
}

fn snapshot_column(
    view: &gtk::ColumnView,
    row: &gtk::Widget,
    column: &gtk::Widget,
    target_x: f32,
    snapshot: &gtk::Snapshot,
) {
    let Some(parent) = row.parent() else {
        return;
    };
    let (Some(source), Some(parent_bounds)) = (column.compute_bounds(&parent), parent.compute_bounds(view)) else {
        return;
    };
    // snapshot_child requires the actual parent and an untransformed snapshot.
    // Reusing the native row keeps selection, stripes, icons and CSS in one model.
    let native = gtk::Snapshot::new();
    parent.snapshot_child(row, &native);
    if let Some(node) = native.to_node() {
        snapshot.save();
        snapshot.translate(&gtk::graphene::Point::new(target_x - source.x(), parent_bounds.y()));
        snapshot.append_node(&node);
        snapshot.restore();
    }
}
