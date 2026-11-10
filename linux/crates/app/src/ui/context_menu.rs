use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio};

// GtkPopover slides a menu along the screen edge only when it opens to a side. Opened above or
// below, a menu taller than the room on either side of the pointer is shrunk and scrolls.
pub(crate) fn context_menu(model: Option<&impl IsA<gio::MenuModel>>) -> gtk::PopoverMenu {
    let menu = gtk::PopoverMenu::from_model(model);
    menu.set_has_arrow(false);
    menu.set_position(trailing_side(menu.direction()));
    menu.set_valign(gtk::Align::Start);
    menu
}

// A key points the menu at a whole row or cell, and the menu opens beside its trailing edge,
// which a cell wider than the view has out of sight.
pub(crate) fn popup_at(menu: &gtk::PopoverMenu, pointing: Option<gdk::Rectangle>) {
    let shown = menu
        .parent()
        .map(|parent| gdk::Rectangle::new(0, 0, parent.width(), parent.height()));
    let pointing = pointing.map(|rect| shown.map_or(rect, |shown| in_view(rect, shown)));
    menu.set_pointing_to(pointing.as_ref());
    menu.popup();
}

fn in_view(rect: gdk::Rectangle, shown: gdk::Rectangle) -> gdk::Rectangle {
    rect.intersect(&shown).unwrap_or(rect)
}

// GTK does not mirror left and right for a right-to-left locale.
fn trailing_side(direction: gtk::TextDirection) -> gtk::PositionType {
    match direction {
        gtk::TextDirection::Rtl => gtk::PositionType::Left,
        _ => gtk::PositionType::Right,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_menu_opens_on_the_side_text_runs_toward() {
        assert_eq!(trailing_side(gtk::TextDirection::Ltr), gtk::PositionType::Right);
        assert_eq!(trailing_side(gtk::TextDirection::None), gtk::PositionType::Right);
        assert_eq!(trailing_side(gtk::TextDirection::Rtl), gtk::PositionType::Left);
    }

    #[gtk4::test]
    fn a_context_menu_opens_beside_the_pointer_from_its_top_corner_with_no_arrow() {
        let menu = context_menu(None::<&gio::MenuModel>);

        assert!(!menu.has_arrow());
        assert_eq!(menu.position(), trailing_side(menu.direction()));
        assert_eq!(menu.valign(), gtk::Align::Start);
    }

    #[gtk4::test]
    fn a_menu_points_at_the_part_of_its_cell_in_view() {
        let shown = gdk::Rectangle::new(0, 0, 400, 300);

        assert_eq!(
            in_view(gdk::Rectangle::new(250, 40, 600, 24), shown),
            gdk::Rectangle::new(250, 40, 150, 24),
            "a cell past the trailing edge"
        );
        assert_eq!(
            in_view(gdk::Rectangle::new(-200, 40, 300, 24), shown),
            gdk::Rectangle::new(0, 40, 100, 24),
            "a cell scrolled past the leading edge"
        );
        assert_eq!(
            in_view(gdk::Rectangle::new(40, 60, 1, 1), shown),
            gdk::Rectangle::new(40, 60, 1, 1),
            "a pointer"
        );
        assert_eq!(
            in_view(gdk::Rectangle::new(500, 40, 100, 24), shown),
            gdk::Rectangle::new(500, 40, 100, 24),
            "a cell out of view keeps its place"
        );
    }
}
