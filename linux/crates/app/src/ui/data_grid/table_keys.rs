use std::cell::RefCell;
use std::rc::Rc;

use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey};
use tablepro_core::meta::TableRef;

/// A table's foreign keys both ways, as its tab last read them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableKeys {
    pub(crate) table: TableRef,
    /// The table's own keys, which point at other rows.
    pub(crate) outbound: Vec<OutboundForeignKey>,
    /// Other tables' keys that point at this one.
    pub(crate) inbound: Vec<InboundForeignKey>,
}

impl TableKeys {
    pub(crate) fn none(table: TableRef) -> Self {
        Self {
            table,
            outbound: Vec::new(),
            inbound: Vec::new(),
        }
    }
}

/// Shared by a table tab and its grid, so keys read after the grid was
/// built reach its menus. A menu takes the keys as it opens, so a read
/// that lands while it is open changes nothing it shows.
#[derive(Debug, Clone)]
pub struct KeysHandle(Rc<RefCell<Rc<TableKeys>>>);

impl KeysHandle {
    pub(crate) fn new(table: TableRef) -> Self {
        Self(Rc::new(RefCell::new(Rc::new(TableKeys::none(table)))))
    }

    pub(crate) fn get(&self) -> Rc<TableKeys> {
        self.0.borrow().clone()
    }

    pub(crate) fn set(&self, keys: TableKeys) {
        self.0.replace(Rc::new(keys));
    }
}
