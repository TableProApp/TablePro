use std::collections::HashMap;
use std::sync::Arc;

use crate::driver::DatabaseDriver;

#[derive(Default)]
pub struct DriverRegistry {
    drivers: HashMap<&'static str, Arc<dyn DatabaseDriver>>,
}

impl DriverRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, driver: Arc<dyn DatabaseDriver>) {
        self.drivers.insert(driver.id(), driver);
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn DatabaseDriver>> {
        self.drivers.get(id).cloned()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Arc<dyn DatabaseDriver>> {
        self.drivers.values()
    }

    pub fn len(&self) -> usize {
        self.drivers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.drivers.is_empty()
    }
}
