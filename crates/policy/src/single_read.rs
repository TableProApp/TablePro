use crate::classify::{StatementClass, StatementFacts};
use crate::effects::Effects;

impl StatementFacts {
    pub fn is_single_read(&self) -> bool {
        let external = Effects::SESSION_STATE
            .union(Effects::HOST_OR_FILE_ACCESS)
            .union(Effects::ADMIN);
        !self.is_multi_statement
            && self.class == StatementClass::Select
            && !self.effects.writes()
            && !self.effects.intersects(external)
    }
}
