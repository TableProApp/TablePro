use std::collections::HashMap;

use uuid::Uuid;

#[derive(Default)]
pub struct CloseAfterSave {
    pending: HashMap<Uuid, u32>,
}

impl CloseAfterSave {
    pub fn begin(&mut self, tab: Uuid, saves: u32) {
        if saves > 0 {
            *self.pending.entry(tab).or_insert(0) += saves;
        }
    }

    pub fn complete(&mut self, tab: &Uuid) -> bool {
        if let Some(count) = self.pending.get_mut(tab) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.pending.remove(tab);
                return true;
            }
        }
        false
    }

    pub fn cancel(&mut self, tab: &Uuid) {
        self.pending.remove(tab);
    }

    pub fn remaining(&self, tab: &Uuid) -> Option<u32> {
        self.pending.get(tab).copied()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

pub fn close_other_page_indexes(page_ids: &[Option<Uuid>], keep_id: Uuid) -> Vec<usize> {
    page_ids
        .iter()
        .enumerate()
        .filter_map(|(index, id)| (*id != Some(keep_id)).then_some(index))
        .collect()
}

pub fn close_page_indexes_to_right(page_ids: &[Option<Uuid>], anchor_id: Uuid) -> Vec<usize> {
    let Some(anchor) = page_ids.iter().position(|id| *id == Some(anchor_id)) else {
        return Vec::new();
    };
    ((anchor + 1)..page_ids.len()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn close_other_targets_leave_the_selected_page_open() {
        let left = Uuid::new_v4();
        let keep = Uuid::new_v4();
        let right = Uuid::new_v4();
        let page_ids = [Some(left), Some(keep), Some(right)];

        assert_eq!(close_other_page_indexes(&page_ids, keep), vec![0, 2]);
    }

    #[test]
    fn close_right_targets_only_pages_after_the_anchor_in_current_order() {
        let left = Uuid::new_v4();
        let anchor = Uuid::new_v4();
        let right = Uuid::new_v4();
        let page_ids = [Some(left), Some(anchor), None, Some(right)];

        assert_eq!(close_page_indexes_to_right(&page_ids, anchor), vec![2, 3]);
    }

    #[test]
    fn a_missing_close_right_anchor_does_not_target_any_page() {
        let page_ids = [Some(Uuid::new_v4()), Some(Uuid::new_v4())];

        assert!(close_page_indexes_to_right(&page_ids, Uuid::new_v4()).is_empty());
    }
}

#[cfg(test)]
#[path = "close_after_save_tests.rs"]
mod close_after_save_tests;
