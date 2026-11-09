use tablepro_session::LinkGeneration;

use super::BrowseCommand;

#[derive(Debug)]
pub(crate) enum DataInput {
    Start,
    // Replies own page data; keep that payload out of every queued input.
    Command(Box<BrowseCommand>),
    LinkChanged(LinkGeneration),
    SchemaChanged,
}
