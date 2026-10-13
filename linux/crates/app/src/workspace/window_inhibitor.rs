use std::cell::RefCell;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;

use super::InhibitReason;

/// What holds the session back: the window's application, or a test's
/// counter.
pub trait InhibitTarget {
    /// The cookie to release it with, or 0 when nothing was inhibited.
    fn inhibit(&self, flags: gtk::ApplicationInhibitFlags, reason: &str) -> u32;
    fn uninhibit(&self, cookie: u32);
}

/// Holds logout, and suspend while a save runs, for as long as the
/// window has something a logout would lose. At most one inhibition is
/// held at a time, and dropping the inhibitor releases it.
pub struct WindowInhibitor {
    target: Box<dyn InhibitTarget>,
    reason: Option<InhibitReason>,
    /// 0 when nothing is held, which is also what a session without an
    /// inhibit service answers.
    cookie: u32,
}

impl WindowInhibitor {
    pub fn new(target: impl InhibitTarget + 'static) -> Self {
        Self {
            target: Box::new(target),
            reason: None,
            cookie: 0,
        }
    }

    /// Hold the session back for `reason`, or let it go with `None`. The
    /// old inhibition is released before a new one is taken.
    pub fn update(&mut self, reason: Option<InhibitReason>) {
        if reason == self.reason {
            return;
        }
        self.release();
        self.reason = reason;
        if let Some(reason) = reason {
            self.cookie = self.target.inhibit(reason.flags(), &reason.text());
        }
    }

    fn release(&mut self) {
        if self.cookie != 0 {
            self.target.uninhibit(std::mem::take(&mut self.cookie));
        }
    }
}

impl Drop for WindowInhibitor {
    fn drop(&mut self) {
        self.release();
    }
}

impl std::fmt::Debug for WindowInhibitor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WindowInhibitor")
            .field("reason", &self.reason)
            .field("cookie", &self.cookie)
            .finish_non_exhaustive()
    }
}

/// Inhibits through the window's application. The application is
/// looked up when it is needed, since a window is built before it is
/// added to one, and remembered so the release reaches the same one.
#[derive(Debug)]
pub struct ApplicationInhibit {
    window: glib::WeakRef<gtk::Window>,
    application: RefCell<glib::WeakRef<gtk::Application>>,
}

impl ApplicationInhibit {
    pub fn new(window: &impl IsA<gtk::Window>) -> Self {
        Self {
            window: window.upcast_ref::<gtk::Window>().downgrade(),
            application: RefCell::new(glib::WeakRef::new()),
        }
    }
}

impl InhibitTarget for ApplicationInhibit {
    fn inhibit(&self, flags: gtk::ApplicationInhibitFlags, reason: &str) -> u32 {
        let Some(window) = self.window.upgrade() else {
            return 0;
        };
        let Some(application) = window.application() else {
            return 0;
        };
        self.application.replace(application.downgrade());
        application.inhibit(Some(&window), flags, Some(reason))
    }

    fn uninhibit(&self, cookie: u32) {
        if let Some(application) = self.application.borrow().upgrade() {
            application.uninhibit(cookie);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;

    /// Hands out cookies and keeps the ones still held.
    #[derive(Default, Clone)]
    struct Session {
        held: Rc<RefCell<Vec<(u32, gtk::ApplicationInhibitFlags)>>>,
        next: Rc<RefCell<u32>>,
        refuse: bool,
    }

    impl InhibitTarget for Session {
        fn inhibit(&self, flags: gtk::ApplicationInhibitFlags, _reason: &str) -> u32 {
            if self.refuse {
                return 0;
            }
            let cookie = {
                let mut next = self.next.borrow_mut();
                *next += 1;
                *next
            };
            self.held.borrow_mut().push((cookie, flags));
            cookie
        }

        fn uninhibit(&self, cookie: u32) {
            assert_ne!(cookie, 0, "released a cookie that was never held");
            self.held.borrow_mut().retain(|(held, _)| *held != cookie);
        }
    }

    #[test]
    fn for_state_table() {
        assert_eq!(InhibitReason::for_state(false, false), None);
        assert_eq!(
            InhibitReason::for_state(true, false),
            Some(InhibitReason::UnsavedChanges)
        );
        assert_eq!(
            InhibitReason::for_state(false, true),
            Some(InhibitReason::SavingChanges)
        );
        assert_eq!(InhibitReason::for_state(true, true), Some(InhibitReason::SavingChanges));
        assert_eq!(
            InhibitReason::UnsavedChanges.flags(),
            gtk::ApplicationInhibitFlags::LOGOUT
        );
        assert_eq!(
            InhibitReason::SavingChanges.flags(),
            gtk::ApplicationInhibitFlags::LOGOUT | gtk::ApplicationInhibitFlags::SUSPEND
        );
    }

    #[gtk4::test]
    fn update_keeps_single_cookie() {
        let session = Session::default();
        let mut inhibitor = WindowInhibitor::new(session.clone());

        inhibitor.update(Some(InhibitReason::UnsavedChanges));
        inhibitor.update(Some(InhibitReason::UnsavedChanges));
        assert_eq!(session.held.borrow().len(), 1);
        assert_eq!(*session.next.borrow(), 1, "the same reason inhibited again");

        inhibitor.update(Some(InhibitReason::SavingChanges));
        assert_eq!(
            session.held.borrow().as_slice(),
            [(2, InhibitReason::SavingChanges.flags())]
        );

        inhibitor.update(None);
        assert!(session.held.borrow().is_empty());

        inhibitor.update(Some(InhibitReason::UnsavedChanges));
        drop(inhibitor);
        assert!(
            session.held.borrow().is_empty(),
            "dropping the inhibitor kept the session held"
        );
    }

    #[gtk4::test]
    fn a_refused_inhibit_is_never_released() {
        let session = Session {
            refuse: true,
            ..Session::default()
        };
        let mut inhibitor = WindowInhibitor::new(session.clone());

        inhibitor.update(Some(InhibitReason::SavingChanges));
        inhibitor.update(None);
        drop(inhibitor);

        assert!(session.held.borrow().is_empty());
    }

    #[gtk4::test]
    fn a_window_without_an_application_inhibits_nothing() {
        let window = gtk::Window::new();
        let target = ApplicationInhibit::new(&window);

        assert_eq!(target.inhibit(gtk::ApplicationInhibitFlags::LOGOUT, "unsaved"), 0);
        target.uninhibit(3);
    }
}
