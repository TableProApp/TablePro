use serde::{Deserialize, Serialize};

/// Where the user put one table of an ER diagram, in whole diagram units.
/// The table is named without its schema: a diagram shows one schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagramPlace {
    pub table: String,
    pub x: i32,
    pub y: i32,
}
