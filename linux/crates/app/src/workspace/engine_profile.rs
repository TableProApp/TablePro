use tablepro_core::{DriverRegistry, WriteAtomicity};

/// What a structure review says about the engine the workspace's
/// session runs on. A workspace never changes session, so this is read
/// once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineProfile {
    pub name: String,
    pub ddl_writes: WriteAtomicity,
}

impl EngineProfile {
    /// A driver the registry does not know is taken to apply each
    /// statement on its own, so every save of more than one statement
    /// asks first.
    pub fn of(drivers: &DriverRegistry, driver_id: &str) -> Self {
        match drivers.get(driver_id) {
            Some(driver) => Self {
                name: driver.display_name().to_owned(),
                ddl_writes: driver.capabilities().ddl_writes,
            },
            None => Self {
                name: driver_id.to_owned(),
                ddl_writes: WriteAtomicity::StatementByStatement,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    #[test]
    fn an_engine_comes_from_its_driver_and_an_unknown_one_asks() {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(drivers_mysql::MysqlDriver));

        assert_eq!(
            EngineProfile::of(&drivers, "mysql"),
            EngineProfile {
                name: "MySQL".to_owned(),
                ddl_writes: WriteAtomicity::StatementByStatement,
            }
        );
        assert_eq!(
            EngineProfile::of(&drivers, "gone").ddl_writes,
            WriteAtomicity::StatementByStatement
        );
    }
}
