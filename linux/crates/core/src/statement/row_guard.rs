use super::Statement;

/// How a write proves it touched the rows it meant to.
///
/// A grid edit is built from the row the user was looking at. If the
/// row moved, or another session changed it, the statement can match
/// nothing or everything. The guard is what turns that into a refusal
/// instead of silent damage.
#[derive(Debug, Clone, PartialEq)]
pub enum RowGuard {
    /// Nothing to check: a DDL step, or a write the user asked for by
    /// hand.
    None,
    /// The engine reports affected rows exactly, so the count itself
    /// is the proof.
    AffectedExactly(u64),
    /// The engine's affected-row count is an estimate, so a SELECT
    /// runs first and its count is the proof.
    ProbeExactly { probe: Statement, rows: u64 },
}

impl RowGuard {
    /// Whether the count the engine reported is what was expected.
    /// `None` means the guard does not check counts.
    pub fn accepts_affected(&self, affected: u64) -> Option<bool> {
        match self {
            Self::None => None,
            Self::AffectedExactly(expected) => Some(affected == *expected),
            Self::ProbeExactly { .. } => None,
        }
    }

    pub fn probe(&self) -> Option<(&Statement, u64)> {
        match self {
            Self::ProbeExactly { probe, rows } => Some((probe, *rows)),
            _ => None,
        }
    }
}

/// A write step and the proof it has to produce.
#[derive(Debug, Clone, PartialEq)]
pub struct GuardedStatement {
    pub statement: Statement,
    pub guard: RowGuard,
}

impl GuardedStatement {
    pub fn unguarded(statement: Statement) -> Self {
        Self {
            statement,
            guard: RowGuard::None,
        }
    }

    pub fn affecting_exactly(statement: Statement, rows: u64) -> Self {
        Self {
            statement,
            guard: RowGuard::AffectedExactly(rows),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::StatementBuilder;
    use super::*;

    fn statement(sql: &str) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(sql);
        builder.finish()
    }

    #[test]
    fn an_exact_guard_refuses_any_other_count() {
        let guard = RowGuard::AffectedExactly(1);

        assert_eq!(guard.accepts_affected(1), Some(true));
        assert_eq!(guard.accepts_affected(0), Some(false), "a row that moved was accepted");
        assert_eq!(guard.accepts_affected(2), Some(false), "a broad match was accepted");
    }

    #[test]
    fn a_probe_guard_carries_the_select_that_proves_it() {
        let guard = RowGuard::ProbeExactly {
            probe: statement("SELECT count(*) FROM t WHERE id = 1"),
            rows: 1,
        };

        let (probe, rows) = guard.probe().expect("the probe");
        assert_eq!(rows, 1);
        assert!(probe.sql().starts_with("SELECT count"));
        assert_eq!(guard.accepts_affected(9), None, "a probe guard judged a count");
    }

    #[test]
    fn an_unguarded_step_checks_nothing() {
        let step = GuardedStatement::unguarded(statement("DROP TABLE t"));

        assert_eq!(step.guard, RowGuard::None);
        assert_eq!(step.guard.accepts_affected(0), None);
    }
}
