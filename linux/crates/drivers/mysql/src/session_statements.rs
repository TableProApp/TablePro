use std::time::Duration;

use tablepro_core::WorkspaceSettings;

use crate::flavour::MySqlFlavour;

/// The bounds a session runs under, set once when it opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SessionLimits {
    pub read_only: bool,
    /// `None` keeps the server's own default, which is no limit.
    pub statement_timeout: Option<Duration>,
    pub lock_timeout: Duration,
}

impl SessionLimits {
    pub(crate) fn workspace(settings: &WorkspaceSettings) -> Self {
        Self {
            read_only: settings.read_only,
            statement_timeout: Some(settings.statement_timeout),
            lock_timeout: settings.lock_timeout,
        }
    }
}

/// What a new session sends before anything else.
///
/// `SET NAMES utf8mb4` comes first and names no collation, so the server
/// picks the charset's default: MySQL's `default_collation_for_utf8mb4`
/// and MariaDB's `character_set_collations`, which is what the mysql
/// client gets too. Every number is rendered as an integer, because a
/// float a server reads in a different locale is not one.
pub(crate) fn for_session(flavour: MySqlFlavour, limits: &SessionLimits) -> Vec<String> {
    let mut statements = vec!["SET NAMES utf8mb4".to_owned()];
    if limits.read_only {
        statements.push("SET SESSION TRANSACTION READ ONLY".to_owned());
    }
    if let Some(timeout) = limits.statement_timeout {
        statements.push(statement_timeout(flavour, Some(timeout)));
    }
    let lock = whole_seconds(limits.lock_timeout);
    statements.push(format!("SET SESSION lock_wait_timeout = {lock}"));
    statements.push(format!("SET SESSION innodb_lock_wait_timeout = {lock}"));
    statements
}

/// The session's statement bound, or the server's "no limit" for
/// `None`. MySQL bounds only read-only SELECTs, in milliseconds; MariaDB
/// bounds every statement, in seconds.
pub(crate) fn statement_timeout(flavour: MySqlFlavour, timeout: Option<Duration>) -> String {
    match flavour {
        MySqlFlavour::MySql => format!(
            "SET SESSION max_execution_time = {}",
            timeout.map_or(0, |timeout| timeout.as_millis().max(1))
        ),
        MySqlFlavour::MariaDb => format!("SET SESSION max_statement_time = {}", timeout.map_or(0, whole_seconds)),
    }
}

/// Seconds rounded up, at least one: the lock and MariaDB statement
/// bounds take whole seconds, and zero would lift MariaDB's.
pub(crate) fn whole_seconds(duration: Duration) -> u64 {
    let rounded = duration.as_secs() + u64::from(duration.subsec_nanos() > 0);
    rounded.max(1)
}

/// The editor's row limit as the server applies it. One row past the
/// limit is asked for, so a result cut by the server is told apart from
/// one that ended exactly at the limit.
pub(crate) fn select_limit(rows: u64) -> String {
    format!("SET SESSION sql_select_limit = {}", rows.saturating_add(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mysql_and_mariadb_text() {
        let limits = SessionLimits {
            read_only: true,
            statement_timeout: Some(Duration::from_millis(1_500)),
            lock_timeout: Duration::from_secs(10),
        };

        assert_eq!(
            for_session(MySqlFlavour::MySql, &limits),
            [
                "SET NAMES utf8mb4",
                "SET SESSION TRANSACTION READ ONLY",
                "SET SESSION max_execution_time = 1500",
                "SET SESSION lock_wait_timeout = 10",
                "SET SESSION innodb_lock_wait_timeout = 10",
            ]
        );
        assert_eq!(
            for_session(MySqlFlavour::MariaDb, &limits),
            [
                "SET NAMES utf8mb4",
                "SET SESSION TRANSACTION READ ONLY",
                "SET SESSION max_statement_time = 2",
                "SET SESSION lock_wait_timeout = 10",
                "SET SESSION innodb_lock_wait_timeout = 10",
            ]
        );

        let editor = SessionLimits {
            read_only: false,
            statement_timeout: None,
            lock_timeout: Duration::from_millis(300),
        };
        let statements = for_session(MySqlFlavour::MySql, &editor);
        assert_eq!(statements.first().map(String::as_str), Some("SET NAMES utf8mb4"));
        assert!(!statements.iter().any(|sql| sql.contains("max_execution_time")));
        assert!(statements.contains(&"SET SESSION lock_wait_timeout = 1".to_owned()));
        for sql in statements {
            assert!(!sql.contains('.'), "{sql}");
        }
    }

    #[test]
    fn a_lifted_bound_is_the_servers_zero() {
        assert_eq!(
            statement_timeout(MySqlFlavour::MariaDb, None),
            "SET SESSION max_statement_time = 0"
        );
        assert_eq!(
            statement_timeout(MySqlFlavour::MySql, Some(Duration::from_micros(10))),
            "SET SESSION max_execution_time = 1"
        );
        assert_eq!(select_limit(100), "SET SESSION sql_select_limit = 101");
        assert_eq!(
            select_limit(u64::MAX),
            "SET SESSION sql_select_limit = 18446744073709551615"
        );
    }
}
