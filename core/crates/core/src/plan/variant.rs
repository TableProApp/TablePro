/// How an EXPLAIN variant produces its plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExplainStep {
    /// Prepend [`ExplainVariant::sql_prefix`] to the statement and run it as a
    /// normal statement.
    SqlPrefix,
    /// The driver fetches the plan itself. `runs_statement` is true when doing so
    /// executes the user's statement.
    Driver { runs_statement: bool },
}

/// The shape of the text a database returns for an EXPLAIN variant. A string, not a
/// closed enum, so a driver can name a format the app does not parse yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ExplainPlanFormat(pub &'static str);

impl ExplainPlanFormat {
    /// Output with no structured parser; rendered as text.
    pub const PLAIN_TEXT: Self = Self("plainText");
    pub const POSTGRES_JSON: Self = Self("postgresJson");
    pub const MYSQL_COMPOSITE: Self = Self("mysqlComposite");
    pub const SQLITE_QUERY_PLAN: Self = Self("sqliteQueryPlan");
    pub const COCKROACH_TEXT: Self = Self("cockroachText");
    pub const INDENTED_TEXT: Self = Self("indentedText");
    pub const DAMENG_TEXT: Self = Self("damengText");
    pub const ORACLE_PLAN_ROWS: Self = Self("oraclePlanRows");
    pub const SQL_SERVER_SHOWPLAN_XML: Self = Self("sqlServerShowplanXML");

    pub fn as_str(&self) -> &'static str {
        self.0
    }
}

/// One EXPLAIN option an engine offers (EXPLAIN, EXPLAIN ANALYZE, a driver plan).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExplainVariant {
    pub id: &'static str,
    pub label: &'static str,
    /// Prepended to the statement for [`ExplainStep::SqlPrefix`]; empty for a driver step.
    pub sql_prefix: &'static str,
    pub format: ExplainPlanFormat,
    pub step: ExplainStep,
}

impl ExplainVariant {
    /// A variant that prepends `sql_prefix` and runs the result as a statement.
    pub const fn prefix(
        id: &'static str,
        label: &'static str,
        sql_prefix: &'static str,
        format: ExplainPlanFormat,
    ) -> Self {
        Self {
            id,
            label,
            sql_prefix,
            format,
            step: ExplainStep::SqlPrefix,
        }
    }

    /// A variant whose plan the driver fetches itself.
    pub const fn driver(
        id: &'static str,
        label: &'static str,
        format: ExplainPlanFormat,
        runs_statement: bool,
    ) -> Self {
        Self {
            id,
            label,
            sql_prefix: "",
            format,
            step: ExplainStep::Driver { runs_statement },
        }
    }

    /// Whether running this variant executes the user's statement, so it needs the
    /// Safe-Mode / manual-commit gate. A prefix variant runs the statement only when
    /// it carries ANALYZE.
    pub fn runs_statement(&self) -> bool {
        match self.step {
            ExplainStep::SqlPrefix => self.sql_prefix.to_ascii_uppercase().contains("ANALYZE"),
            ExplainStep::Driver { runs_statement } => runs_statement,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_variant_runs_the_statement_only_with_analyze() {
        let explain = ExplainVariant::prefix(
            "e",
            "EXPLAIN",
            "EXPLAIN (FORMAT JSON)",
            ExplainPlanFormat::POSTGRES_JSON,
        );
        let analyze = ExplainVariant::prefix(
            "a",
            "EXPLAIN ANALYZE",
            "EXPLAIN (ANALYZE, FORMAT JSON)",
            ExplainPlanFormat::POSTGRES_JSON,
        );
        assert!(!explain.runs_statement());
        assert!(analyze.runs_statement());
    }

    #[test]
    fn driver_variant_carries_its_own_flag() {
        let variant = ExplainVariant::driver("p", "Plan", ExplainPlanFormat::SQL_SERVER_SHOWPLAN_XML, true);
        assert!(variant.runs_statement());
        assert_eq!(variant.step, ExplainStep::Driver { runs_statement: true });
    }
}
