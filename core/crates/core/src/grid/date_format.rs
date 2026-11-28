/// How a grid lays out a date, a timestamp or a clock. The app owns the
/// setting and its names; the core owns the layout each one maps to.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum DateFormat {
    #[default]
    Iso,
    IsoDate,
    UsLong,
    UsShort,
    EuLong,
    EuShort,
}

impl DateFormat {
    pub const ALL: [Self; 6] = [
        Self::Iso,
        Self::IsoDate,
        Self::UsLong,
        Self::UsShort,
        Self::EuLong,
        Self::EuShort,
    ];
}
