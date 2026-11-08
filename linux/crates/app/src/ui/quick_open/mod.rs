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

/// What the user chose, and whether they asked for its structure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Pick {
    pub table: TableRef,
    pub structure: bool,
}

type Chosen = Rc<dyn Fn(Pick)>;

/// The tables and views of `objects`, by name.
pub(crate) fn candidates(objects: &[ObjectInfo]) -> Vec<ObjectInfo> {
    let mut found: Vec<ObjectInfo> = objects
        .iter()
        .filter(|object| object.kind.is_browsable())
        .cloned()
        .collect();
    found.sort_by_cached_key(|object| (object.name.to_lowercase(), object.schema.clone()));
    found
}

/// The candidates `typed` finds, the best first, at most `LISTED`.
pub(crate) fn search(candidates: &[ObjectInfo], typed: &str) -> Vec<ObjectInfo> {
    let mut ranked: Vec<(u32, &ObjectInfo)> = candidates
        .iter()
        .filter_map(|object| matching::rank(typed, &object.name).map(|rank| (rank, object)))
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

    use gtk4::glib;
    use gtk4::subclass::prelude::*;
    use libadwaita as adw;
    use libadwaita::subclass::prelude::*;
    use tablepro_core::meta::ObjectInfo;

    #[derive(Default)]
    pub struct QuickOpen {
        pub candidates: RefCell<Vec<ObjectInfo>>,
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
    pub(crate) fn new(objects: &[ObjectInfo], chosen: impl Fn(Pick) + 'static) -> Self {
        let dialog: Self = glib::Object::new();
        dialog.set_title(&gettext("Open Quickly"));
        dialog.set_content_width(520);
        dialog.set_content_height(440);
        let all = candidates(objects);
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let selection = gtk::SingleSelection::new(Some(store.clone()));
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory()));
        list.add_css_class("navigation-sidebar");
        list.set_single_click_activate(true);
        list.update_property(&[gtk::accessible::Property::Label(&gettext("Tables and views"))]);
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();
        let empty = adw::StatusPage::builder()
            .title(gettext("No Matches"))
            .description(gettext("No table or view matches what you typed."))
            .build();
        empty.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.add_named(&scrolled, Some("list"));
        stack.add_named(&empty, Some("empty"));
        let entry = gtk::SearchEntry::builder()
            .placeholder_text(gettext("Search tables and views"))
            .hexpand(true)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(&gettext("Search tables and views"))]);
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
                let Some(object) = store
                    .item(position)
                    .and_downcast::<glib::BoxedAnyObject>()
                    .map(|item| item.borrow::<ObjectInfo>().clone())
                else {
                    return;
                };
                if let Some(dialog) = dialog_weak.upgrade() {
                    dialog.close();
                }
                chosen(Pick {
                    table: TableRef::new(object.schema, object.name),
                    structure,
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
            .map(|object| object.name.clone())
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
        let object = object.borrow::<ObjectInfo>().clone();
        let (Some(icon), Some(name), Some(place)) = (
            row.first_child().and_downcast::<gtk::Image>(),
            row.first_child()
                .and_then(|icon| icon.next_sibling())
                .and_downcast::<gtk::Label>(),
            row.last_child().and_downcast::<gtk::Label>(),
        ) else {
            return;
        };
        icon.set_icon_name(Some(match object.kind {
            ObjectKind::View | ObjectKind::MaterializedView => icons::VIEW_GRID,
            _ => icons::TABLE_RELATION,
        }));
        name.set_label(&object.name);
        place.set_label(object.schema.as_deref().unwrap_or_default());
        let described = match object.schema.as_deref() {
            Some(schema) => gettext_f("{table}, in {schema}", &[("table", &object.name), ("schema", schema)]),
            None => object.name.clone(),
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

    fn names(found: &[ObjectInfo]) -> Vec<&str> {
        found.iter().map(|object| object.name.as_str()).collect()
    }

    #[test]
    fn only_what_the_grid_can_page_is_offered_and_it_is_ordered_by_name() {
        let all = candidates(&[
            table("public", "orders", ObjectKind::Table),
            table("public", "recount", ObjectKind::Function),
            table("public", "Customers", ObjectKind::View),
            table("public", "customers_id_seq", ObjectKind::Sequence),
        ]);

        assert_eq!(names(&all), ["Customers", "orders"]);
    }

    #[test]
    fn the_best_match_comes_first_and_a_miss_is_left_out() {
        let all = candidates(&[
            table("public", "reorder_log", ObjectKind::Table),
            table("public", "orders", ObjectKind::Table),
            table("sales", "order_items", ObjectKind::Table),
            table("public", "users", ObjectKind::Table),
        ]);

        assert_eq!(names(&search(&all, "ord")), ["order_items", "orders", "reorder_log"]);
        assert!(search(&all, "zzz").is_empty());
        assert_eq!(search(&all, "").len(), 4);
    }

    #[gtk4::test]
    fn the_dialog_searches_the_tables_it_was_given() {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        let dialog = QuickOpen::new(&[table("public", "orders", ObjectKind::Table)], |_| {});

        assert_eq!(dialog.candidate_names(), ["orders"]);
    }
}
