//! Editor sessions in psql's execution model: the script is split on the
//! client and sent one statement per message, with the transaction
//! status followed statement by statement.

mod actor;
mod cursor_flight;
mod editor_dispatch;
mod editor_session;
mod run;
mod session_core;
mod session_status;
pub(crate) mod statement_class;
mod stop_watch;
mod transaction_tracker;

pub(crate) use editor_session::PgEditorSession;
