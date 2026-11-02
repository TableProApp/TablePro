use crate::value::SqlTime;

/// How a boolean column stores its value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoolStorage {
    Native,
    /// MySQL `tinyint(1)` and SQLite BOOLEAN: the server keeps any
    /// integer, so the value stays a `Value::Int` and 2 is not true.
    Integer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FloatWidth {
    F32,
    F64,
}

/// The length a text or byte column declares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextLength {
    Unbounded,
    Varying(u32),
    /// Padded to this length by the server, so a trailing-space diff is
    /// the server's doing and not the user's.
    Fixed(u32),
}

/// What a time column measures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimeRange {
    TimeOfDay,
    /// MySQL TIME, which runs from -838:59:59 to 838:59:59.
    Duration,
    /// ClickHouse Time and Time64, which run to 999:59:59 either side of
    /// zero.
    LongDuration,
}

impl TimeRange {
    /// Whether a column of this range can hold `time`.
    pub fn holds(self, time: &SqlTime) -> bool {
        match self {
            Self::TimeOfDay => time.to_time_of_day().is_some(),
            Self::Duration => time.within_hours(838),
            // A `SqlTime` reaches no further than ClickHouse's Time64.
            Self::LongDuration => true,
        }
    }
}

/// How a timestamp column relates to a time zone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemporalZone {
    Naive,
    Offset,
    /// ClickHouse `DateTime('Europe/Paris')`: wall-clock time in a zone
    /// the column names, with no offset in the value.
    Named(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkFamily {
    Inet,
    Cidr,
    MacAddr,
    MacAddr8,
    Ipv4,
    Ipv6,
}
