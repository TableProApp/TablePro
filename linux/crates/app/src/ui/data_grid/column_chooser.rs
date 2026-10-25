use std::cell::{Cell, OnceCell, RefCell};
use std::collections::HashMap;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gio, glib, pango};
use libadwaita as adw;
use libadwaita::prelude::*;
use libadwaita::subclass::prelude::*;

use super::DataGrid;

/// A signal the dialog keeps connected on the grid while it is open.
type Watch = (glib::WeakRef<glib::Object>, glib::SignalHandlerId);

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/column-chooser.ui")]
    pub struct ColumnChooser {
        #[template_child]
        pub search_entry: TemplateChild<gtk::SearchEntry>,
        #[template_child]
        pub stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub list_view: TemplateChild<gtk::ListView>,
        #[template_child]
        pub reset_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub show_all_button: TemplateChild<gtk::Button>,

        pub grid: glib::WeakRef<DataGrid>,
        /// The grid's data columns, in the order on screen.
        pub columns: OnceCell<gio::ListStore>,
        pub filter: OnceCell<gtk::StringFilter>,
        /// Each drawn row's check follows its column's visibility.
        pub bindings: RefCell<HashMap<glib::Object, glib::Binding>>,
        pub grid_watch: RefCell<Option<Watch>>,
        pub visibility_watches: RefCell<Vec<Watch>>,
        pub refill_queued: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ColumnChooser {
        const NAME: &'static str = "TableProColumnChooser";
        type Type = super::ColumnChooser;
        type ParentType = adw::Dialog;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ColumnChooser {
        fn dispose(&self) {
            self.obj().stop_watching();
            for (_, binding) in self.bindings.take() {
                binding.unbind();
            }
        }
    }

    impl WidgetImpl for ColumnChooser {}
    impl AdwDialogImpl for ColumnChooser {}
}

glib::wrapper! {
    /// Which of a grid's columns show, and the way back to the layout the
    /// result came in.
    pub struct ColumnChooser(ObjectSubclass<imp::ColumnChooser>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub fn present(grid: &DataGrid) {
    open(grid);
}

fn open(grid: &DataGrid) -> ColumnChooser {
    let chooser: ColumnChooser = glib::Object::new();
    chooser.setup(grid);
    chooser.present(Some(grid));
    chooser
}

impl ColumnChooser {
    fn setup(&self, grid: &DataGrid) {
        let imp = self.imp();
        imp.grid.set(Some(grid));
        let columns = gio::ListStore::new::<gtk::ColumnViewColumn>();
        let filter = gtk::StringFilter::new(Some(gtk::PropertyExpression::new(
            gtk::ColumnViewColumn::static_type(),
            None::<gtk::Expression>,
            "title",
        )));
        filter.set_match_mode(gtk::StringFilterMatchMode::Substring);
        filter.set_ignore_case(true);
        let filtered = gtk::FilterListModel::new(Some(columns.clone()), Some(filter.clone()));
        filtered.connect_items_changed(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |model, _, _, _| chooser.show_list_or_empty(model.n_items())
        ));
        imp.list_view.set_model(Some(&gtk::NoSelection::new(Some(filtered))));
        imp.list_view.set_factory(Some(&self.row_factory()));
        imp.list_view.connect_activate(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |_, position| chooser.toggle_at(position)
        ));
        let _ = imp.columns.set(columns);
        let _ = imp.filter.set(filter);
        self.wire_controls();
        self.watch_grid(grid);
        self.connect_closed(|chooser| chooser.stop_watching());
        self.refill();
    }

    fn wire_controls(&self) {
        let imp = self.imp();
        imp.search_entry.set_key_capture_widget(Some(self));
        imp.search_entry.connect_search_changed(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |entry| chooser.filter_by(&entry.text())
        ));
        // Escape clears the search first, then closes, which the entry
        // would otherwise keep from the dialog.
        imp.search_entry.connect_stop_search(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |entry| match entry.text().is_empty() {
                true => {
                    chooser.close();
                }
                false => entry.set_text(""),
            }
        ));
        imp.reset_button.connect_clicked(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |_| chooser.reset()
        ));
        imp.show_all_button.connect_clicked(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |_| chooser.show_all()
        ));
    }

    fn grid(&self) -> Option<DataGrid> {
        self.imp().grid.upgrade()
    }

    fn row_factory(&self) -> gtk::SignalListItemFactory {
        let factory = gtk::SignalListItemFactory::new();
        let weak = self.downgrade();
        factory.connect_setup(move |_, item| {
            if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                setup_row(item, weak.clone());
            }
        });
        let weak = self.downgrade();
        factory.connect_bind(move |_, item| {
            if let (Some(item), Some(chooser)) = (item.downcast_ref::<gtk::ListItem>(), weak.upgrade()) {
                chooser.bind_row(item);
            }
        });
        let weak = self.downgrade();
        factory.connect_unbind(move |_, item| {
            if let Some(chooser) = weak.upgrade()
                && let Some(binding) = chooser.imp().bindings.borrow_mut().remove(item)
            {
                binding.unbind();
            }
        });
        factory
    }

    fn bind_row(&self, item: &gtk::ListItem) {
        let (Some(view_column), Some(check), Some(grid)) = (
            item.item().and_downcast::<gtk::ColumnViewColumn>(),
            item.child().and_downcast::<gtk::CheckButton>(),
            self.grid(),
        ) else {
            return;
        };
        let Some(column) = grid
            .column_index(&view_column)
            .and_then(|index| grid.grid_columns().get(index).cloned())
        else {
            return;
        };
        let type_name = column.value_type().name.clone();
        let labels = check.child();
        let label = |widget: Option<gtk::Widget>| widget.and_downcast::<gtk::Label>();
        if let Some(name) = label(labels.as_ref().and_then(|labels| labels.first_child())) {
            name.set_label(&column.name);
        }
        if let Some(kind) = label(labels.as_ref().and_then(|labels| labels.last_child())) {
            kind.set_label(&type_name);
            kind.set_visible(!type_name.is_empty());
        }
        check.update_property(&[gtk::accessible::Property::Label(&column.name)]);
        match type_name.is_empty() {
            true => check.reset_property(gtk::AccessibleProperty::Description),
            false => check.update_property(&[gtk::accessible::Property::Description(&type_name)]),
        }
        let binding = view_column
            .bind_property("visible", &check, "active")
            .sync_create()
            .build();
        if let Some(old) = self.imp().bindings.borrow_mut().insert(item.clone().upcast(), binding) {
            old.unbind();
        }
    }

    /// The user checked or cleared a row.
    fn set_shown(&self, view_column: &gtk::ColumnViewColumn, check: &gtk::CheckButton) {
        let Some(grid) = self.grid() else {
            return;
        };
        let Some(index) = grid.column_index(view_column) else {
            return;
        };
        grid.set_column_visible(index, check.is_active());
        // The grid keeps its last column on screen, so the check goes back.
        if check.is_active() != view_column.is_visible() {
            check.set_active(view_column.is_visible());
        }
    }

    fn toggle_at(&self, position: u32) {
        let Some(view_column) = self
            .imp()
            .list_view
            .model()
            .and_then(|model| model.item(position))
            .and_downcast::<gtk::ColumnViewColumn>()
        else {
            return;
        };
        if let Some(grid) = self.grid()
            && let Some(index) = grid.column_index(&view_column)
        {
            grid.set_column_visible(index, !view_column.is_visible());
        }
    }

    /// List the grid's data columns as they are on screen now.
    fn refill(&self) {
        let (Some(grid), Some(columns)) = (self.grid(), self.imp().columns.get()) else {
            return;
        };
        let view_columns = grid.column_view().columns();
        let shown: Vec<gtk::ColumnViewColumn> = (0..view_columns.n_items())
            .filter_map(|position| view_columns.item(position).and_downcast::<gtk::ColumnViewColumn>())
            .filter(|column| grid.column_index(column).is_some())
            .collect();
        columns.splice(0, columns.n_items(), &shown);
        self.watch_visibility(&shown);
        self.refresh_show_all();
    }

    /// The grid builds its columns again for a reset or a new result, and
    /// the list follows it once the build is done.
    fn watch_grid(&self, grid: &DataGrid) {
        let view_columns = grid.column_view().columns();
        let handler = view_columns.connect_items_changed(glib::clone!(
            #[weak(rename_to = chooser)]
            self,
            move |_, _, _, _| chooser.queue_refill()
        ));
        self.imp()
            .grid_watch
            .replace(Some((view_columns.upcast_ref::<glib::Object>().downgrade(), handler)));
    }

    fn queue_refill(&self) {
        if self.imp().refill_queued.replace(true) {
            return;
        }
        let chooser = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(chooser) = chooser.upgrade() {
                chooser.imp().refill_queued.set(false);
                chooser.refill();
            }
        });
    }

    fn watch_visibility(&self, columns: &[gtk::ColumnViewColumn]) {
        disconnect(self.imp().visibility_watches.take());
        let watches = columns
            .iter()
            .map(|column| {
                let handler = column.connect_visible_notify(glib::clone!(
                    #[weak(rename_to = chooser)]
                    self,
                    move |_| chooser.refresh_show_all()
                ));
                (column.upcast_ref::<glib::Object>().downgrade(), handler)
            })
            .collect();
        self.imp().visibility_watches.replace(watches);
    }

    fn stop_watching(&self) {
        let imp = self.imp();
        disconnect(imp.grid_watch.take());
        disconnect(imp.visibility_watches.take());
    }

    fn refresh_show_all(&self) {
        let imp = self.imp();
        let hidden = imp.columns.get().is_some_and(|columns| {
            columns
                .iter::<gtk::ColumnViewColumn>()
                .flatten()
                .any(|column| !column.is_visible())
        });
        imp.show_all_button.set_sensitive(hidden);
    }

    fn filter_by(&self, text: &str) {
        if let Some(filter) = self.imp().filter.get() {
            filter.set_search(Some(text).filter(|text| !text.is_empty()));
        }
    }

    fn show_list_or_empty(&self, listed: u32) {
        let imp = self.imp();
        let page = match listed == 0 && !imp.search_entry.text().is_empty() {
            true => "empty",
            false => "list",
        };
        imp.stack.set_visible_child_name(page);
    }

    fn reset(&self) {
        if let Some(grid) = self.grid() {
            grid.reset_layout();
            self.refill();
        }
    }

    fn show_all(&self) {
        if let Some(grid) = self.grid() {
            for index in 0..grid.grid_columns().len() {
                grid.set_column_visible(index, true);
            }
        }
    }
}

/// A row is one check: the column's name over its type. The check, not
/// the row, takes the focus, so Space toggles it.
fn setup_row(item: &gtk::ListItem, chooser: glib::WeakRef<ColumnChooser>) {
    item.set_focusable(false);
    let name = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    let kind = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    kind.add_css_class("caption");
    kind.add_css_class("dimmed");
    let labels = gtk::Box::new(gtk::Orientation::Vertical, 2);
    labels.append(&name);
    labels.append(&kind);
    let check = gtk::CheckButton::builder().child(&labels).hexpand(true).build();
    let item_ref = item.downgrade();
    check.connect_toggled(move |check| {
        if let (Some(item), Some(chooser)) = (item_ref.upgrade(), chooser.upgrade())
            && let Some(view_column) = item.item().and_downcast::<gtk::ColumnViewColumn>()
        {
            chooser.set_shown(&view_column, check);
        }
    });
    item.set_child(Some(&check));
}

fn disconnect(watches: impl IntoIterator<Item = Watch>) {
    for (object, handler) in watches {
        if let Some(object) = object.upgrade() {
            object.disconnect(handler);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;
    use libadwaita as adw;
    use libadwaita::prelude::*;
    use tablepro_core::{ColumnInfo, Value};
    use uuid::Uuid;

    use super::super::LayoutBinding;
    use super::super::test_grid::{Grid, GridSpec, WAIT, named, persisted};
    use super::{ColumnChooser, open};
    use crate::persistence::ColumnLayoutStore;
    use crate::services::grid::ColumnLayout;
    use crate::test_support::{assert_labelled, descendants, drain_main_context, wait_until};

    fn columns() -> Vec<ColumnInfo> {
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("email", "varchar(80)", false),
        ]
    }

    fn rows() -> Vec<Vec<Value>> {
        vec![
            vec![
                Value::Int(1),
                Value::Text("Ada".into()),
                Value::Text("ada@example.com".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("Grace".into()),
                Value::Text("grace@example.com".into()),
            ],
        ]
    }

    fn row_labels(check: &gtk4::CheckButton) -> Option<(String, String)> {
        let labels = check.child()?;
        let name = labels.first_child().and_downcast::<gtk4::Label>()?;
        let kind = labels.last_child().and_downcast::<gtk4::Label>()?;
        Some((name.label().to_string(), kind.label().to_string()))
    }

    /// The drawn check of the column named `name`.
    fn check(chooser: &ColumnChooser, name: &str) -> gtk4::CheckButton {
        descendants(chooser)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::CheckButton>().ok())
            .find(|check| row_labels(check).is_some_and(|(shown, _)| shown == name))
            .unwrap_or_else(|| panic!("no check for {name}"))
    }

    /// The columns the chooser lists, by data column, in its order.
    fn listed(chooser: &ColumnChooser, grid: &Grid) -> Vec<usize> {
        let model = chooser.imp().list_view.model().expect("a model");
        (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<gtk4::ColumnViewColumn>())
            .filter_map(|column| grid.grid.column_index(&column))
            .collect()
    }

    fn opened(grid: &Grid) -> ColumnChooser {
        let chooser = open(&grid.grid);
        wait_until(WAIT, || {
            descendants(&chooser)
                .into_iter()
                .filter(|widget| widget.is::<gtk4::CheckButton>())
                .count()
                == 3
        })
        .expect("a check per column");
        chooser
    }

    #[gtk4::test]
    fn a_check_hides_and_shows_its_column_and_the_last_one_stays() {
        adw::init().expect("libadwaita initialises under the test backend");
        let grid = Grid::open(columns(), rows());
        let chooser = opened(&grid);
        let email = check(&chooser, "email");
        assert_eq!(row_labels(&email).map(|(_, kind)| kind).as_deref(), Some("varchar(80)"));
        assert_eq!(assert_labelled(&email), Ok(()));
        assert!(gtk4::test_accessible_has_property(
            &email,
            gtk4::AccessibleProperty::Description
        ));

        check(&chooser, "name").set_active(false);
        assert_eq!(grid.grid.shown_columns(), [0, 2]);
        assert!(chooser.imp().show_all_button.is_sensitive());
        check(&chooser, "name").set_active(true);
        assert_eq!(grid.grid.shown_columns(), [0, 1, 2]);
        assert!(!chooser.imp().show_all_button.is_sensitive());

        check(&chooser, "id").set_active(false);
        check(&chooser, "email").set_active(false);
        check(&chooser, "name").set_active(false);
        assert_eq!(grid.grid.shown_columns(), [1], "the last column stays on screen");
        assert!(check(&chooser, "name").is_active(), "its check goes back");

        chooser.imp().show_all_button.emit_clicked();
        assert_eq!(grid.grid.shown_columns(), [0, 1, 2]);
        assert!(check(&chooser, "id").is_active() && check(&chooser, "email").is_active());
        chooser.close();
        drain_main_context();
    }

    #[gtk4::test]
    fn reset_puts_every_column_back_and_forgets_the_saved_layout() {
        adw::init().expect("libadwaita initialises under the test backend");
        let root = tempfile::tempdir().expect("tempdir");
        let runtime = crate::test_support::test_runtime();
        let store = ColumnLayoutStore::load(root.path().join("column_widths.json"), &runtime.tasks());
        let connection_id = Uuid::new_v4();
        let saved = || store.layout(connection_id, Some("public"), "users");
        let spec = GridSpec {
            layout: Some(LayoutBinding {
                store: store.clone(),
                connection_id,
                schema: Some("public".to_owned()),
                table: "users".to_owned(),
            }),
            ..GridSpec::table(columns())
        };
        let grid = Grid::build(spec, persisted(&rows()));
        let email = grid.grid.data_view_column(2).expect("the email column");
        grid.grid.column_view().insert_column(1, &email);
        grid.grid
            .data_view_column(1)
            .expect("the name column")
            .set_fixed_width(321);
        grid.grid.set_column_visible(0, false);
        drain_main_context();
        assert_eq!(grid.grid.shown_columns(), [2, 1]);
        assert!(
            saved().hidden.contains("id") && saved().widths.get("name") == Some(&321),
            "{:?}",
            saved()
        );
        let chooser = opened(&grid);
        assert_eq!(listed(&chooser, &grid), [2, 0, 1], "listed as on screen");

        chooser.imp().reset_button.emit_clicked();
        drain_main_context();

        assert_eq!(grid.grid.shown_columns(), [0, 1, 2]);
        assert_ne!(
            grid.grid.data_view_column(1).map(|column| column.fixed_width()),
            Some(321)
        );
        assert_eq!(saved(), ColumnLayout::default());
        assert_eq!(listed(&chooser, &grid), [0, 1, 2]);
        wait_until(WAIT, || check(&chooser, "id").is_active()).expect("the id column is checked again");
        chooser.close();
        drain_main_context();
    }

    #[gtk4::test]
    fn the_search_narrows_the_list_and_escape_clears_it_before_closing() {
        adw::init().expect("libadwaita initialises under the test backend");
        let grid = Grid::open(columns(), rows());
        let chooser = opened(&grid);
        let closed = Rc::new(Cell::new(false));
        let flag = closed.clone();
        chooser.connect_closed(move |_| flag.set(true));
        let imp = chooser.imp();

        imp.search_entry.set_text("MAI");
        wait_until(WAIT, || listed(&chooser, &grid) == [2]).expect("only email is listed");
        imp.search_entry.set_text("zzz");
        wait_until(WAIT, || imp.stack.visible_child_name().as_deref() == Some("empty")).expect("No Matches");

        imp.search_entry.emit_by_name::<()>("stop-search", &[]);
        assert!(imp.search_entry.text().is_empty() && !closed.get());
        assert_eq!(imp.stack.visible_child_name().as_deref(), Some("list"));
        assert_eq!(listed(&chooser, &grid), [0, 1, 2]);
        imp.search_entry.emit_by_name::<()>("stop-search", &[]);
        wait_until(WAIT, || closed.get()).expect("a second Escape closes the dialog");
    }
}
