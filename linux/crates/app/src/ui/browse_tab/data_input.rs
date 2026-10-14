use tablepro_session::LinkGeneration;

use super::BrowseCommand;

/// What changes the columns and rows the tab holds: its own reads, and
/// changes to the connection or the table under it.
#[derive(Debug)]
pub(crate) enum DataInput {
    /// The tab is built: read the columns, then the page and the count.
    Start,
    /// A reply to one of the tab's reads.
    Command(BrowseCommand),
    /// A reconnect replaced the session's connection.
    LinkChanged(LinkGeneration),
    /// The table's definition changed. The catalog has already dropped
    /// its columns, so they are read again before the page.
    SchemaChanged,
}
