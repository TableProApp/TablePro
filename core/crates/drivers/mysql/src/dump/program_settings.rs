use tablepro_core::dump::DumpStatement;

/// What a view, routine or trigger was made under, which its CREATE runs
/// under again, as mysqldump writes it, so the server reads the text as
/// it did then.
///
/// `character_set_client` is not switched: mysqldump writes the stored
/// bytes as they are (`character_set_results=binary`), while this file
/// is UTF-8, which only the header's `SET NAMES utf8mb4` reads right.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ProgramSettings {
    /// `None` for a view, which keeps no mode.
    pub sql_mode: Option<String>,
    pub collation_connection: Option<String>,
}

impl ProgramSettings {
    /// The statements that save the session's settings, set the
    /// object's, run `create`, and set the session's back.
    pub(crate) fn around(&self, create: DumpStatement) -> Vec<DumpStatement> {
        let mut before = Vec::new();
        let mut after = Vec::new();
        if let Some(collation) = &self.collation_connection {
            before.push("SET @saved_col_connection = @@collation_connection".to_owned());
            before.push(format!("SET collation_connection = {}", quoted(collation)));
            after.push("SET collation_connection = @saved_col_connection".to_owned());
        }
        if let Some(mode) = &self.sql_mode {
            before.push("SET @saved_sql_mode = @@sql_mode".to_owned());
            before.push(format!("SET sql_mode = {}", quoted(mode)));
            after.insert(0, "SET sql_mode = @saved_sql_mode".to_owned());
        }
        before
            .into_iter()
            .map(DumpStatement::new)
            .chain(std::iter::once(create))
            .chain(after.into_iter().map(DumpStatement::new))
            .collect()
    }
}

/// A setting's value as a string, which reads the same whatever mode
/// the session is in: neither a mode list nor a collation name holds a
/// backslash.
fn quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(statements: &[DumpStatement]) -> Vec<(&str, bool)> {
        statements
            .iter()
            .map(|statement| (statement.sql.as_str(), statement.body))
            .collect()
    }

    #[test]
    fn a_routine_runs_under_its_own_mode_and_collation_then_the_sessions() {
        let settings = ProgramSettings {
            sql_mode: Some("STRICT_TRANS_TABLES,NO_ZERO_DATE".to_owned()),
            collation_connection: Some("utf8mb4_0900_ai_ci".to_owned()),
        };

        let statements = settings.around(DumpStatement::body("CREATE PROCEDURE `p`()\nBEGIN SELECT 1; END"));

        assert_eq!(
            texts(&statements),
            [
                ("SET @saved_col_connection = @@collation_connection", false),
                ("SET collation_connection = 'utf8mb4_0900_ai_ci'", false),
                ("SET @saved_sql_mode = @@sql_mode", false),
                ("SET sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE'", false),
                ("CREATE PROCEDURE `p`()\nBEGIN SELECT 1; END", true),
                ("SET sql_mode = @saved_sql_mode", false),
                ("SET collation_connection = @saved_col_connection", false),
            ]
        );
    }

    #[test]
    fn a_view_keeps_the_sessions_mode_and_an_empty_mode_is_still_set() {
        let view = ProgramSettings {
            sql_mode: None,
            collation_connection: Some("latin1_swedish_ci".to_owned()),
        };
        let unmoded = ProgramSettings {
            sql_mode: Some(String::new()),
            collation_connection: None,
        };

        assert_eq!(
            texts(&view.around(DumpStatement::new("CREATE VIEW `v` AS select 1 AS `1`"))),
            [
                ("SET @saved_col_connection = @@collation_connection", false),
                ("SET collation_connection = 'latin1_swedish_ci'", false),
                ("CREATE VIEW `v` AS select 1 AS `1`", false),
                ("SET collation_connection = @saved_col_connection", false),
            ]
        );
        assert_eq!(
            texts(&unmoded.around(DumpStatement::body(
                "CREATE TRIGGER `t` BEFORE INSERT ON `c` FOR EACH ROW SET @n = 1"
            ))),
            [
                ("SET @saved_sql_mode = @@sql_mode", false),
                ("SET sql_mode = ''", false),
                ("CREATE TRIGGER `t` BEFORE INSERT ON `c` FOR EACH ROW SET @n = 1", true),
                ("SET sql_mode = @saved_sql_mode", false),
            ]
        );
    }
}
