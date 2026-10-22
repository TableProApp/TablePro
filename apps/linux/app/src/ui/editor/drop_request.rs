#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DropRequest {
    generation: u64,
    revision: u64,
}

#[derive(Debug, Default)]
pub(super) struct DropGeneration {
    generation: std::cell::Cell<u64>,
    revision: std::cell::Cell<u64>,
}

impl DropGeneration {
    pub(super) fn changed(&self) {
        self.revision.set(self.revision.get().wrapping_add(1));
    }

    pub(super) fn begin(&self) -> DropRequest {
        let generation = self.generation.get().wrapping_add(1);
        self.generation.set(generation);
        DropRequest {
            generation,
            revision: self.revision.get(),
        }
    }

    pub(super) fn accepts(&self, request: DropRequest) -> bool {
        self.generation.get() == request.generation && self.revision.get() == request.revision
    }
}
