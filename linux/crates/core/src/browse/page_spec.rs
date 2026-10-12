use crate::meta::{PageCost, PageStability};
use crate::statement::Statement;

use super::{PageLayout, RowKeyLayout};

/// A page query and what the caller needs to read its result back.
#[derive(Debug, Clone, PartialEq)]
pub struct PageSpec {
    pub statement: Statement,
    pub layout: PageLayout,
    /// Where each row's key is read from, in `key_components` order.
    pub row_key: RowKeyLayout,
    pub stability: PageStability,
    pub cost: PageCost,
}

impl PageSpec {
    /// How many of the returned columns the user sees.
    pub fn visible_columns(&self) -> usize {
        self.layout.visible.len()
    }
}
