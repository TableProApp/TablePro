#[derive(Debug, Clone)]
pub struct RecentList<T> {
    newest_first: Vec<T>,
}

impl<T> Default for RecentList<T> {
    fn default() -> Self {
        Self {
            newest_first: Vec::new(),
        }
    }
}

impl<T: PartialEq + Clone> RecentList<T> {
    pub fn touch(&mut self, item: &T) {
        self.forget(item);
        self.newest_first.insert(0, item.clone());
    }

    pub fn forget(&mut self, item: &T) {
        self.newest_first.retain(|entry| entry != item);
    }

    pub fn walk(&self) -> RecentWalk<T> {
        RecentWalk {
            order: self.newest_first.clone(),
            position: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RecentWalk<T> {
    order: Vec<T>,
    position: usize,
}

impl<T: Clone> RecentWalk<T> {
    pub fn step(&mut self, is_open: impl Fn(&T) -> bool) -> Option<T> {
        let count = self.order.len();
        for offset in 1..count {
            let candidate = (self.position + offset) % count;
            if is_open(&self.order[candidate]) {
                self.position = candidate;
                return Some(self.order[candidate].clone());
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(order: &[u8]) -> RecentList<u8> {
        let mut recent = RecentList::default();
        for item in order.iter().rev() {
            recent.touch(item);
        }
        recent
    }

    #[test]
    fn the_first_step_is_the_tab_used_just_before_the_current() {
        let mut recent = RecentList::default();
        for tab in [1u8, 2, 3] {
            recent.touch(&tab);
        }
        assert_eq!(recent.walk().step(|_| true), Some(2));
        recent.touch(&1);
        assert_eq!(recent.walk().step(|_| true), Some(3));
    }

    #[test]
    fn releasing_and_pressing_again_alternates_between_two_tabs() {
        let mut recent = list(&[1, 2, 3]);
        for expected in [2u8, 1, 2, 1] {
            let next = recent.walk().step(|_| true).unwrap();
            assert_eq!(next, expected);
            recent.touch(&next);
        }
    }

    #[test]
    fn a_closed_tab_is_never_offered() {
        let mut recent = list(&[1, 2, 3]);
        recent.forget(&2);
        assert_eq!(recent.walk().step(|_| true), Some(3));
    }

    #[test]
    fn holding_the_modifier_walks_deeper_through_the_history_and_wraps() {
        let mut walk = list(&[1, 2, 3, 4]).walk();
        let visited: Vec<u8> = (0..5).filter_map(|_| walk.step(|_| true)).collect();
        assert_eq!(visited, vec![2, 3, 4, 1, 2]);
    }

    #[test]
    fn a_walk_skips_tabs_that_closed_meanwhile() {
        let mut walk = list(&[1, 2, 3]).walk();
        assert_eq!(walk.step(|tab| *tab != 2), Some(3));
        assert_eq!(walk.step(|tab| *tab != 2), Some(1));
    }

    #[test]
    fn a_walk_over_one_tab_goes_nowhere() {
        assert_eq!(list(&[7]).walk().step(|_| true), None);
        assert_eq!(RecentList::<u8>::default().walk().step(|_| true), None);
    }
}
