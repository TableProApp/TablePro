use std::cell::RefCell;
use std::collections::HashMap;

use relm4::gtk;
use uuid::Uuid;

thread_local! {
    static OWNERS: RefCell<HashMap<Uuid, gtk::Window>> = RefCell::new(HashMap::new());
}

/// Record which window owns a connection, so an approval dialog for a
/// statement on that connection can be parented to the window that
/// actually triggered it instead of whichever window last had focus.
pub fn register(connection_id: Uuid, window: gtk::Window) {
    OWNERS.with(|owners| owners.borrow_mut().insert(connection_id, window));
}

pub fn unregister(connection_id: Uuid) {
    OWNERS.with(|owners| {
        owners.borrow_mut().remove(&connection_id);
    });
}

pub fn window_for(connection_id: Uuid) -> Option<gtk::Window> {
    OWNERS.with(|owners| owners.borrow().get(&connection_id).cloned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unregistered_connection_has_no_owning_window() {
        assert!(window_for(Uuid::new_v4()).is_none());
    }
}
