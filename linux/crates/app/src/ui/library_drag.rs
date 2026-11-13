use std::cell::Cell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib};

use crate::services::library_outline::{DropSpot, LibraryItem, LibraryMove, LibraryOutline, LibrarySection};

const CHANGE_LIBRARY: &str = "picker.change-library";
const DRAGGING: &str = "tp-dragging";
const DROP_BEFORE: &str = "tp-drop-before";
const DROP_AFTER: &str = "tp-drop-after";

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct LibraryDragItem {
        pub(super) dragged: Cell<Option<(LibrarySection, LibraryItem)>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for LibraryDragItem {
        const NAME: &'static str = "TableProLibraryDragItem";
        type Type = super::LibraryDragItem;
    }

    impl ObjectImpl for LibraryDragItem {}
}

glib::wrapper! {
    pub struct LibraryDragItem(ObjectSubclass<imp::LibraryDragItem>);
}

impl LibraryDragItem {
    pub(crate) fn new(dragged: (LibrarySection, LibraryItem)) -> Self {
        let item: Self = glib::Object::new();
        item.imp().dragged.set(Some(dragged));
        item
    }

    pub(crate) fn dragged(&self) -> Option<(LibrarySection, LibraryItem)> {
        self.imp().dragged.get()
    }
}

pub(crate) fn drag_source(
    widget: &impl IsA<gtk::Widget>,
    payload: impl Fn() -> Option<(LibrarySection, LibraryItem)> + 'static,
) -> gtk::DragSource {
    let source = gtk::DragSource::new();
    source.set_actions(gdk::DragAction::MOVE);
    let pressed = Rc::new(Cell::new((0.0, 0.0)));
    let press = pressed.clone();
    source.connect_prepare(move |_, x, y| {
        let item = LibraryDragItem::new(payload()?);
        press.set((x, y));
        Some(gdk::ContentProvider::for_value(&item.to_value()))
    });
    source.connect_drag_begin(move |source, _| {
        let Some(widget) = source.widget() else {
            return;
        };
        // A still image taken before the fade: the row can be recycled while the list scrolls.
        let icon = gtk::WidgetPaintable::new(Some(&widget)).current_image();
        let (x, y) = pressed.get();
        source.set_icon(Some(&icon), x as i32, y as i32);
        widget.add_css_class(DRAGGING);
        cancel_row_click(&widget);
    });
    source.connect_drag_end(|source, _, _| unfade(source));
    source.connect_drag_cancel(|source, _, _| {
        unfade(source);
        false
    });
    widget.add_controller(source.clone());
    source
}

fn unfade(source: &gtk::DragSource) {
    if let Some(widget) = source.widget() {
        widget.remove_css_class(DRAGGING);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ZoneKind {
    Group,
    Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Zone {
    Before,
    Into,
    After,
}

pub(crate) fn zone(kind: ZoneKind, y: f64, height: f64) -> Zone {
    match kind {
        ZoneKind::Group if y < height * 0.25 => Zone::Before,
        ZoneKind::Group if y < height * 0.75 => Zone::Into,
        ZoneKind::Connection if y < height * 0.5 => Zone::Before,
        ZoneKind::Group | ZoneKind::Connection => Zone::After,
    }
}

type Spot = Box<dyn Fn(f64, f64) -> Option<(DropSpot, bool)>>;

struct Drops {
    spot: Spot,
    outline: Box<dyn Fn() -> Rc<LibraryOutline>>,
}

impl Drops {
    fn resolve(
        &self,
        dragged: (LibrarySection, LibraryItem),
        widget: &gtk::Widget,
        y: f64,
    ) -> Option<(DropSpot, LibraryMove)> {
        let (spot, expanded) = (self.spot)(y, f64::from(widget.height()))?;
        let change = (self.outline)().resolve_drop(dragged, spot, expanded)?;
        Some((spot, change))
    }

    fn hover(&self, target: &gtk::DropTarget, y: f64) -> gdk::DragAction {
        let Some(widget) = target.widget() else {
            return gdk::DragAction::empty();
        };
        let spot = dragged_in(target)
            .and_then(|dragged| self.resolve(dragged, &widget, y))
            .map(|(spot, _)| spot);
        show_line(&widget, spot);
        if spot.is_some() {
            gdk::DragAction::MOVE
        } else {
            gdk::DragAction::empty()
        }
    }
}

pub(crate) fn drop_target(
    widget: &impl IsA<gtk::Widget>,
    spot: impl Fn(f64, f64) -> Option<(DropSpot, bool)> + 'static,
    outline: impl Fn() -> Rc<LibraryOutline> + 'static,
) -> gtk::DropTarget {
    let target = gtk::DropTarget::new(LibraryDragItem::static_type(), gdk::DragAction::MOVE);
    let drops = Rc::new(Drops {
        spot: Box::new(spot),
        outline: Box::new(outline),
    });
    let hovering = drops.clone();
    let hover = move |target: &gtk::DropTarget, _: f64, y: f64| hovering.hover(target, y);
    target.connect_enter(hover.clone());
    target.connect_motion(hover);
    target.connect_leave(|target| {
        if let Some(widget) = target.widget() {
            show_line(&widget, None);
        }
    });
    target.connect_drop(move |target, value, _, y| {
        let Some(widget) = target.widget() else {
            return false;
        };
        // GTK ends a drop without emitting leave.
        show_line(&widget, None);
        let Some(dragged) = value.get::<LibraryDragItem>().ok().and_then(|item| item.dragged()) else {
            return false;
        };
        drops
            .resolve(dragged, &widget, y)
            .is_some_and(|(_, change)| apply(&widget, &change))
    });
    widget.add_controller(target.clone());
    target
}

// A local drag hands over its value at once, so a row can refuse before the drop.
fn dragged_in(target: &gtk::DropTarget) -> Option<(LibrarySection, LibraryItem)> {
    let drag = target.current_drop()?.drag()?;
    let value = drag.content().value(LibraryDragItem::static_type()).ok()?;
    value.get::<LibraryDragItem>().ok()?.dragged()
}

fn show_line(widget: &gtk::Widget, spot: Option<DropSpot>) {
    // Into and End keep libadwaita's :drop(active) ring.
    let (before, after) = match spot {
        Some(DropSpot::Before(..)) => (true, false),
        Some(DropSpot::After(..)) => (false, true),
        Some(DropSpot::Into(_) | DropSpot::End(_)) | None => (false, false),
    };
    for (class, shown) in [(DROP_BEFORE, before), (DROP_AFTER, after)] {
        if shown {
            widget.add_css_class(class);
        } else {
            widget.remove_css_class(class);
        }
    }
}

fn apply(widget: &gtk::Widget, change: &LibraryMove) -> bool {
    match widget.activate_action(CHANGE_LIBRARY, Some(&change.to_variant())) {
        Ok(()) => true,
        Err(error) => {
            tracing::warn!(%error, "a library drop reached no picker");
            false
        }
    }
}

// GTK resets only the drag source's own widget, and the list row's click would still activate it on the release.
fn cancel_row_click(widget: &gtk::Widget) {
    let Some(row) = widget.parent() else {
        return;
    };
    let controllers = row.observe_controllers();
    let clicks = (0..controllers.n_items()).filter_map(|at| controllers.item(at).and_downcast::<gtk::GestureClick>());
    for click in clicks {
        click.reset();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use gtk4::gio;
    use tablepro_storage::{ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionTag, SavedConnection};
    use uuid::Uuid;

    use super::*;

    struct Library {
        outline: Rc<LibraryOutline>,
        group: Uuid,
        connection: Uuid,
    }

    fn library() -> Library {
        let group = ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a group name"), None);
        let saved = SavedConnection {
            id: Uuid::new_v4(),
            name: "Shop".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            query_timeout_secs: None,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        };
        let (group_id, connection) = (group.id, saved.id);
        let tags: Vec<ConnectionTag> = Vec::new();
        let list = ConnectionList::new(vec![saved], tags).with_groups(vec![group]);
        Library {
            outline: Rc::new(LibraryOutline::new(&list)),
            group: group_id,
            connection,
        }
    }

    struct Picker {
        _parent: gtk::Box,
        row: gtk::Box,
        seen: Rc<RefCell<Vec<glib::Variant>>>,
    }

    fn picker() -> Picker {
        let parent = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        parent.append(&row);
        let shape = LibraryMove::Favourites {
            ids: Vec::new(),
            before: None,
        }
        .to_variant();
        let change = gio::SimpleAction::new("change-library", Some(shape.type_()));
        let seen: Rc<RefCell<Vec<glib::Variant>>> = Rc::default();
        let log = seen.clone();
        change.connect_activate(move |_, value| log.borrow_mut().extend(value.cloned()));
        let actions = gio::SimpleActionGroup::new();
        actions.add_action(&change);
        parent.insert_action_group("picker", Some(&actions));
        Picker {
            _parent: parent,
            row,
            seen,
        }
    }

    fn drop_on(target: &gtk::DropTarget, dragged: (LibrarySection, LibraryItem)) -> bool {
        let value = LibraryDragItem::new(dragged).to_value();
        target.emit_by_name::<bool>("drop", &[&glib::BoxedValue(value), &0.0_f64, &0.0_f64])
    }

    #[test]
    fn a_group_row_splits_a_quarter_before_half_into_a_quarter_after() {
        let at = |y| zone(ZoneKind::Group, y, 100.0);

        assert_eq!(at(0.0), Zone::Before);
        assert_eq!(at(24.9), Zone::Before);
        assert_eq!(at(25.0), Zone::Into);
        assert_eq!(at(74.9), Zone::Into);
        assert_eq!(at(75.0), Zone::After);
        assert_eq!(at(100.0), Zone::After);
    }

    #[test]
    fn a_connection_row_splits_in_half_before_and_after() {
        let at = |y| zone(ZoneKind::Connection, y, 100.0);

        assert_eq!(at(0.0), Zone::Before);
        assert_eq!(at(49.9), Zone::Before);
        assert_eq!(at(50.0), Zone::After);
        assert_eq!(at(100.0), Zone::After);
    }

    #[gtk4::test]
    fn a_drag_source_offers_its_payload_and_starts_nothing_without_one() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let dragged = (LibrarySection::Favourites, LibraryItem::Connection(Uuid::new_v4()));
        let offered = Rc::new(Cell::new(Some(dragged)));
        let payload = offered.clone();
        let source = drag_source(&row, move || payload.get());

        let content = source.emit_by_name::<Option<gdk::ContentProvider>>("prepare", &[&4.0_f64, &2.0_f64]);
        let carried = content
            .and_then(|content| content.value(LibraryDragItem::static_type()).ok())
            .and_then(|value| value.get::<LibraryDragItem>().ok())
            .and_then(|item| item.dragged());
        assert_eq!(carried, Some(dragged));

        offered.set(None);
        let content = source.emit_by_name::<Option<gdk::ContentProvider>>("prepare", &[&4.0_f64, &2.0_f64]);
        assert!(content.is_none(), "a row with nothing to drag started a drag");
    }

    #[gtk4::test]
    fn a_drop_activates_change_library_with_the_resolved_move() {
        let library = library();
        let picker = picker();
        let group = library.group;
        let outline = library.outline.clone();
        let target = drop_target(
            &picker.row,
            move |_, _| Some((DropSpot::Into(group), false)),
            move || outline.clone(),
        );
        picker.row.add_css_class(DROP_BEFORE);
        picker.row.add_css_class(DROP_AFTER);

        let dropped = drop_on(
            &target,
            (LibrarySection::Tree, LibraryItem::Connection(library.connection)),
        );

        assert!(dropped);
        let expected = LibraryMove::Connections {
            ids: vec![library.connection],
            group: Some(library.group),
            before: None,
        };
        let seen: Vec<Option<LibraryMove>> = picker.seen.borrow().iter().map(LibraryMove::from_variant).collect();
        assert_eq!(seen, [Some(expected)]);
        assert!(
            !picker.row.has_css_class(DROP_BEFORE) && !picker.row.has_css_class(DROP_AFTER),
            "the drop left a line on the row"
        );
    }

    #[gtk4::test]
    fn a_drop_the_outline_refuses_activates_nothing() {
        let library = library();
        let picker = picker();
        let group = library.group;
        let outline = library.outline.clone();
        let target = drop_target(
            &picker.row,
            move |_, _| Some((DropSpot::Into(group), false)),
            move || outline.clone(),
        );

        let dropped = drop_on(&target, (LibrarySection::Tree, LibraryItem::Group(group)));

        assert!(!dropped, "a group dropped into itself was taken");
        assert!(picker.seen.borrow().is_empty());
    }

    #[gtk4::test]
    fn a_drop_off_every_spot_activates_nothing() {
        let library = library();
        let picker = picker();
        let outline = library.outline.clone();
        let target = drop_target(&picker.row, |_, _| None, move || outline.clone());

        let dropped = drop_on(
            &target,
            (LibrarySection::Tree, LibraryItem::Connection(library.connection)),
        );

        assert!(!dropped);
        assert!(picker.seen.borrow().is_empty());
    }

    #[gtk4::test]
    fn the_line_marks_only_the_edge_the_spot_names() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let item = LibraryItem::Connection(Uuid::new_v4());
        let (tree, favourites) = (LibrarySection::Tree, LibrarySection::Favourites);
        let lines = |spot| {
            show_line(row.upcast_ref(), spot);
            (row.has_css_class(DROP_BEFORE), row.has_css_class(DROP_AFTER))
        };

        assert_eq!(lines(Some(DropSpot::Before(tree, item))), (true, false));
        assert_eq!(lines(Some(DropSpot::After(tree, item))), (false, true));
        assert_eq!(lines(Some(DropSpot::Into(Uuid::new_v4()))), (false, false));
        assert_eq!(lines(Some(DropSpot::After(favourites, item))), (false, true));
        assert_eq!(lines(Some(DropSpot::End(tree))), (false, false));
        assert_eq!(lines(None), (false, false));
    }
}
