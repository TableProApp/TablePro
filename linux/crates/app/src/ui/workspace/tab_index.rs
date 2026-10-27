use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use libadwaita as adw;
use uuid::Uuid;

/// Which tab each page of the tab view shows. A page is in it from the
/// moment it is appended until its close finishes.
#[derive(Debug, Default)]
pub(crate) struct TabIndex {
    ids: RefCell<HashMap<adw::TabPage, Uuid>>,
    /// The workspace's tab the view selected last. The view is shared by
    /// the window's sessions, so it may show another's while this one's
    /// stays the tab to come back to.
    last_selected: Cell<Option<Uuid>>,
}

impl TabIndex {
    pub(crate) fn insert(&self, page: &adw::TabPage, id: Uuid) {
        self.ids.borrow_mut().insert(page.clone(), id);
    }

    pub(crate) fn id_of(&self, page: &adw::TabPage) -> Option<Uuid> {
        self.ids.borrow().get(page).copied()
    }

    pub(crate) fn remove(&self, page: &adw::TabPage) -> Option<Uuid> {
        self.ids.borrow_mut().remove(page)
    }

    /// This workspace's tabs, in the order `view` shows them.
    pub(crate) fn order_in(&self, view: &adw::TabView) -> Vec<Uuid> {
        let ids = self.ids.borrow();
        (0..view.n_pages())
            .filter_map(|position| ids.get(&view.nth_page(position)).copied())
            .collect()
    }

    pub(crate) fn pages(&self) -> Vec<adw::TabPage> {
        self.ids.borrow().keys().cloned().collect()
    }

    /// Remember `page` as the one to come back to, when it is ours.
    pub(crate) fn note_selected(&self, page: Option<&adw::TabPage>) {
        if let Some(id) = page.and_then(|page| self.id_of(page)) {
            self.last_selected.set(Some(id));
        }
    }

    pub(crate) fn last_selected(&self) -> Option<Uuid> {
        self.last_selected.get()
    }

    /// Let go of every page, so a closed workspace holds none of them.
    pub(crate) fn clear(&self) {
        self.last_selected.set(None);
        self.ids.borrow_mut().clear();
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;

    use super::*;

    #[gtk4::test]
    fn tab_index_round_trips() {
        adw::init().expect("libadwaita initialises under the test backend");
        let view = adw::TabView::new();
        let first = view.append(&gtk::Label::new(None));
        let second = view.append(&gtk::Label::new(None));
        let index = TabIndex::default();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());

        index.insert(&first, a);
        index.insert(&second, b);

        assert_eq!(index.id_of(&first), Some(a));
        assert_eq!(index.id_of(&second), Some(b));
        assert_eq!(index.remove(&first), Some(a));
        assert_eq!(index.id_of(&first), None);
        assert_eq!(index.id_of(&second), Some(b));
    }

    #[gtk4::test]
    fn another_sessions_page_leaves_the_last_selected_tab() {
        adw::init().expect("libadwaita initialises under the test backend");
        let view = adw::TabView::new();
        let ours = view.append(&gtk::Label::new(None));
        let theirs = view.append(&gtk::Label::new(None));
        let index = TabIndex::default();
        let id = Uuid::new_v4();
        index.insert(&ours, id);

        index.note_selected(Some(&ours));
        index.note_selected(Some(&theirs));

        assert_eq!(index.last_selected(), Some(id));
    }

    #[gtk4::test]
    fn a_page_removed_from_the_index_is_freed() {
        adw::init().expect("libadwaita initialises under the test backend");
        let view = adw::TabView::new();
        let page = view.append(&gtk::Label::new(None));
        let index = TabIndex::default();
        index.insert(&page, Uuid::new_v4());
        let freed = page.downgrade();

        view.close_page(&page);
        index.remove(&page);
        drop(page);

        assert!(freed.upgrade().is_none(), "the index kept a closed page alive");
    }
}
