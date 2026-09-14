use chrono::FixedOffset;

use crate::value::SqlTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TimeWithOffset {
    pub time: SqlTime,
    pub offset: FixedOffset,
}
