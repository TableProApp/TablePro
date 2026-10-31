use std::sync::Arc;

use tablepro_core::ddl::{CharacterSet, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_session::OperationError;

use crate::runtime::Stamped;
use crate::ui::tab_load::LoadFailure;

/// The reads a structure tab makes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum StructureRequestKind {
    Definition,
    CharacterSets,
}

/// The table as one definition, read in one call, with the dialect of
/// the connection that read it, which the tab spells its DDL in.
#[derive(Debug)]
pub(crate) struct LoadedStructure {
    pub definition: TableDefinition,
    pub dialect: Arc<dyn SqlDialect>,
}

/// A reply to one of the tab's reads, stamped with the request it
/// answers so a reply to a replaced request is dropped.
#[derive(Debug)]
#[expect(
    clippy::large_enum_variant,
    reason = "every command travels boxed in LoadInput::Command, so the enum is never moved by value"
)]
pub(crate) enum StructureCommand {
    Loaded(Stamped<Result<LoadedStructure, LoadFailure>>),
    CharacterSetsRead(Stamped<Result<Vec<CharacterSet>, Arc<OperationError>>>),
}
