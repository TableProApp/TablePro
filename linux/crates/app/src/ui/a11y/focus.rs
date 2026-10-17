use gtk4 as gtk;
use gtk4::prelude::*;

/// Whether the window's focus is `widget` or inside it.
pub(crate) fn holds_focus(widget: &impl IsA<gtk::Widget>) -> bool {
    let widget = widget.as_ref();
    widget
        .root()
        .and_then(|root| root.focus())
        .is_some_and(|focus| &focus == widget || focus.is_ancestor(widget))
}

/// Move the focus from inside `from` to `to`, before `from` is hidden or
/// turned off. GTK would move it to the first control of the window.
pub(crate) fn pass_focus(from: &impl IsA<gtk::Widget>, to: &impl IsA<gtk::Widget>) -> bool {
    holds_focus(from) && to.as_ref().grab_focus()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{OwnedWindow, drain_main_context};

    #[gtk4::test]
    fn the_focus_moves_only_from_inside() {
        let first = gtk::Button::with_label("First");
        let second = gtk::Button::with_label("Second");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        row.append(&first);
        row.append(&second);
        let window = OwnedWindow::presented(gtk::Window::builder().child(&row).build());
        first.grab_focus();
        drain_main_context();

        assert!(!pass_focus(&second, &first), "the focus was not in Second");
        assert!(pass_focus(&first, &second));
        assert_eq!(GtkWindowExt::focus(&*window).as_ref(), Some(second.upcast_ref()));
        assert!(holds_focus(&row));
    }
}
