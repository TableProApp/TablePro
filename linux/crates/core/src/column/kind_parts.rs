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
