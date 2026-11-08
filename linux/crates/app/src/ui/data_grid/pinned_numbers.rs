use std::cell::{Cell, OnceCell, RefCell};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::DataGrid;

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
        pub views: OnceCell<(gtk::ColumnView, gtk::ColumnView)>,
    }

    impl Default for PinnedNumbers {
        fn default() -> Self {
            Self {
                hadjustment: RefCell::default(),
                vadjustment: RefCell::default(),
                hscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
                vscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
                views: OnceCell::new(),
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
    impl ObjectImpl for PinnedNumbers {}

    impl WidgetImpl for PinnedNumbers {}
    impl BinImpl for PinnedNumbers {}
    impl ScrollableImpl for PinnedNumbers {
        fn border(&self) -> Option<gtk::Border> {
            self.views.get().and_then(|(view, _)| view.border())
        }
    }

    impl PinnedNumbers {
        fn set_hadjustment(&self, adjustment: Option<gtk::Adjustment>) {
            self.hadjustment.replace(adjustment);
            if let Some((view, _)) = self.views.get() {
                view.set_hadjustment(self.hadjustment.borrow().as_ref());
            }
        }

        fn set_vadjustment(&self, adjustment: Option<gtk::Adjustment>) {
            self.vadjustment.replace(adjustment);
            if let Some((view, gutter)) = self.views.get() {
                for child in [view, gutter] {
                    child.set_vadjustment(self.vadjustment.borrow().as_ref());
                }
            }
        }

        fn set_hscroll_policy(&self, policy: gtk::ScrollablePolicy) {
            self.hscroll_policy.set(policy);
            if let Some((view, _)) = self.views.get() {
                view.set_hscroll_policy(policy);
            }
        }

        fn set_vscroll_policy(&self, policy: gtk::ScrollablePolicy) {
            self.vscroll_policy.set(policy);
            if let Some((view, gutter)) = self.views.get() {
                for child in [view, gutter] {
                    child.set_vscroll_policy(policy);
                }
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
    let gutter = imp.gutter_view.get();
    // One scroller owns wheel, touch and kinetic scrolling. The projection
    // takes no events, so GTK also keeps one selection anchor and drag gesture.
    gutter.update_state(&[gtk::accessible::State::Hidden(true)]);
    gutter.set_model(Some(&grid.selection()));
    gutter.append_column(&super::row_number_column::build(grid));
    // A sortable header reserves icon height even when its title is shorter.
    if let (Some(header), Some(projected)) = (header(&view), header(&gutter)) {
        let height = gtk::SizeGroup::new(gtk::SizeGroupMode::Vertical);
        height.add_widget(&header);
        height.add_widget(&projected);
    }
    let _ = viewport.imp().views.set((view.clone(), gutter.clone()));
    view.set_hadjustment(viewport.hadjustment().as_ref());
    for child in [&view, &gutter] {
        child.set_vadjustment(viewport.vadjustment().as_ref());
        child.set_vscroll_policy(viewport.vscroll_policy());
    }
    view.set_hscroll_policy(viewport.hscroll_policy());
    imp.scrolled.hadjustment().connect_value_changed(glib::clone!(
        #[weak]
        grid,
        move |_| sync(&grid)
    ));
}

pub(super) fn sync(grid: &DataGrid) {
    let imp = grid.imp();
    let gutter = &imp.gutter_view;
    if let Some(column) = grid.row_numbers_column()
        && let Some(projection) = gutter.columns().item(0).and_downcast::<gtk::ColumnViewColumn>()
    {
        projection.set_fixed_width(column.fixed_width());
        gutter.set_width_request(column.fixed_width());
    }
    gutter.set_visible(imp.scrolled.hadjustment().value() > 0.0);
}

pub(super) fn covers(grid: &DataGrid, x: f64) -> bool {
    let gutter = &grid.imp().gutter_view;
    gutter.is_visible() && x >= 0.0 && x < f64::from(gutter.width())
}

pub(super) fn reveal_focus(grid: &DataGrid) {
    let Some(cell) = grid.focused_cell() else {
        return;
    };
    // GTK scrolls focus into the full view; the fixed gutter covers its left edge.
    glib::idle_add_local_once(glib::clone!(
        #[weak]
        grid,
        #[weak]
        cell,
        move || {
            if grid.focused_cell().as_ref() != Some(&cell) {
                return;
            }
            let Some(bounds) = cell.compute_bounds(&grid.column_view()) else {
                return;
            };
            let width = grid.row_numbers_column().map_or(0, |column| column.fixed_width());
            if bounds.x() < width as f32 {
                let adjustment = grid.imp().scrolled.hadjustment();
                adjustment.set_value(adjustment.value() + f64::from(bounds.x()) - f64::from(width));
            }
        }
    ));
}

fn header(view: &gtk::ColumnView) -> Option<gtk::Widget> {
    let mut child = view.first_child();
    while let Some(widget) = child {
        if widget.css_name() == "header" {
            return Some(widget);
        }
        child = widget.next_sibling();
    }
    None
}
