use std::cell::RefCell;
use std::collections::HashMap;

use crate::runtime::InputSender;
use crate::ui::{SessionWindow, SessionWindowInput};

/// Each window the application opened, by window id. GTK-thread only.
#[derive(Default)]
pub(crate) struct WindowRegistry {
    windows: RefCell<HashMap<u32, SessionWindow>>,
}

impl WindowRegistry {
    pub(crate) fn insert(&self, id: u32, window: SessionWindow) {
        self.windows.borrow_mut().insert(id, window);
    }

    /// The window is shut down after the map is released: its teardown
    /// may present another window, which reads the map.
    pub(crate) fn remove(&self, id: u32) {
        let removed = self.windows.borrow_mut().remove(&id);
        if let Some(window) = removed {
            window.shutdown();
        }
    }

    pub(crate) fn sender(&self, id: u32) -> Option<InputSender<SessionWindowInput>> {
        self.windows.borrow().get(&id).and_then(SessionWindow::input)
    }

    /// Whether the window holds logout back.
    pub(crate) fn holds_inhibit(&self, id: u32) -> bool {
        self.windows.borrow().get(&id).is_some_and(SessionWindow::is_inhibiting)
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.windows.borrow().len()
    }

    #[cfg(test)]
    pub(crate) fn get(&self, id: u32) -> Option<SessionWindow> {
        self.windows.borrow().get(&id).cloned()
    }

    pub(crate) fn clear(&self) {
        let windows: Vec<SessionWindow> = self.windows.borrow_mut().drain().map(|(_, window)| window).collect();
        for window in windows {
            window.shutdown();
        }
    }
}

impl std::fmt::Debug for WindowRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WindowRegistry")
            .field("windows", &self.windows.borrow().keys().collect::<Vec<_>>())
            .finish()
    }
}
