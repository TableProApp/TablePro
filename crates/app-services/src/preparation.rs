use std::collections::{HashMap, HashSet};
use std::hash::Hash;

#[derive(Debug, PartialEq, Eq)]
pub enum PreparationStatus {
    Ready,
    Pending,
    Started(u64),
}

pub struct Preparation<T> {
    generation: u64,
    pending: HashMap<T, u64>,
    ready: HashSet<T>,
}

impl<T> Default for Preparation<T> {
    fn default() -> Self {
        Self {
            generation: 0,
            pending: HashMap::new(),
            ready: HashSet::new(),
        }
    }
}

impl<T: Clone + Eq + Hash> Preparation<T> {
    pub fn request(&mut self, action: T) -> PreparationStatus {
        if self.ready.remove(&action) {
            return PreparationStatus::Ready;
        }
        if self.pending.contains_key(&action) {
            return PreparationStatus::Pending;
        }
        self.generation = self.generation.wrapping_add(1);
        self.pending.insert(action, self.generation);
        PreparationStatus::Started(self.generation)
    }

    pub fn complete(&mut self, action: T, ticket: u64, accepted: bool) -> bool {
        if self.pending.get(&action) != Some(&ticket) {
            return false;
        }
        self.pending.remove(&action);
        if accepted {
            self.ready.insert(action);
        }
        true
    }

    pub fn invalidate(&mut self, action: T) {
        self.pending.remove(&action);
        self.ready.remove(&action);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn begin(state: &mut Preparation<u8>, action: u8) -> u64 {
        let PreparationStatus::Started(ticket) = state.request(action) else {
            panic!("a fresh action must start")
        };
        ticket
    }

    #[test]
    fn repeated_requests_wait_for_the_original_preparation() {
        let mut state = Preparation::default();
        let ticket = begin(&mut state, 1);
        assert_eq!(state.request(1), PreparationStatus::Pending);
        assert!(state.complete(1, ticket, true));
        assert_eq!(state.request(1), PreparationStatus::Ready);
        assert!(matches!(state.request(1), PreparationStatus::Started(_)));
    }

    #[test]
    fn bulk_actions_can_prepare_each_target_independently() {
        let mut state = Preparation::default();
        let first = begin(&mut state, 1);
        let second = begin(&mut state, 2);
        assert!(state.complete(2, second, true));
        assert_eq!(state.request(2), PreparationStatus::Ready);
        assert_eq!(state.request(1), PreparationStatus::Pending);
        assert!(state.complete(1, first, true));
        assert_eq!(state.request(1), PreparationStatus::Ready);
    }

    #[test]
    fn a_refused_preparation_allows_a_new_attempt() {
        let mut state = Preparation::default();
        let ticket = begin(&mut state, 1);
        assert!(state.complete(1, ticket, false));
        assert!(matches!(state.request(1), PreparationStatus::Started(_)));
        assert!(!state.complete(1, ticket, true));
    }

    #[test]
    fn an_old_completion_cannot_prepare_a_replacement_owner() {
        let mut state = Preparation::default();
        let old = begin(&mut state, 1);
        state.invalidate(1);
        let current = begin(&mut state, 1);
        assert!(!state.complete(1, old, true));
        assert_eq!(state.request(1), PreparationStatus::Pending);
        assert!(state.complete(1, current, true));
        assert_eq!(state.request(1), PreparationStatus::Ready);
    }

    #[test]
    fn a_duplicate_completion_cannot_authorize_another_action() {
        let mut state = Preparation::default();
        let ticket = begin(&mut state, 1);
        assert!(state.complete(1, ticket, true));
        assert_eq!(state.request(1), PreparationStatus::Ready);
        assert!(!state.complete(1, ticket, true));
        assert!(matches!(state.request(1), PreparationStatus::Started(_)));
    }
}
