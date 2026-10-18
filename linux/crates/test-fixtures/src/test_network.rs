use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestNetwork {
    name: String,
}

impl TestNetwork {
    pub fn new() -> Self {
        Self {
            name: format!("tablepro-test-{}", Uuid::new_v4().simple()),
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn container_name(&self, role: &str) -> String {
        format!("{}-{role}", self.name)
    }
}

impl Default for TestNetwork {
    fn default() -> Self {
        Self::new()
    }
}
