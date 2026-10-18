use crate::column::ColumnInfo;
use crate::meta::EngineRowIdPart;

/// What a value is being bound for, which is what decides its
/// parameter type.
///
/// The same text binds differently depending on where it lands: as a
/// column's own type, as a LIKE pattern, or as an engine row address
/// the server has to parse.
#[derive(Debug, Clone, Copy)]
pub enum BindTarget<'a> {
    Column(&'a ColumnInfo),
    /// A LIKE pattern, which is text whatever the column is.
    Pattern,
    EngineRowId(EngineRowIdPart),
}
