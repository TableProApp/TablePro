use std::collections::HashMap;

use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReadScope {
    Page,
    Count,
    Columns,
    ForeignKeys,
    Structure,
}

#[derive(Debug, Default)]
pub struct ReadScopes {
    tokens: HashMap<(Uuid, ReadScope), CancellationToken>,
}

impl ReadScopes {
    pub fn start(&mut self, tab: Uuid, scope: ReadScope) -> CancellationToken {
        let token = CancellationToken::new();
        if let Some(previous) = self.tokens.insert((tab, scope), token.clone()) {
            previous.cancel();
        }
        token
    }

    pub fn cancel_tab(&mut self, tab: Uuid) {
        self.tokens.retain(|(owner, _), token| {
            let keep = *owner != tab;
            if !keep {
                token.cancel();
            }
            keep
        });
    }

    pub fn cancel_all(&mut self) {
        for token in self.tokens.drain().map(|(_, token)| token) {
            token.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_newer_read_of_the_same_kind_cancels_the_older_one() {
        let mut scopes = ReadScopes::default();
        let tab = Uuid::new_v4();
        let first = scopes.start(tab, ReadScope::Page);
        let second = scopes.start(tab, ReadScope::Page);
        assert!(first.is_cancelled());
        assert!(!second.is_cancelled());
    }

    #[test]
    fn reads_of_other_kinds_or_tabs_are_left_running() {
        let mut scopes = ReadScopes::default();
        let tab = Uuid::new_v4();
        let page = scopes.start(tab, ReadScope::Page);
        let count = scopes.start(tab, ReadScope::Count);
        let other_tab = scopes.start(Uuid::new_v4(), ReadScope::Page);
        scopes.start(tab, ReadScope::Page);
        assert!(!count.is_cancelled());
        assert!(!other_tab.is_cancelled());
        assert!(page.is_cancelled());
    }

    #[test]
    fn closing_a_tab_cancels_every_read_it_owns_and_only_those() {
        let mut scopes = ReadScopes::default();
        let tab = Uuid::new_v4();
        let page = scopes.start(tab, ReadScope::Page);
        let columns = scopes.start(tab, ReadScope::Columns);
        let other = scopes.start(Uuid::new_v4(), ReadScope::Page);
        scopes.cancel_tab(tab);
        assert!(page.is_cancelled() && columns.is_cancelled());
        assert!(!other.is_cancelled());
    }

    #[test]
    fn disconnecting_cancels_everything() {
        let mut scopes = ReadScopes::default();
        let tokens: Vec<_> = (0..3)
            .map(|_| scopes.start(Uuid::new_v4(), ReadScope::Structure))
            .collect();
        scopes.cancel_all();
        assert!(tokens.iter().all(CancellationToken::is_cancelled));
    }
}
