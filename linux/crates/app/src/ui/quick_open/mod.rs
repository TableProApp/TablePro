//! Open Quickly: a search over the front connection's tables and views,
//! as the macOS Quick Switcher (`QuickSwitcherPanelView`) offers, so a
//! table is one key and a few letters away instead of a scroll through
//! the sidebar. Enter opens it and Ctrl+Enter opens its structure.

mod matching;

use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};

use crate::i18n::{gettext, gettext_f};
use crate::ui::icons;

/// The rows listed at once, which a longer search narrows.
const LISTED: usize = 200;

/// What the user chose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Pick {
    /// A table or view, and whether they asked for its structure.
    Table { table: TableRef, structure: bool },
    /// A saved query's SQL, which opens in a new query tab.
    Query(String),
}

/// What the dialog searches: a table or view, or a saved query.
#[derive(Debug, Clone)]
pub(crate) enum Entry {
    Object(ObjectInfo),
    Query { name: String, sql: String },
}

impl Entry {
    pub(crate) fn name(&self) -> &str {
        match self {
            Entry::Object(object) => &object.name,
            Entry::Query { name, .. } => name,
        }
    }
}

type Chosen = Rc<dyn Fn(Pick)>;

/// The tables and views of `objects` and the saved `queries` as (name, SQL),
/// by name, a table before a query of the same name.
pub(crate) fn candidates(objects: &[ObjectInfo], queries: &[(String, String)]) -> Vec<Entry> {
    let mut found: Vec<Entry> = objects
        .iter()
        .filter(|object| object.kind.is_browsable())
        .cloned()
        .map(Entry::Object)
        .chain(queries.iter().map(|(name, sql)| Entry::Query {
            name: name.clone(),
            sql: sql.clone(),
        }))
        .collect();
    found.sort_by_cached_key(|entry| {
        (
            entry.name().to_lowercase(),
            matches!(entry, Entry::Query { .. }),
            match entry {
                Entry::Object(object) => object.schema.clone(),
                Entry::Query { .. } => None,
            },
        )
    });
    found
}

/// The candidates `typed` finds, the best first, at most `LISTED`.
pub(crate) fn search(candidates: &[Entry], typed: &str) -> Vec<Entry> {
    let mut ranked: Vec<(u32, &Entry)> = candidates
        .iter()
        .filter_map(|entry| matching::rank(typed, entry.name()).map(|rank| (rank, entry)))
        .collect();
    // Stable, so equals keep the by-name order the candidates came in.
    ranked.sort_by_key(|(rank, _)| *rank);
    ranked
        .into_iter()
        .take(LISTED)
        .map(|(_, object)| object.clone())
        .collect()
}

glib::wrapper! {
    pub struct QuickOpen(ObjectSubclass<imp::QuickOpen>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

mod imp {
    use std::cell::RefCell;

    use super::Entry;
    use gtk4::glib;
    use gtk4::subclass::prelude::*;
    use libadwaita as adw;
    use libadwaita::subclass::prelude::*;

    #[derive(Default)]
    pub struct QuickOpen {
        pub(super) candidates: RefCell<Vec<Entry>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for QuickOpen {
        const NAME: &'static str = "TableProQuickOpen";
        type Type = super::QuickOpen;
        type ParentType = adw::Dialog;
    }

    impl ObjectImpl for QuickOpen {}
    impl WidgetImpl for QuickOpen {}
    impl AdwDialogImpl for QuickOpen {}
}

impl QuickOpen {
    pub(crate) fn new(objects: &[ObjectInfo], queries: &[(String, String)], chosen: impl Fn(Pick) + 'static) -> Self {
        let dialog: Self = glib::Object::new();
        dialog.set_title(&gettext("Open Quickly"));
        dialog.set_content_width(520);
        dialog.set_content_height(440);
        let all = candidates(objects, queries);
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let selection = gtk::SingleSelection::new(Some(store.clone()));
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext(
            "Tables, views and saved queries",
        ))]);
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();
        let empty = adw::StatusPage::builder()
            .title(gettext("No Matches"))
            .description(gettext("No table, view or saved query matches what you typed."))
            .build();
        empty.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.add_named(&scrolled, Some("list"));
        stack.add_named(&empty, Some("empty"));
        let entry = gtk::SearchEntry::builder()
            .placeholder_text(gettext("Search tables, views and saved queries"))
            .hexpand(true)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(&gettext(
            "Search tables, views and saved queries",
        ))]);
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        body.append(&entry);
        body.append(&stack);
        let header = adw::HeaderBar::new();
        let view = adw::ToolbarView::new();
        view.add_top_bar(&header);
        view.set_content(Some(&body));
        dialog.set_child(Some(&view));
        dialog.set_focus(Some(&entry));
        dialog.imp().candidates.replace(all.clone());

        let show = {
            let (store, stack, selection) = (store.clone(), stack.clone(), selection.clone());
            move |typed: &str| {
                let found = search(&all, typed);
                let items: Vec<glib::BoxedAnyObject> = found.into_iter().map(glib::BoxedAnyObject::new).collect();
                store.splice(0, store.n_items(), &items);
                stack.set_visible_child_name(if items.is_empty() { "empty" } else { "list" });
                selection.set_selected(if items.is_empty() {
                    gtk::INVALID_LIST_POSITION
                } else {
                    0
                });
            }
        };
        show("");
        entry.connect_search_changed({
            let show = show.clone();
            move |entry| show(&entry.text())
        });

        let chosen: Chosen = Rc::new(chosen);
        let dialog_weak = dialog.downgrade();
        let pick = {
            let (store, chosen) = (store.clone(), chosen.clone());
            move |position: u32, structure: bool| {
                let Some(found) = store
                    .item(position)
                    .and_downcast::<glib::BoxedAnyObject>()
                    .map(|item| item.borrow::<Entry>().clone())
                else {
                    return;
                };
                if let Some(dialog) = dialog_weak.upgrade() {
                    dialog.close();
                }
                chosen(match found {
                    Entry::Object(object) => Pick::Table {
                        table: TableRef::new(object.schema, object.name),
                        structure,
                    },
                    Entry::Query { sql, .. } => Pick::Query(sql),
                });
            }
        };
        list.connect_activate({
            let pick = pick.clone();
            move |_, position| pick(position, false)
        });
        entry.connect_activate({
            let (pick, selection) = (pick.clone(), selection.clone());
            move |_| pick(selection.selected(), false)
        });
        // Up and Down move the choice while the text keeps the keyboard.
        entry.connect_next_match({
            let selection = selection.clone();
            move |_| step(&selection, 1)
        });
        entry.connect_previous_match({
            let selection = selection.clone();
            move |_| step(&selection, -1)
        });
        let keys = gtk::EventControllerKey::new();
        let held: Rc<RefCell<()>> = Rc::default();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let _ = &held;
            if matches!(key, gdk::Key::Return | gdk::Key::KP_Enter)
                && modifiers.contains(gdk::ModifierType::CONTROL_MASK)
            {
                pick(selection.selected(), true);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        entry.add_controller(keys);
        dialog
    }

    /// The tables and views the dialog searches.
    #[cfg(test)]
    pub(crate) fn candidate_names(&self) -> Vec<String> {
        use gtk4::subclass::prelude::ObjectSubclassIsExt;
        self.imp()
            .candidates
            .borrow()
            .iter()
            .map(|entry| entry.name().to_owned())
            .collect()
    }
}

fn step(selection: &gtk::SingleSelection, by: i32) {
    let count = selection.n_items();
    if count == 0 {
        return;
    }
    let current = i64::from(selection.selected().min(count - 1));
    let next = (current + i64::from(by)).clamp(0, i64::from(count) - 1);
    selection.set_selected(u32::try_from(next).unwrap_or(0));
}

fn factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let icon = gtk::Image::new();
        icon.add_css_class("dimmed");
        icon.set_accessible_role(gtk::AccessibleRole::Presentation);
        let name = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let place = gtk::Label::builder()
            .xalign(1.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        place.add_css_class("dimmed");
        place.add_css_class("caption");
        let row = gtk::Box::builder()
            .spacing(10)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(6)
            .margin_end(6)
            .build();
        row.append(&icon);
        row.append(&name);
        row.append(&place);
        item.set_child(Some(&row));
    });
    factory.connect_bind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(object), Some(row)) = (item.item().and_downcast::<glib::BoxedAnyObject>(), item.child()) else {
            return;
        };
        let entry = object.borrow::<Entry>().clone();
        let (Some(icon), Some(name), Some(place)) = (
            row.first_child().and_downcast::<gtk::Image>(),
            row.first_child()
                .and_then(|icon| icon.next_sibling())
                .and_downcast::<gtk::Label>(),
            row.last_child().and_downcast::<gtk::Label>(),
        ) else {
            return;
        };
        let described = match &entry {
            Entry::Object(object) => {
                icon.set_icon_name(Some(match object.kind {
                    ObjectKind::View | ObjectKind::MaterializedView => icons::VIEW_GRID,
                    _ => icons::TABLE_RELATION,
                }));
                name.set_label(&object.name);
                place.set_label(object.schema.as_deref().unwrap_or_default());
                match object.schema.as_deref() {
                    Some(schema) => gettext_f("{table}, in {schema}", &[("table", &object.name), ("schema", schema)]),
                    None => object.name.clone(),
                }
            }
            Entry::Query { name: title, .. } => {
                icon.set_icon_name(Some("text-x-generic-symbolic"));
                name.set_label(title);
                place.set_label(&gettext("Saved query"));
                gettext_f("{name}, a saved query", &[("name", title)])
            }
        };
        item.set_accessible_label(&described);
    });
    factory
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(schema: &str, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo::new(Some(schema.to_owned()), name, kind)
    }

    fn names(found: &[Entry]) -> Vec<&str> {
        found.iter().map(Entry::name).collect()
    }

    #[test]
    fn only_what_the_grid_can_page_is_offered_and_it_is_ordered_by_name() {
        let all = candidates(
            &[
                table("public", "orders", ObjectKind::Table),
                table("public", "recount", ObjectKind::Function),
                table("public", "Customers", ObjectKind::View),
                table("public", "customers_id_seq", ObjectKind::Sequence),
            ],
            &[],
        );

        assert_eq!(names(&all), ["Customers", "orders"]);
    }

    #[test]
    fn the_best_match_comes_first_and_a_miss_is_left_out() {
        let all = candidates(
            &[
                table("public", "reorder_log", ObjectKind::Table),
                table("public", "orders", ObjectKind::Table),
                table("sales", "order_items", ObjectKind::Table),
                table("public", "users", ObjectKind::Table),
            ],
            &[],
        );

        assert_eq!(names(&search(&all, "ord")), ["order_items", "orders", "reorder_log"]);
        assert!(search(&all, "zzz").is_empty());
        assert_eq!(search(&all, "").len(), 4);
    }

    #[test]
    fn a_saved_query_is_found_by_its_name_beside_the_tables() {
        let all = candidates(
            &[table("public", "orders", ObjectKind::Table)],
            &[
                ("Orders this week".to_owned(), "SELECT 1".to_owned()),
                ("Monthly report".to_owned(), "SELECT 2".to_owned()),
            ],
        );

        assert_eq!(names(&search(&all, "orders")), ["orders", "Orders this week"]);
        assert_eq!(names(&search(&all, "month")), ["Monthly report"]);
    }

    #[gtk4::test]
    fn the_dialog_searches_the_tables_it_was_given() {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        let dialog = QuickOpen::new(&[table("public", "orders", ObjectKind::Table)], &[], |_| {});

        assert_eq!(dialog.candidate_names(), ["orders"]);
    }
}
