use crate::statement::Statement;
use crate::user_sql::UserSql;

/// What a streamed read runs.
///
/// Generated SQL arrives with its parameters already bound, and the
/// user's own SQL arrives as typed, so a driver never has to guess
/// which one it was handed.
#[derive(Debug, Clone, PartialEq)]
pub enum ReadStatement {
    Generated(Statement),
    User(UserSql),
}
