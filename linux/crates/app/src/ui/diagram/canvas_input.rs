//! The pointer on the canvas: drag a card or the empty space, click to
//! select, double click to open, right click for the menu, Ctrl+scroll
//! and a pinch to zoom.

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio};

use super::canvas::{DiagramCanvas, Drag};
use super::canvas_imp::has_primary_modifier;
use super::layout::Point;
use crate::application::menu_item;

/// A press that moves less than this is a click, not a drag.
const DRAG_THRESHOLD: f64 = 4.0;
/// Ctrl+scroll zooms by this much per wheel notch.
const WHEEL_ZOOM: f64 = 1.1;
/// A touchpad scrolls in pixels; this many make one notch's zoom.
const PIXELS_PER_NOTCH: f64 = 40.0;

pub(super) fn install(canvas: &DiagramCanvas) {
    install_drag(canvas, gdk::BUTTON_PRIMARY, true);
    install_drag(canvas, gdk::BUTTON_MIDDLE, false);
    install_click(canvas);
    install_scroll(canvas);
    install_pinch(canvas);
    let motion = gtk::EventControllerMotion::new();
    let weak = canvas.downgrade();
    motion.connect_motion(move |_, x, y| {
        if let Some(canvas) = weak.upgrade() {
            canvas.imp().pointer.set(Some((x, y)));
        }
    });
    let weak = canvas.downgrade();
    motion.connect_leave(move |_| {
        if let Some(canvas) = weak.upgrade() {
            canvas.imp().pointer.set(None);
        }
    });
    canvas.add_controller(motion);
}

/// The primary button drags a card, or pans from empty space; the
/// middle button always pans.
fn install_drag(canvas: &DiagramCanvas, button: u32, moves_cards: bool) {
    let drag = gtk::GestureDrag::new();
    drag.set_button(button);
    let weak = canvas.downgrade();
    drag.connect_drag_begin(move |_, x, y| {
        let Some(canvas) = weak.upgrade() else {
            return;
        };
        let card = moves_cards.then(|| canvas.card_at(x, y)).flatten();
        let start = match card.and_then(|index| card_origin(&canvas, index).map(|from| (index, from))) {
            Some((index, from)) => Drag::Card {
                index,
                from,
                moved: false,
            },
            None => {
                let (h, v) = canvas.imp().adjustments();
                Drag::Pan {
                    scroll: (
                        h.map_or(0.0, |adjustment| adjustment.value()),
                        v.map_or(0.0, |adjustment| adjustment.value()),
                    ),
                }
            }
        };
        canvas.imp().drag.replace(Some(start));
    });
    let weak = canvas.downgrade();
    drag.connect_drag_update(move |_, dx, dy| {
        if let Some(canvas) = weak.upgrade() {
            drag_update(&canvas, dx, dy);
        }
    });
    let weak = canvas.downgrade();
    drag.connect_drag_end(move |_, dx, dy| {
        let Some(canvas) = weak.upgrade() else {
            return;
        };
        drag_update(&canvas, dx, dy);
        if let Some(Drag::Card { moved: true, .. }) = canvas.imp().drag.take() {
            canvas.settle_move();
        }
    });
    canvas.add_controller(drag);
}

fn card_origin(canvas: &DiagramCanvas, index: usize) -> Option<Point> {
    let content = canvas.imp().content.borrow();
    content.as_ref()?.cards.get(index).map(|card| card.at)
}

fn drag_update(canvas: &DiagramCanvas, dx: f64, dy: f64) {
    let imp = canvas.imp();
    let current = *imp.drag.borrow();
    match current {
        Some(Drag::Card { index, from, moved }) => {
            if !moved && dx.hypot(dy) < DRAG_THRESHOLD {
                return;
            }
            imp.drag.replace(Some(Drag::Card {
                index,
                from,
                moved: true,
            }));
            let zoom = canvas.zoom();
            canvas.place_card(
                index,
                Point {
                    x: from.x + dx / zoom,
                    y: from.y + dy / zoom,
                },
            );
        }
        Some(Drag::Pan { scroll }) => {
            let (h, v) = imp.adjustments();
            if let Some(h) = h {
                h.set_value(scroll.0 - dx);
            }
            if let Some(v) = v {
                v.set_value(scroll.1 - dy);
            }
        }
        None => {}
    }
}

fn install_click(canvas: &DiagramCanvas) {
    let click = gtk::GestureClick::new();
    click.set_button(0);
    let weak = canvas.downgrade();
    click.connect_pressed(move |gesture, presses, x, y| {
        let Some(canvas) = weak.upgrade() else {
            return;
        };
        let card = canvas.card_at(x, y);
        match gesture.current_button() {
            gdk::BUTTON_PRIMARY => {
                match card {
                    Some(index) => focus_by_pointer(&canvas, index),
                    None => canvas.select(None),
                }
                if presses == 2
                    && let Some(index) = card
                {
                    canvas.emit_by_name::<()>("table-activated", &[&u32::try_from(index).unwrap_or(u32::MAX)]);
                }
            }
            gdk::BUTTON_SECONDARY => {
                if let Some(index) = card {
                    focus_by_pointer(&canvas, index);
                    popup_menu(&canvas, gdk::Rectangle::new(x.round() as i32, y.round() as i32, 1, 1));
                }
            }
            _ => {}
        }
    });
    canvas.add_controller(click);
}

/// A click puts the keyboard on the card it selects, so the keys go on
/// from there, without scrolling: the card is under the pointer.
fn focus_by_pointer(canvas: &DiagramCanvas, index: usize) {
    canvas.imp().quiet_focus.set(true);
    canvas.focus_table(index);
    canvas.imp().quiet_focus.set(false);
}

fn install_scroll(canvas: &DiagramCanvas) {
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
    let weak = canvas.downgrade();
    scroll.connect_scroll(move |controller, _, dy| {
        let Some(canvas) = weak.upgrade() else {
            return gtk::glib::Propagation::Proceed;
        };
        if !has_primary_modifier(controller.current_event_state()) {
            // The scrolled window pans.
            return gtk::glib::Propagation::Proceed;
        }
        let notches = match controller.unit() {
            gdk::ScrollUnit::Surface => dy / PIXELS_PER_NOTCH,
            _ => dy,
        };
        let anchor = canvas.imp().pointer.get();
        canvas.set_zoom(canvas.zoom() * WHEEL_ZOOM.powf(-notches), anchor);
        gtk::glib::Propagation::Stop
    });
    canvas.add_controller(scroll);
}

fn install_pinch(canvas: &DiagramCanvas) {
    let pinch = gtk::GestureZoom::new();
    let weak = canvas.downgrade();
    pinch.connect_begin(move |_, _| {
        if let Some(canvas) = weak.upgrade() {
            canvas.imp().pinch.set(Some(canvas.zoom()));
        }
    });
    let weak = canvas.downgrade();
    pinch.connect_scale_changed(move |gesture, scale| {
        let Some(canvas) = weak.upgrade() else {
            return;
        };
        let Some(start) = canvas.imp().pinch.get() else {
            return;
        };
        canvas.set_zoom(start * scale, gesture.bounding_box_center());
    });
    let weak = canvas.downgrade();
    pinch.connect_end(move |_, _| {
        if let Some(canvas) = weak.upgrade() {
            canvas.imp().pinch.set(None);
        }
    });
    canvas.add_controller(pinch);
}

/// The selected table's menu, pointing at `at` on the canvas.
pub(super) fn popup_menu(canvas: &DiagramCanvas, at: gdk::Rectangle) {
    let imp = canvas.imp();
    let popover = imp
        .popover
        .borrow_mut()
        .get_or_insert_with(|| {
            let menu = gio::Menu::new();
            menu.append_item(&menu_item(&crate::i18n::gettext("Open Table"), "diagram.open-table"));
            menu.append_item(&menu_item(
                &crate::i18n::gettext("Show Structure"),
                "diagram.show-structure",
            ));
            let popover = gtk::PopoverMenu::from_model(Some(&menu));
            popover.set_has_arrow(true);
            popover.set_parent(canvas);
            popover
        })
        .clone();
    popover.set_pointing_to(Some(&at));
    popover.popup();
}
