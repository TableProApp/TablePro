use std::rc::Rc;
use std::sync::Arc;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;

use super::{KeysHandle, LayoutBinding};
use crate::services::grid::{EditPolicy, GridColumn};
use crate::services::tab_tracker_handle::TabTrackerHandle;

/// How a grid's headers sort its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridSorting {
    /// The server sorts: a header click asks the host for the rows again
    /// in that order. `initial` is the order the first rows arrive in.
    Server { initial: Option<(usize, bool)> },
    /// The grid sorts the rows it holds.
    Client,
    /// The engine reads in its own order, which nothing changes.
    None,
}

/// The dialect a copy writes SQL literals in, asked for at each copy
/// since a reconnect can reach another server version.
pub type DialectSource = Rc<dyn Fn() -> Option<Arc<dyn SqlDialect>>>;

/// What a grid may change in the rows of its column set. It names
/// columns, so it comes and goes with them.
#[derive(Debug, Clone)]
pub struct EditRules {
    /// What names a saved row, which locks the columns that name it.
    pub identity: RowIdentity,
    pub policy: EditPolicy,
}

/// Everything a host decides about its grid.
#[derive(Clone)]
pub struct GridConfig {
    /// The first column set, its sort and its rules; `set_columns`
    /// replaces all three.
    pub columns: Arc<[GridColumn]>,
    pub sorting: GridSorting,
    pub rules: Option<EditRules>,
    /// Where edits go. `None` for a grid that only shows rows.
    pub tracker: Option<TabTrackerHandle>,
    /// Read when it is needed, so a change in Preferences reaches open
    /// grids.
    pub settings: Rc<AppSettings>,
    /// Where the table's column layout is kept. `None` keeps it for the
    /// grid's life only.
    pub layout: Option<LayoutBinding>,
    /// The foreign keys of the table the rows come from.
    pub references: Option<KeysHandle>,
    /// `None` where the rows have no SQL spelling: no IN list to copy.
    pub dialect: Option<DialectSource>,
    /// The table an INSERT copy writes into.
    pub table: Option<TableRef>,
    /// Ctrl+F searches the rows the grid holds.
    pub find: bool,
    /// The host can add a filter rule from a cell's value.
    pub filter_by_value: bool,
    pub tasks: Tasks,
    /// What a screen reader calls the grid.
    pub label: String,
}
