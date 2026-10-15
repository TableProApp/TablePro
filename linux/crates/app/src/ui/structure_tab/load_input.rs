use tablepro_session::LinkGeneration;

use super::StructureCommand;

/// What reads the table's definition, or reads it again.
#[derive(Debug)]
pub(crate) enum LoadInput {
    /// The tab is built: read the table, or draw an empty draft.
    Start,
    /// A reply to the tab's read, boxed: it holds the whole definition,
    /// which every other input would otherwise carry room for.
    Command(Box<StructureCommand>),
    /// A reconnect replaced the session's connection.
    LinkChanged(LinkGeneration),
    /// The table's definition changed elsewhere.
    SchemaChanged,
    /// Try Again on the error page, or Retry on the banner.
    Retry,
}
