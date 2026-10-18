/// Which protocol a row came over.
///
/// sqlx keeps `MySqlValueRef::format` to itself, so the caller says
/// which one it used: a prepared statement (`sqlx::query`) answers in
/// the binary protocol, and `raw_sql` in the text protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum MySqlWireFormat {
    Binary,
    Text,
}
