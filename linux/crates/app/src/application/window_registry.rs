use std::cell::RefCell;
use std::collections::HashMap;

use relm4::{ComponentController, Controller};

use crate::ui::{App, AppMsg};

/// The controller of each window the application opened, by window id.
/// GTK-thread only.
#[derive(Default)]
pub(crate) struct WindowRegistry {
    controllers: RefCell<HashMap<u32, Controller<App>>>,
}

impl WindowRegistry {
    pub(crate) fn insert(&self, id: u32, controller: Controller<App>) {
        self.controllers.borrow_mut().insert(id, controller);
    }

    /// The caller drops the controller after the map is released, since
    /// dropping it stops the window's component.
    pub(crate) fn remove(&self, id: u32) -> Option<Controller<App>> {
        self.controllers.borrow_mut().remove(&id)
    }

    pub(crate) fn sender(&self, id: u32) -> Option<relm4::Sender<AppMsg>> {
        self.controllers
            .borrow()
            .get(&id)
            .map(|controller| controller.sender().clone())
    }

    /// Whether the window holds logout back.
    ///
    /// The state is read outside any update: the components run their
    /// updates without returning to the main loop, which is the only
    /// place this is called from.
    pub(crate) fn holds_inhibit(&self, id: u32) -> bool {
        self.controllers
            .borrow()
            .get(&id)
            .is_some_and(|controller| controller.model().is_inhibiting())
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.controllers.borrow().len()
    }

    #[cfg(test)]
    pub(crate) fn with_model<R>(&self, id: u32, change: impl FnOnce(&mut App) -> R) -> Option<R> {
        let controllers = self.controllers.borrow();
        let controller = controllers.get(&id)?;
        let mut parts = controller.state().get_mut();
        Some(change(&mut parts.model))
    }

    pub(crate) fn clear(&self) {
        let controllers: Vec<Controller<App>> = self.controllers.borrow_mut().drain().map(|(_, c)| c).collect();
        drop(controllers);
    }
}

impl std::fmt::Debug for WindowRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WindowRegistry")
            .field("windows", &self.controllers.borrow().keys().collect::<Vec<_>>())
            .finish()
    }
}
