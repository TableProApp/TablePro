use std::fmt;

/// What an engine cannot do, as a value the app turns into its own
/// sentence. A driver names one of these rather than writing the
/// feature in English. Closed, so a new one needs its sentence in the
/// app before it builds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnsupportedFeature {
    /// A file path, for an engine reached over the network.
    DatabaseFile,
    /// A host and port, for an engine that opens a file.
    NetworkConnection,
    /// A save that turns foreign key checks off and verifies them after.
    ForeignKeySuspension,
    /// The engine's client library or server is older than the driver
    /// needs, such as `SQLite 3.43.0` or `PostgreSQL 10`.
    MinimumVersion {
        required: &'static str,
    },
    CopyFromStdinInEditor,
    CopyToStdoutInEditor,
    /// The rows of a `COPY ... FROM STDIN`, on a session that cannot send
    /// them.
    CopyFromStdin,
    /// A TIMESTAMP in the hour the session time zone repeats, which the
    /// server cannot store as the one instant it was given.
    TimestampInRepeatedHour,
    TimeOutsideOneDay,
    TimeWithOffset,
    Interval,
    BitString,
    NumberWiderThan {
        digits: u32,
    },
    /// A decimal that is NaN or infinite, or wider than `digits`.
    DecimalOutOfRange {
        digits: u32,
    },
    DateOutsideYears {
        first: i32,
        last: i32,
    },
    /// A DuckDB `ATTACH ... (HIDDEN)`, a database DuckDB lists nowhere.
    HiddenAttach,
    /// Pages the server keeps itself, by a paging state.
    ServerPaging,
    /// Tables, columns and SQL, on an engine that has keys instead.
    Tables,
    /// Keys, on an engine that has tables instead.
    Keys,
    /// A list of character sets and collations to pick a column's or a
    /// table's from.
    CharacterSets,
    /// Another of the server's databases for a query tab.
    DatabaseSwitching,
    /// The options a new database can take.
    DatabaseOptions,
    /// The SQL that defines a routine, a sequence or a trigger.
    ObjectDefinitions,
    /// The SQL of a SQL Server routine whose code is a .NET assembly.
    ClrRoutine,
    /// The SQL of a SQL Server module created `WITH ENCRYPTION`.
    EncryptedDefinition,
    /// A command the editor cannot run, because it stops the one reply
    /// per command the editor reads, such as `SUBSCRIBE`.
    EditorCommand {
        command: &'static str,
    },
    // A login whose account uses a client plugin the driver does not speak, such as MariaDB's ed25519.
    AuthPlugin,
    /// A whole database written as one SQL file.
    SqlDump,
}

impl UnsupportedFeature {
    /// A stable code for each feature, for an app that words an error by
    /// its codes.
    pub fn code(&self) -> &'static str {
        match self {
            Self::DatabaseFile => "unsupported.database_file",
            Self::NetworkConnection => "unsupported.network_connection",
            Self::ForeignKeySuspension => "unsupported.foreign_key_suspension",
            Self::MinimumVersion { .. } => "unsupported.minimum_version",
            Self::CopyFromStdinInEditor => "unsupported.copy_from_stdin_in_editor",
            Self::CopyToStdoutInEditor => "unsupported.copy_to_stdout_in_editor",
            Self::CopyFromStdin => "unsupported.copy_from_stdin",
            Self::TimestampInRepeatedHour => "unsupported.timestamp_in_repeated_hour",
            Self::TimeOutsideOneDay => "unsupported.time_outside_one_day",
            Self::TimeWithOffset => "unsupported.time_with_offset",
            Self::Interval => "unsupported.interval",
            Self::BitString => "unsupported.bit_string",
            Self::NumberWiderThan { .. } => "unsupported.number_wider_than",
            Self::DecimalOutOfRange { .. } => "unsupported.decimal_out_of_range",
            Self::DateOutsideYears { .. } => "unsupported.date_outside_years",
            Self::HiddenAttach => "unsupported.hidden_attach",
            Self::ServerPaging => "unsupported.server_paging",
            Self::Tables => "unsupported.tables",
            Self::Keys => "unsupported.keys",
            Self::CharacterSets => "unsupported.character_sets",
            Self::DatabaseSwitching => "unsupported.database_switching",
            Self::DatabaseOptions => "unsupported.database_options",
            Self::ObjectDefinitions => "unsupported.object_definitions",
            Self::ClrRoutine => "unsupported.clr_routine",
            Self::EncryptedDefinition => "unsupported.encrypted_definition",
            Self::EditorCommand { .. } => "unsupported.editor_command",
            Self::AuthPlugin => "unsupported.auth_plugin",
            Self::SqlDump => "unsupported.sql_dump",
        }
    }
}

impl fmt::Display for UnsupportedFeature {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DatabaseFile => f.write_str("a database file"),
            Self::NetworkConnection => f.write_str("network connections"),
            Self::ForeignKeySuspension => f.write_str("foreign key suspension"),
            Self::MinimumVersion { required } => write!(f, "{required} or later"),
            Self::CopyFromStdinInEditor => f.write_str("COPY FROM STDIN in the editor"),
            Self::CopyToStdoutInEditor => f.write_str("COPY TO STDOUT in the editor"),
            Self::CopyFromStdin => f.write_str("COPY FROM STDIN rows"),
            Self::TimestampInRepeatedHour => {
                f.write_str("single instant for a TIMESTAMP in the hour its time zone repeats")
            }
            Self::TimeOutsideOneDay => f.write_str("a time outside one day"),
            Self::TimeWithOffset => f.write_str("a time with an offset"),
            Self::Interval => f.write_str("an interval"),
            Self::BitString => f.write_str("a bit string"),
            Self::NumberWiderThan { digits } => write!(f, "a number wider than {digits} digits"),
            Self::DecimalOutOfRange { digits } => write!(f, "a decimal NaN, infinity or wider than {digits} digits"),
            Self::DateOutsideYears { first, last } => write!(f, "a date outside years {first} to {last}"),
            Self::HiddenAttach => f.write_str("a HIDDEN attached database"),
            Self::ServerPaging => f.write_str("server-side paging"),
            Self::Tables => f.write_str("tables"),
            Self::Keys => f.write_str("keys"),
            Self::CharacterSets => f.write_str("character sets"),
            Self::DatabaseSwitching => f.write_str("database switching"),
            Self::DatabaseOptions => f.write_str("options for a new database"),
            Self::ObjectDefinitions => f.write_str("object definitions"),
            Self::ClrRoutine => f.write_str("the SQL of a CLR routine"),
            Self::EncryptedDefinition => f.write_str("the SQL of an encrypted module"),
            Self::EditorCommand { command } => write!(f, "{command} in the editor"),
            Self::AuthPlugin => f.write_str("this account's authentication plugin"),
            Self::SqlDump => f.write_str("a SQL dump"),
        }
    }
}
