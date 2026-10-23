use std::rc::Weak;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, graphene, pango};

use super::sidebar_object::SidebarObject;
use super::sidebar_view::SidebarInner;

/// Builds the rows the list view recycles: an icon and the table's name,
/// with one click gesture for what activation does not cover.
pub(super) fn row_factory(view: Weak<SidebarInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .has_tooltip(true)
            .build();
        // Asked for on hover: setting a tooltip queries the pointer's
        // position, and a search binds two hundred rows at once.
        let hovered = item.downgrade();
        row.connect_query_tooltip(move |_, _, _, _, tooltip| {
            let Some(object) = hovered
                .upgrade()
                .and_then(|item| item.item())
                .and_downcast::<SidebarObject>()
            else {
                return false;
            };
            tooltip.set_text(Some(&object.qualified_name()));
            true
        });
        // The name says what the row is; the icon only tells a view from
        // a table at a glance.
        let icon = gtk::Image::builder()
            .pixel_size(16)
            .accessible_role(gtk::AccessibleRole::Presentation)
            .build();
        let label = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        // A key's type, as a dim suffix: its icon alone would leave the
        // user to learn which picture means a sorted set.
        let kind = gtk::Label::builder()
            .visible(false)
            .accessible_role(gtk::AccessibleRole::Presentation)
            .build();
        kind.add_css_class("dimmed");
        kind.add_css_class("caption");
        row.append(&icon);
        row.append(&label);
        row.append(&kind);
        row.add_controller(click_gesture(view.clone(), item));
        item.set_child(Some(&row));
        if let Some(view) = view.upgrade() {
            view.track_row(item);
        }
    });
    factory.connect_bind(|_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(row), Some(object)) = (item.child(), item.item().and_downcast::<SidebarObject>()) else {
            return;
        };
        // A recycled row usually shows a table again, and setting the
        // same icon or description still redraws or re-announces it.
        let icon_name = object.icon_name();
        if let Some(icon) = row.first_child().and_downcast::<gtk::Image>()
            && icon.icon_name().as_deref() != Some(icon_name.as_str())
        {
            icon.set_icon_name(Some(&icon_name));
        }
        if let Some(label) = row
            .first_child()
            .and_then(|icon| icon.next_sibling())
            .and_downcast::<gtk::Label>()
        {
            label.set_label(&object.name());
        }
        if let Some(kind) = row.last_child().and_downcast::<gtk::Label>() {
            let shown = object.type_label();
            kind.set_visible(shown.is_some());
            kind.set_label(shown.as_deref().unwrap_or_default());
        }
        // The getter's binding cannot read an unset description, which a
        // new row has; the property can.
        let kind = object.kind_name();
        if item.property::<Option<String>>("accessible-description").as_deref() != Some(kind.as_str()) {
            item.set_accessible_description(&kind);
        }
    });
    factory
}

/// Button 0, so one gesture sees every button. It claims only what it
/// handles, which cancels the row's own click for that press.
fn click_gesture(view: Weak<SidebarInner>, item: &gtk::ListItem) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(0);
    let (pressed_view, pressed_item) = (view.clone(), item.downgrade());
    gesture.connect_pressed(move |gesture, _, x, y| {
        let (Some(view), Some(item), Some(row)) = (pressed_view.upgrade(), pressed_item.upgrade(), gesture.widget())
        else {
            return;
        };
        let at = row.compute_point(&view.list_view, &graphene::Point::new(x as f32, y as f32));
        let pointing = at.map(|point| gdk::Rectangle::new(point.x() as i32, point.y() as i32, 1, 1));
        if view.pressed(
            item.position(),
            gesture.current_button(),
            gesture.current_event_state(),
            pointing,
        ) {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    gesture.connect_released(move |gesture, _, _, _| {
        let Some(view) = view.upgrade() else {
            return;
        };
        if view.released(gesture.current_button()) {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    gesture
}
