use tablepro_core::dump::DumpError;
use tablepro_core::import::{SqlFileError, SqlImportFault};
use tablepro_core::sql_syntax::script::{RefusedUnit, ScriptReadError};

use super::driver::driver_message;
use super::statement::browse_reason;
use crate::i18n::{gettext, gettext_f};

/// Why a database export stopped reading the database.
pub fn dump_error_message(error: &DumpError) -> String {
    match error {
        DumpError::Driver(error) => driver_message(error),
        DumpError::Read(error) => gettext_f(
            "A table cannot be read: {reason}.",
            &[("reason", &browse_reason(error))],
        ),
        DumpError::OutputClosed => gettext("The file stopped taking data."),
    }
}

/// Why a SQL file could not be read on.
pub fn sql_file_message(error: &SqlFileError) -> String {
    match error {
        SqlFileError::Read(detail) => gettext_f("The file cannot be read: {detail}", &[("detail", detail)]),
        SqlFileError::NotUtf8 { line } => gettext_f(
            "Line {line} is not UTF-8 text. A dump with binary values has to write them as hex, as mysqldump does with --hex-blob.",
            &[("line", &line.to_string())],
        ),
        SqlFileError::Script(ScriptReadError::TooLong { line }) => gettext_f(
            "The statement starting on line {line} is longer than 128 MB.",
            &[("line", &line.to_string())],
        ),
    }
}

/// Why one statement of a SQL file did not run.
pub fn sql_import_fault_message(fault: &SqlImportFault) -> String {
    match fault {
        SqlImportFault::Statement(error) => driver_message(error),
        SqlImportFault::Refused(RefusedUnit::ClientCommand { command }) => gettext_f(
            "{command} is a psql command, which only psql runs.",
            &[("command", command)],
        ),
        SqlImportFault::Refused(RefusedUnit::CopyFormat) => {
            gettext("Only COPY data in the text format pg_dump writes can be imported, with no options.")
        }
        SqlImportFault::Refused(RefusedUnit::CopyNotText) => gettext("This COPY row is not UTF-8 text."),
        SqlImportFault::FileEndsTransaction => gettext(
            "The file ends its own transaction, which would end the one the import runs it in. Turn off Run as One Transaction to run it as written.",
        ),
    }
}
