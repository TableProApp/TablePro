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
    /// The engine's client library is older than the driver needs, such
    /// as `SQLite 3.37.0`.
    MinimumVersion {
        required: &'static str,
    },
    CopyFromStdinInEditor,
    CopyToStdoutInEditor,
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
    /// Pages the server keeps itself, by a paging state.
    ServerPaging,
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
            Self::ServerPaging => f.write_str("server-side paging"),
        }
    }
}
