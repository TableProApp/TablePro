use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;

// GtkPopover slides a menu along the screen edge only when it opens to a side. Opened above or
// below, a menu taller than the room on either side of the pointer is shrunk and scrolls.
pub(crate) fn context_menu(model: Option<&impl IsA<gio::MenuModel>>) -> gtk::PopoverMenu {
    let menu = gtk::PopoverMenu::from_model(model);
    menu.set_has_arrow(false);
    menu.set_position(trailing_side(menu.direction()));
    menu.set_valign(gtk::Align::Start);
    menu
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
}
