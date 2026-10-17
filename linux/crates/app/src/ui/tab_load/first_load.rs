use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;

/// When a tab makes its first read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum FirstLoad {
    #[default]
    Now,
    /// The first time the tab is on screen. A restored session reopens
    /// every tab together, and reading them all at once would queue more
    /// reads than the pool has connections.
    WhenShown,
}

/// Run `start` now, or for `WhenShown` once `widget` stays mapped past
/// the main loop's turn that mapped it. A restore selects the first tab
/// it adds before the one that was active, and that first tab is on
/// screen for no time at all.
pub(crate) fn start_first_load(widget: &impl IsA<gtk::Widget>, load: FirstLoad, start: impl FnOnce() + 'static) {
    if load == FirstLoad::Now {
        start();
        return;
    }
    let pending = PendingStart {
        start: Rc::new(RefCell::new(Some(Box::new(start)))),
        handler: Rc::default(),
    };
    let widget = widget.as_ref();
    let id = widget.connect_map({
        let pending = pending.clone();
        move |widget| pending.start_if_it_stays(widget)
    });
    pending.handler.replace(Some(id));
    if widget.is_mapped() {
        pending.start_if_it_stays(widget);
    }
}

/// The first read, taken by whichever showing starts it.
type StartOnce = Rc<RefCell<Option<Box<dyn FnOnce()>>>>;

/// A first read waiting for its tab to stay on screen.
#[derive(Clone)]
struct PendingStart {
    start: StartOnce,
    handler: Rc<RefCell<Option<glib::SignalHandlerId>>>,
}

impl PendingStart {
    fn start_if_it_stays(&self, widget: &gtk::Widget) {
        let widget = widget.downgrade();
        let pending = self.clone();
        glib::idle_add_local_once(move || {
            let Some(widget) = widget.upgrade().filter(gtk::Widget::is_mapped) else {
                return;
            };
            if let Some(id) = pending.handler.borrow_mut().take() {
                widget.disconnect(id);
            }
            let start = pending.start.borrow_mut().take();
            if let Some(start) = start {
                start();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::time::Duration;

    use super::*;
    use crate::test_support::{OwnedWindow, drain_main_context, wait_until};

    fn counting(label: &gtk::Label, load: FirstLoad) -> Rc<Cell<u32>> {
        let starts = Rc::new(Cell::new(0));
        start_first_load(label, load, {
            let starts = starts.clone();
            move || starts.set(starts.get() + 1)
        });
        starts
    }

    #[gtk4::test]
    fn a_tab_loaded_when_shown_starts_once_it_stays_on_screen() {
        let label = gtk::Label::new(None);
        let starts = counting(&label, FirstLoad::WhenShown);
        assert_eq!(starts.get(), 0, "a tab not on screen read its table");

        let window = OwnedWindow::presented(gtk::Window::new());
        window.set_child(Some(&label));
        wait_until(Duration::from_secs(5), || starts.get() == 1).expect("the read once the tab is shown");
        label.set_visible(false);
        label.set_visible(true);
        drain_main_context();
        assert_eq!(starts.get(), 1, "a second map read again");
        window.set_child(None::<&gtk::Widget>);
    }

    #[gtk4::test]
    fn a_tab_shown_for_no_time_waits_for_its_next_showing() {
        let label = gtk::Label::new(None);
        let starts = counting(&label, FirstLoad::WhenShown);
        let window = OwnedWindow::presented(gtk::Window::new());
        wait_until(Duration::from_secs(5), || window.is_mapped()).expect("the window on screen");

        window.set_child(Some(&label));
        label.set_visible(false);
        drain_main_context();
        assert_eq!(starts.get(), 0, "a tab on screen for no time read its table");

        label.set_visible(true);
        wait_until(Duration::from_secs(5), || starts.get() == 1).expect("the read once the tab stays");
        window.set_child(None::<&gtk::Widget>);
    }

    #[gtk4::test]
    fn a_tab_loaded_now_starts_at_once() {
        let starts = counting(&gtk::Label::new(None), FirstLoad::Now);
        assert_eq!(starts.get(), 1);
    }
}
