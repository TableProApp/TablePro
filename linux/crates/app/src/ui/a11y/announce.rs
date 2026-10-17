use gtk4 as gtk;
use gtk4::prelude::*;

/// Say `message` from `widget`, for a change a screen reader would not
/// otherwise hear: one away from the focus, or text that changed under
/// it.
pub(crate) fn announce(widget: &impl IsA<gtk::Widget>, message: &str, priority: gtk::AccessibleAnnouncementPriority) {
    if message.is_empty() {
        return;
    }
    let widget = widget.as_ref();
    #[cfg(test)]
    said::record(widget, message, priority);
    widget.announce(message, priority);
}

/// Show `text` on a status line, and say it when it changed: a screen
/// reader does not read a label that changes away from the focus.
pub(crate) fn show_status(label: &gtk::Label, text: &str) {
    if label.label() == text {
        return;
    }
    label.set_label(text);
    announce(label, text, gtk::AccessibleAnnouncementPriority::Medium);
}

/// GTK's test backend keeps no announcement, so a test reads them here.
#[cfg(test)]
pub(crate) mod said {
    use std::cell::RefCell;

    use gtk4 as gtk;
    use gtk4::glib;
    use gtk4::prelude::*;

    thread_local! {
        static SAID: RefCell<Vec<(glib::WeakRef<gtk::Widget>, String, gtk::AccessibleAnnouncementPriority)>> =
            const { RefCell::new(Vec::new()) };
    }

    pub(super) fn record(widget: &gtk::Widget, message: &str, priority: gtk::AccessibleAnnouncementPriority) {
        SAID.with_borrow_mut(|said| said.push((widget.downgrade(), message.to_owned(), priority)));
    }

    /// What `root`, or a widget inside it, announced, oldest first.
    pub(crate) fn announced_in(root: &impl IsA<gtk::Widget>) -> Vec<(String, gtk::AccessibleAnnouncementPriority)> {
        let root = root.as_ref();
        SAID.with_borrow(|said| {
            said.iter()
                .filter(|(widget, _, _)| {
                    widget
                        .upgrade()
                        .is_some_and(|widget| &widget == root || widget.is_ancestor(root))
                })
                .map(|(_, message, priority)| (message.clone(), *priority))
                .collect()
        })
    }
}
