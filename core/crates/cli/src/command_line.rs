use std::ffi::OsString;
use std::path::PathBuf;

use clap::{Arg, ArgAction, Args, CommandFactory, FromArgMatches, Parser, Subcommand, ValueEnum, ValueHint};

use crate::output::{ExportFormat, OutputFormat};

pub(crate) const SUBCOMMANDS: [&str; 10] = [
    "open",
    "query",
    "connections",
    "databases",
    "schemas",
    "tables",
    "describe",
    "export",
    "status",
    "completion",
];

const ABOUT: &str = "Open databases in TablePro and work with them from the shell.";

const AFTER_HELP: &str = "Examples:
  tablepro \"postgresql://user@127.0.0.1:5432/app\"
  tablepro schema.sql
  tablepro query -c Staging \"SELECT id, email FROM users LIMIT 5\"
  tablepro query -c Staging -f report.sql --format csv > report.csv

Exit status: 0 done, 1 database or connection error, 2 usage error, 3 refused by a setting, 4 timed out.";

const QUERY_ABOUT: &str = "Run one SQL statement through TablePro and print the rows.

The SQL comes from the argument, from --file, or from standard input. Put SQL that starts with a dash after --:
  tablepro query -c Staging -- \"-- weekly report
  SELECT 1\"

The connection has to be open in TablePro. Run in a terminal, the command opens it and waits; otherwise it stops.

Exit status: 0 done, 1 database or connection error, 2 usage error, 3 refused by a setting, 4 timed out.";

const CONNECTION_HELP: &str = "A saved connection's name or id";
const DATABASE_HELP: &str = "A database TablePro has open beside the connection; the connection's own by default";
const SCHEMA_HELP: &str = "The schema; the connection's default by default";
const FORMAT_HELP: &str = "Output format; table on a terminal, csv otherwise";
const FORMAT_NAME: &str = "FORMAT";

#[derive(Debug, Parser)]
#[command(
    name = "tablepro",
    bin_name = "tablepro",
    about = ABOUT,
    after_help = AFTER_HELP,
    args_conflicts_with_subcommands = true,
    disable_version_flag = true
)]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Option<Command>,
    #[command(flatten)]
    pub(crate) open: OpenArgs,
}

#[derive(Debug, Subcommand)]
pub(crate) enum Command {
    #[command(about = "Open connection URLs and database or SQL files in TablePro")]
    Open(OpenArgs),
    #[command(about = "Run one SQL statement and print the rows", long_about = QUERY_ABOUT)]
    Query(QueryArgs),
    #[command(about = "List the saved connections this command can use")]
    Connections(FormatArgs),
    #[command(about = "List a connection's databases")]
    Databases(DatabasesArgs),
    #[command(about = "List a connection's schemas")]
    Schemas(SchemasArgs),
    #[command(about = "List the tables and views in a schema")]
    Tables(TablesArgs),
    #[command(about = "Show a table's columns, indexes and foreign keys")]
    Describe(DescribeArgs),
    #[command(about = "Export tables as CSV, JSON or SQL INSERT statements")]
    Export(ExportArgs),
    #[command(about = "Show whether this command can reach TablePro")]
    Status(FormatArgs),
    #[command(about = "Print a shell completion script")]
    Completion(CompletionArgs),
}

#[derive(Debug, Args)]
pub(crate) struct OpenArgs {
    #[arg(
        value_name = "URL_OR_FILE",
        value_hint = ValueHint::AnyPath,
        help = "Connection URLs and database or SQL files to open"
    )]
    pub(crate) targets: Vec<OsString>,
    #[arg(short = 'n', long, help = "Open a new window")]
    pub(crate) new_window: bool,
}

#[derive(Debug, Args)]
pub(crate) struct FormatArgs {
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
}

#[derive(Debug, Args)]
pub(crate) struct QueryArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_name = "NAME", help = DATABASE_HELP)]
    pub(crate) database: Option<String>,
    #[arg(
        short = 'f',
        long,
        value_name = "PATH",
        value_hint = ValueHint::FilePath,
        conflicts_with = "sql",
        help = "Read the SQL from a file, or - for standard input"
    )]
    pub(crate) file: Option<PathBuf>,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
    #[arg(long, value_name = "ROWS", help = "Rows to return, 1 to 1000; 100 by default")]
    pub(crate) limit: Option<u32>,
    #[arg(
        long,
        value_name = "SECONDS",
        help = "Seconds the statement may run, 1 to 300; 30 by default"
    )]
    pub(crate) timeout: Option<u32>,
    #[arg(long, help = "Refuse any statement that is not a read")]
    pub(crate) read_only: bool,
    #[arg(value_name = "SQL", help = "The statement to run")]
    pub(crate) sql: Option<String>,
}

#[derive(Debug, Args)]
pub(crate) struct DatabasesArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
}

#[derive(Debug, Args)]
pub(crate) struct SchemasArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_name = "NAME", help = DATABASE_HELP)]
    pub(crate) database: Option<String>,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
}

#[derive(Debug, Args)]
pub(crate) struct TablesArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_name = "NAME", help = DATABASE_HELP)]
    pub(crate) database: Option<String>,
    #[arg(long, value_name = "NAME", help = SCHEMA_HELP)]
    pub(crate) schema: Option<String>,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
}

#[derive(Debug, Args)]
pub(crate) struct DescribeArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_name = "NAME", help = DATABASE_HELP)]
    pub(crate) database: Option<String>,
    #[arg(long, value_name = "NAME", help = SCHEMA_HELP)]
    pub(crate) schema: Option<String>,
    #[arg(long, conflicts_with = "format", help = "Print the CREATE TABLE statement instead")]
    pub(crate) ddl: bool,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = FORMAT_HELP)]
    pub(crate) format: Option<OutputFormat>,
    #[arg(value_name = "TABLE", help = "The table or view, unquoted")]
    pub(crate) table: String,
}

#[derive(Debug, Args)]
pub(crate) struct ExportArgs {
    #[arg(short = 'c', long, value_name = "CONNECTION", help = CONNECTION_HELP)]
    pub(crate) connection: String,
    #[arg(long, value_name = "NAME", help = DATABASE_HELP)]
    pub(crate) database: Option<String>,
    #[arg(long, value_name = "NAME", help = SCHEMA_HELP)]
    pub(crate) schema: Option<String>,
    #[arg(long, value_enum, ignore_case = true, value_name = FORMAT_NAME, help = "Export format")]
    pub(crate) format: ExportFormat,
    #[arg(
        long,
        value_name = "ROWS",
        help = "Rows to export per table, 1 to 1000; 100 by default"
    )]
    pub(crate) limit: Option<u32>,
    #[arg(
        required = true,
        value_name = "TABLE",
        help = "The tables or views to export, unquoted"
    )]
    pub(crate) tables: Vec<String>,
}

#[derive(Debug, Args)]
pub(crate) struct CompletionArgs {
    #[arg(value_enum, help = "The shell to print the script for")]
    pub(crate) shell: Shell,
}

// PowerShell comes with the Windows app, where clap writes it as well.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum Shell {
    Bash,
    Zsh,
    Fish,
}

impl Shell {
    pub(crate) fn generator(self) -> clap_complete::aot::Shell {
        match self {
            Self::Bash => clap_complete::aot::Shell::Bash,
            Self::Zsh => clap_complete::aot::Shell::Zsh,
            Self::Fish => clap_complete::aot::Shell::Fish,
        }
    }
}

// The version is the app's, which only the app knows.
pub(crate) fn command(version: &str) -> clap::Command {
    Cli::command().version(version.to_owned()).arg(
        Arg::new("version")
            .long("version")
            .action(ArgAction::Version)
            .help("Print the version"),
    )
}

pub(crate) fn parse(args: Vec<OsString>, version: &str) -> Result<Cli, clap::Error> {
    let matches = command(version).try_get_matches_from(args)?;
    Cli::from_arg_matches(&matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(args: &[&str]) -> Result<Cli, clap::Error> {
        parse(args.iter().map(OsString::from).collect(), "1.2.3")
    }

    #[test]
    fn the_command_line_is_well_formed() {
        command("1.2.3").debug_assert();
    }

    #[test]
    fn every_listed_subcommand_exists() {
        let command = command("1.2.3");
        let names: Vec<&str> = command
            .get_subcommands()
            .map(clap::Command::get_name)
            .filter(|&name| name != "help")
            .collect();

        assert_eq!(names, SUBCOMMANDS);
    }

    #[test]
    fn a_word_that_is_no_command_is_a_target() {
        let cli = parsed(&["tablepro", "app.db", "postgresql://h/db"]).expect("parsed");

        assert!(cli.command.is_none());
        assert_eq!(
            cli.open.targets,
            vec![OsString::from("app.db"), OsString::from("postgresql://h/db")]
        );
    }

    #[test]
    fn the_format_reads_in_any_case() {
        let cli = parsed(&["tablepro", "query", "-c", "Staging", "--format", "JSON", "SELECT 1"]).expect("parsed");

        let Some(Command::Query(query)) = cli.command else {
            unreachable!("query parses as query");
        };
        assert_eq!(query.format, Some(OutputFormat::Json));
        assert_eq!(query.sql.as_deref(), Some("SELECT 1"));
    }

    #[test]
    fn sql_that_starts_with_a_dash_goes_after_the_terminator() {
        let refused = parsed(&["tablepro", "query", "-c", "Staging", "-- note\nSELECT 1"]);
        let accepted = parsed(&["tablepro", "query", "-c", "Staging", "--", "-- note\nSELECT 1"]).expect("parsed");

        assert!(refused.is_err());
        let Some(Command::Query(query)) = accepted.command else {
            unreachable!("query parses as query");
        };
        assert_eq!(query.sql.as_deref(), Some("-- note\nSELECT 1"));
    }

    #[test]
    fn usage_errors_exit_two() {
        let cases: [&[&str]; 9] = [
            &["tablepro", "query", "SELECT 1"],
            &["tablepro", "query", "-c", "S", "--format", "xml", "SELECT 1"],
            &["tablepro", "query", "-c", "S", "-f", "a.sql", "SELECT 1"],
            &["tablepro", "query", "-c", "S", "--bogus", "SELECT 1"],
            &["tablepro", "describe", "-c", "S", "--ddl", "--format", "json", "orders"],
            &["tablepro", "export", "-c", "S", "orders"],
            &["tablepro", "export", "-c", "S", "--format", "xlsx", "orders"],
            &["tablepro", "completion", "powershell"],
            &["tablepro", "help", "nosuch"],
        ];

        for args in cases {
            let error = parsed(args).err();
            assert_eq!(error.map(|error| error.exit_code()), Some(2), "{args:?}");
        }
    }

    #[test]
    fn help_and_version_print_to_standard_output() {
        for args in [
            &["tablepro", "--help"][..],
            &["tablepro", "-h"],
            &["tablepro", "help", "query"],
            &["tablepro", "query", "--help"],
            &["tablepro", "open", "--help"],
            &["tablepro", "--version"],
        ] {
            let error = parsed(args).err();
            assert_eq!(error.as_ref().map(clap::Error::use_stderr), Some(false), "{args:?}");
            assert_eq!(error.map(|error| error.exit_code()), Some(0), "{args:?}");
        }
    }

    #[test]
    fn the_version_is_the_apps() {
        let error = parsed(&["tablepro", "--version"])
            .err()
            .map(|error| error.render().to_string());

        assert_eq!(error.as_deref(), Some("tablepro 1.2.3\n"));
    }
}
