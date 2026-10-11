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
    pub(super) fn start_new(&mut self) -> u64 {
        self.next = self.next.wrapping_add(1);
        self.current = Some(self.next);
        self.active.insert(self.next);
        self.next
    }

    pub(super) fn accepts(&self, generation: u64) -> bool {
        self.current == Some(generation)
    }

    pub(super) fn finish(&mut self, generation: u64) -> Option<RunTerminal> {
        if !self.active.remove(&generation) {
            return None;
        }
        Some(RunTerminal {
            replace_ui: self.accepts(generation),
            became_idle: self.active.is_empty(),
        })
    }
}
