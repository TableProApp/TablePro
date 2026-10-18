use serde::{Deserialize, Serialize};

/// The column a table tab was sorted by, as its position in the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SortRecord {
    pub column: usize,
    pub ascending: bool,
}
