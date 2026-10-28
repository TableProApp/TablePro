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
    /// Whether the page the view has selected is one of these.
    in_front: Cell<bool>,
}

impl TabIndex {
    pub(crate) fn insert(&self, page: &adw::TabPage, id: Uuid) {
        self.ids.borrow_mut().insert(page.clone(), id);
    }

    pub(crate) fn id_of(&self, page: &adw::TabPage) -> Option<Uuid> {
        self.ids.borrow().get(page).copied()
    }

    /// The page of tab `id`, while it is open.
    pub(crate) fn page_of(&self, id: Uuid) -> Option<adw::TabPage> {
        self.ids
            .borrow()
            .iter()
            .find_map(|(page, held)| (*held == id).then(|| page.clone()))
    }

    pub(crate) fn remove(&self, page: &adw::TabPage) -> Option<Uuid> {
        let id = self.ids.borrow_mut().remove(page);
        if id.is_some() && id == self.last_selected.get() {
            self.last_selected.set(None);
        }
        id
    }

    pub(crate) fn pages(&self) -> Vec<adw::TabPage> {
        self.ids.borrow().keys().cloned().collect()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.ids.borrow().is_empty()
    }

    /// This workspace's first page in the order `view` shows them.
    pub(crate) fn first_in(&self, view: &adw::TabView) -> Option<adw::TabPage> {
        let ids = self.ids.borrow();
        (0..view.n_pages())
            .map(|position| view.nth_page(position))
            .find(|page| ids.contains_key(page))
    }

    /// The view selected `page`. Remembered as the tab to come back to
    /// when it is ours. True when the selection came to one of ours or
    /// left one, which is what the workspace has to hear about.
    pub(crate) fn note_selected(&self, page: Option<&adw::TabPage>) -> bool {
        let id = page.and_then(|page| self.id_of(page));
        if id.is_some() {
            self.last_selected.set(id);
        }
        let was = self.in_front.replace(id.is_some());
        id.is_some() || was
    }

    /// Make `page` the tab to come back to without selecting it, as a
    /// restore behind another session's tab does.
    pub(crate) fn remember(&self, page: &adw::TabPage) {
        if let Some(id) = self.id_of(page) {
            self.last_selected.set(Some(id));
        }
    }

    pub(crate) fn last_selected(&self) -> Option<Uuid> {
        self.last_selected.get()
    }

    /// Let go of every page, so a closed workspace holds none of them.
    pub(crate) fn clear(&self) {
        self.last_selected.set(None);
        self.in_front.set(false);
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
        assert_eq!(index.page_of(b), Some(second.clone()));
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

        assert!(index.note_selected(Some(&ours)));
        assert!(
            index.note_selected(Some(&theirs)),
            "our tab leaving the front went unheard"
        );
        assert!(!index.note_selected(Some(&theirs)));

        assert_eq!(index.last_selected(), Some(id));
    }

    #[gtk4::test]
    fn a_closed_tab_is_no_longer_the_one_to_come_back_to() {
        adw::init().expect("libadwaita initialises under the test backend");
        let view = adw::TabView::new();
        let page = view.append(&gtk::Label::new(None));
        let index = TabIndex::default();
        index.insert(&page, Uuid::new_v4());
        index.note_selected(Some(&page));

        index.remove(&page);

        assert_eq!(index.last_selected(), None);
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
