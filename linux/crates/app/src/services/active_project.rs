use std::sync::{Arc, RwLock};

use uuid::Uuid;

// The setting's value where the MCP server's threads can read it: GSettings stays on the GTK thread.
#[derive(Debug, Clone, Default)]
pub struct ActiveProject(Arc<RwLock<Option<Uuid>>>);

impl ActiveProject {
    pub fn get(&self) -> Option<Uuid> {
        match self.0.read() {
            Ok(project) => *project,
            Err(poisoned) => *poisoned.into_inner(),
        }
    }

    pub fn set(&self, project: Option<Uuid>) {
        match self.0.write() {
            Ok(mut held) => *held = project,
            Err(poisoned) => *poisoned.into_inner() = project,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clone_reads_what_the_other_was_given() {
        let active = ActiveProject::default();
        let reader = active.clone();
        let project = Uuid::new_v4();
        assert_eq!(reader.get(), None);

        active.set(Some(project));

        assert_eq!(
            std::thread::spawn(move || reader.get()).join().ok(),
            Some(Some(project))
        );
    }
}
