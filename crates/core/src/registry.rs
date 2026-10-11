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

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;

    use super::*;
    use crate::{ConnectOptions, Connection, DriverError};

    struct TestDriver {
        id: &'static str,
        name: &'static str,
    }

    #[async_trait]
    impl DatabaseDriver for TestDriver {
        fn id(&self) -> &'static str {
            self.id
        }

        fn display_name(&self) -> &'static str {
            self.name
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported(self.id.into()))
        }
    }

    #[test]
    fn an_empty_registry_reports_empty_and_missing_ids() {
        let registry = DriverRegistry::new();

        assert!(registry.is_empty());
        assert_eq!(registry.len(), 0);
        assert!(registry.get("postgres").is_none());
        assert_eq!(registry.iter().count(), 0);
    }

    #[test]
    fn registration_is_retrievable_as_the_same_shared_driver() {
        let mut registry = DriverRegistry::new();
        let driver: Arc<dyn DatabaseDriver> = Arc::new(TestDriver {
            id: "postgres",
            name: "PostgreSQL",
        });

        registry.register(driver.clone());
        let registered = registry.get("postgres").unwrap();

        assert!(Arc::ptr_eq(&driver, &registered));
        assert!(!registry.is_empty());
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn registering_an_existing_id_replaces_it_without_growing_the_registry() {
        let mut registry = DriverRegistry::new();
        registry.register(Arc::new(TestDriver {
            id: "postgres",
            name: "Old PostgreSQL",
        }));
        registry.register(Arc::new(TestDriver {
            id: "postgres",
            name: "PostgreSQL",
        }));
        registry.register(Arc::new(TestDriver {
            id: "sqlite",
            name: "SQLite",
        }));

        assert_eq!(registry.len(), 2);
        assert_eq!(registry.iter().count(), 2);
        assert_eq!(registry.get("postgres").unwrap().display_name(), "PostgreSQL");
        assert_eq!(registry.get("sqlite").unwrap().display_name(), "SQLite");
    }
}
