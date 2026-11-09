use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib, graphene};
use libadwaita as adw;
use tablepro_linux_platform::settings::keys::SIDEBAR_WIDTH;

// The schema's range, which refuses a write outside it.
const NARROWEST: f64 = 220.0;
const WIDEST: f64 = 1200.0;
const STEP: f64 = 16.0;

// The setting is the most the sidebar takes, which the split view's fraction
// lowers in a narrow window, so every window reads it and a drag writes it
// once it ends.
pub(super) fn follow(split: &adw::OverlaySplitView, handle: &gtk::Box, settings: &gio::Settings) {
    settings.bind(SIDEBAR_WIDTH, split, "max-sidebar-width").get().build();
    // Collapsed, the sidebar lies over the content at its widest.
    handle.set_visible(!split.is_collapsed());
    split.connect_collapsed_notify(glib::clone!(
        #[weak]
        handle,
        move |split| handle.set_visible(!split.is_collapsed())
    ));

    let drag = gtk::GestureDrag::new();
    drag.connect_drag_update(glib::clone!(
        #[weak]
        split,
        #[weak]
        handle,
        move |drag, _, _| {
            if let Some(width) = pointer_width(&split, &handle, drag) {
                split.set_max_sidebar_width(width.clamp(NARROWEST, WIDEST));
            }
        }
    ));
    drag.connect_drag_end(glib::clone!(
        #[weak]
        split,
        #[strong]
        settings,
        move |_, _, _| keep(&settings, split.max_sidebar_width())
    ));
    handle.add_controller(drag);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(glib::clone!(
        #[weak]
        split,
        #[strong]
        settings,
        #[upgrade_or]
        glib::Propagation::Proceed,
        move |_, key, _, _| match step(key, split.direction() == gtk::TextDirection::Rtl) {
            Some(step) => {
                keep(&settings, shown_width(&split) + step);
                glib::Propagation::Stop
            }
            None => glib::Propagation::Proceed,
        }
    ));
    handle.add_controller(keys);
}

// Towards the content widens the sidebar, whichever side it is on.
fn step(key: gdk::Key, rtl: bool) -> Option<f64> {
    match (key, rtl) {
        (gdk::Key::Right, false) | (gdk::Key::Left, true) => Some(STEP),
        (gdk::Key::Left, false) | (gdk::Key::Right, true) => Some(-STEP),
        _ => None,
    }
}

fn keep(settings: &gio::Settings, width: f64) {
    if let Err(error) = settings.set_double(SIDEBAR_WIDTH, width.round().clamp(NARROWEST, WIDEST)) {
        tracing::warn!(%error, "the sidebar's width was not kept");
    }
}

fn shown_width(split: &adw::OverlaySplitView) -> f64 {
    let pixels = split.sidebar().map_or(0, |sidebar| sidebar.width());
    split
        .sidebar_width_unit()
        .from_px(f64::from(pixels), Some(&split.settings()))
}

// Measured in the split view, which stays put while the handle moves with the edge.
fn pointer_width(split: &adw::OverlaySplitView, handle: &gtk::Box, drag: &gtk::GestureDrag) -> Option<f64> {
    let (x, y) = drag.point(None)?;
    let point = handle.compute_point(split, &graphene::Point::new(x as f32, y as f32))?;
    let pixels = match split.direction() {
        gtk::TextDirection::Rtl => f64::from(split.width()) - f64::from(point.x()),
        _ => f64::from(point.x()),
    };
    Some(split.sidebar_width_unit().from_px(pixels, Some(&split.settings())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_arrow_towards_the_content_widens_the_sidebar() {
        assert_eq!(step(gdk::Key::Right, false), Some(STEP));
        assert_eq!(step(gdk::Key::Left, false), Some(-STEP));
        assert_eq!(step(gdk::Key::Left, true), Some(STEP), "the sidebar is on the right");
        assert_eq!(step(gdk::Key::Up, false), None);
    }
}
