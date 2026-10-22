#[derive(Debug, Default)]
pub(super) struct RunGeneration {
    next: u64,
    current: Option<u64>,
    pub(super) active: std::collections::HashSet<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct RunTerminal {
    pub(super) replace_ui: bool,
    pub(super) became_idle: bool,
}

impl RunGeneration {
    pub(super) fn try_start_new(&mut self) -> Option<u64> {
        if !self.active.is_empty() {
            return None;
        }
        Some(self.start_new())
    }

    pub(super) fn start_new(&mut self) -> u64 {
        self.next = self.next.wrapping_add(1);
        self.current = Some(self.next);
        self.active.insert(self.next);
        self.next
    }

    pub(super) fn is_current(&self, generation: u64) -> bool {
        self.current == Some(generation)
    }

    pub(super) fn accepts(&self, generation: u64) -> bool {
        self.current == Some(generation) && self.active.contains(&generation)
    }

    pub(super) fn finish(&mut self, generation: u64) -> Option<RunTerminal> {
        if !self.active.contains(&generation) {
            return None;
        }
        let replace_ui = self.accepts(generation);
        self.active.remove(&generation);
        Some(RunTerminal {
            replace_ui,
            became_idle: self.active.is_empty(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_active_run_refuses_new_execution_until_its_terminal_outcome() {
        let mut generations = RunGeneration::default();
        for _ in 0..3 {
            let running = generations.try_start_new().unwrap();
            assert!(generations.try_start_new().is_none());
            assert!(generations.accepts(running));
            assert_eq!(generations.active.len(), 1);
            let terminal = generations.finish(running).unwrap();
            assert!(terminal.replace_ui);
            assert!(terminal.became_idle);
        }
    }
}
