use crate::value::Value;

use super::EncodeError;

/// Writes a result one row at a time into a buffer the caller owns, so
/// the caller decides how much to hold before handing it on.
pub trait RowEncoder: Send {
    /// What comes before the first row: a header line, an opening
    /// bracket.
    fn begin(&mut self, out: &mut Vec<u8>);

    /// One row. A row that fails leaves `out` as it was.
    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError>;

    /// What comes after the last row.
    fn finish(&mut self, out: &mut Vec<u8>);
}
