use std::io::Read;
use std::path::Path;

use crate::command_error::CommandError;
use crate::command_line::QueryArgs;
use crate::host::Terminal;

const BYTE_ORDER_MARK: char = '\u{feff}';

pub(super) fn read(arguments: &QueryArgs, terminal: Terminal) -> Result<String, CommandError> {
    let text = match source(arguments, terminal)? {
        Source::Argument(text) => text.to_owned(),
        Source::File(path) => read_file(path)?,
        Source::StandardInput => read_standard_input()?,
    };
    let text = text.strip_prefix(BYTE_ORDER_MARK).map(str::to_owned).unwrap_or(text);
    if text.trim().is_empty() {
        return Err(CommandError::Usage("The SQL is empty.".to_owned()));
    }
    Ok(text)
}

#[derive(Debug, PartialEq, Eq)]
enum Source<'a> {
    Argument(&'a str),
    File(&'a Path),
    StandardInput,
}

fn source(arguments: &QueryArgs, terminal: Terminal) -> Result<Source<'_>, CommandError> {
    match (&arguments.sql, &arguments.file) {
        (Some(text), _) => Ok(Source::Argument(text)),
        // An explicit - asks for standard input, so a terminal is read too, until end of file.
        (None, Some(path)) if path.as_os_str() == "-" => Ok(Source::StandardInput),
        (None, Some(path)) => Ok(Source::File(path)),
        (None, None) if terminal.stdin => Err(CommandError::Usage(
            "Pass the SQL as an argument, with --file, or on standard input.".to_owned(),
        )),
        (None, None) => Ok(Source::StandardInput),
    }
}

fn read_file(path: &Path) -> Result<String, CommandError> {
    let bytes =
        std::fs::read(path).map_err(|error| CommandError::Usage(format!("Cannot read {}: {error}", path.display())))?;
    String::from_utf8(bytes).map_err(|_| CommandError::Usage(format!("{} is not UTF-8 text.", path.display())))
}

fn read_standard_input() -> Result<String, CommandError> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .read_to_end(&mut bytes)
        .map_err(|error| CommandError::Usage(format!("Cannot read standard input: {error}")))?;
    String::from_utf8(bytes).map_err(|_| CommandError::Usage("Standard input is not UTF-8 text.".to_owned()))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn query(sql: Option<&str>, file: Option<&str>) -> QueryArgs {
        QueryArgs {
            connection: "Staging".to_owned(),
            database: None,
            file: file.map(PathBuf::from),
            format: None,
            limit: None,
            timeout: None,
            read_only: false,
            sql: sql.map(str::to_owned),
        }
    }

    fn terminal(stdin: bool) -> Terminal {
        Terminal {
            stdin,
            ..Terminal::default()
        }
    }

    #[test]
    fn a_dash_reads_standard_input_even_from_a_terminal() {
        let arguments = query(None, Some("-"));

        assert_eq!(source(&arguments, terminal(true)).ok(), Some(Source::StandardInput));
    }

    #[test]
    fn no_sql_reads_a_pipe_but_not_a_terminal() {
        let arguments = query(None, None);

        assert_eq!(source(&arguments, terminal(false)).ok(), Some(Source::StandardInput));
        assert!(matches!(
            source(&arguments, terminal(true)),
            Err(CommandError::Usage(_))
        ));
    }

    #[test]
    fn a_file_is_read_without_its_byte_order_mark() {
        let dir = tempfile::tempdir().expect("a directory");
        let file = dir.path().join("report.sql");
        std::fs::write(&file, "\u{feff}SELECT 1").expect("a file");
        let arguments = query(None, file.to_str());

        assert_eq!(read(&arguments, terminal(true)).ok().as_deref(), Some("SELECT 1"));
    }

    #[test]
    fn empty_sql_or_a_missing_file_is_a_usage_error() {
        for arguments in [query(Some("  \n"), None), query(None, Some("/nonexistent/report.sql"))] {
            assert!(matches!(read(&arguments, terminal(true)), Err(CommandError::Usage(_))));
        }
    }
}
