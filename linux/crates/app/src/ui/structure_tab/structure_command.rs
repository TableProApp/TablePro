use std::sync::Arc;

use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_session::OperationError;

use crate::runtime::Stamped;

/// The one read a structure tab makes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum StructureRequestKind {
    Definition,
}

/// The table as one definition, read in one call, with the dialect of
/// the connection that read it, which the tab spells its DDL in.
#[derive(Debug)]
pub(crate) struct LoadedStructure {
    pub definition: TableDefinition,
    pub dialect: Arc<dyn SqlDialect>,
}

/// A reply to the tab's read, stamped with the request it answers so a
/// reply to a replaced request is dropped.
#[derive(Debug)]
pub(crate) enum StructureCommand {
    Loaded(Stamped<Result<LoadedStructure, OperationError>>),
}
