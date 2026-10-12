use tablepro_core::browse::BrowseSqlError;
use tablepro_core::dml::BuildSqlError;
use tablepro_core::statement::SqlBuildError;
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{ConnectError, OperationError};
use tablepro_storage::KeyringError;

use super::driver::driver_message;
use super::secret::secret_message;

/// What to tell the user about an operation that produced no value.
pub fn operation_error_message(error: &OperationError) -> String {
    match error {
        OperationError::Driver(error) => driver_message(error),
        OperationError::Sql(error) => sql_build_message(error),
        OperationError::Browse(error) => browse_message(error),
        OperationError::Build(error) => build_message(error),
        OperationError::Panicked(panic) => crate::i18n::gettext_f(
            "TablePro hit an internal error: {detail}",
            &[("detail", panic.message())],
        ),
        OperationError::Cancelled => crate::i18n::gettext("Stopped."),
        OperationError::Closed => crate::i18n::gettext("The connection is closed."),
    }
}

/// What to tell the user about a connect that produced no session.
pub fn connect_error_message(error: &ConnectError) -> String {
    match error {
        ConnectError::Driver(error) => driver_message(error),
        ConnectError::Keyring(KeyringError::SecretNotStored { .. }) => crate::i18n::gettext(
            "No password is saved for this connection, and none was entered. Connect again to type it.",
        ),
        ConnectError::Keyring(KeyringError::Secret { error, .. }) => secret_message(error),
        ConnectError::UnknownDriver(driver) => crate::i18n::gettext_f(
            "This build of TablePro has no {driver} driver.",
            &[("driver", driver)],
        ),
        ConnectError::Cancelled => crate::i18n::gettext("The connection was cancelled."),
        ConnectError::Panicked(panic) => crate::i18n::gettext_f(
            "TablePro hit an internal error: {detail}",
            &[("detail", panic.message())],
        ),
    }
}

/// What to tell the user when the work itself died rather than failed.
pub fn task_failure_message(failure: &TaskFailure) -> String {
    match failure {
        TaskFailure::Panicked(panic) => crate::i18n::gettext_f(
            "TablePro hit an internal error: {detail}",
            &[("detail", panic.message())],
        ),
        TaskFailure::Aborted => crate::i18n::gettext("Stopped."),
    }
}

fn sql_build_message(error: &SqlBuildError) -> String {
    match error {
        SqlBuildError::Dml(bind) => crate::i18n::gettext_f(
            "This change cannot be saved: {reason}",
            &[("reason", &bind.to_string())],
        ),
        SqlBuildError::Browse(bind) => crate::i18n::gettext_f(
            "This filter cannot be applied: {reason}",
            &[("reason", &bind.to_string())],
        ),
        SqlBuildError::Ddl(reason) => {
            crate::i18n::gettext_f("This structure change cannot be written: {reason}", &[("reason", reason)])
        }
    }
}

fn browse_message(error: &BrowseSqlError) -> String {
    match error {
        BrowseSqlError::Filter(filter) => crate::i18n::gettext_f(
            "This filter cannot be applied: {reason}",
            &[("reason", &filter.to_string())],
        ),
        BrowseSqlError::Build(build) => build_message(build),
        other => crate::i18n::gettext_f(
            "This page of the table cannot be read: {reason}",
            &[("reason", &other.to_string())],
        ),
    }
}

fn build_message(error: &BuildSqlError) -> String {
    match error {
        BuildSqlError::NoRowIdentity | BuildSqlError::ReadOnlyRows => crate::i18n::gettext(
            "Rows in this table cannot be edited, because nothing identifies a single row. Add a primary key to edit them.",
        ),
        BuildSqlError::NothingToUpdate | BuildSqlError::NoInsertValues => {
            crate::i18n::gettext("No changes to save.")
        }
        BuildSqlError::UndecodableKey => crate::i18n::gettext(
            "Part of this row's key could not be read from the server, so the row cannot be changed.",
        ),
        other => crate::i18n::gettext_f(
            "This change cannot be saved: {reason}",
            &[("reason", &other.to_string())],
        ),
    }
}
