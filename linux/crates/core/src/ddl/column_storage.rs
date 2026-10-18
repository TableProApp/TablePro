/// How PostgreSQL keeps a column's long values: inline or out of line,
/// compressed or not, as `SET STORAGE` names it.
///
/// A type change resets it to the new type's own, so a column that had
/// one set keeps it only when the change restates it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColumnStorage {
    Plain,
    Main,
    External,
    Extended,
}

/// The method PostgreSQL compresses a column's values with, as
/// `SET COMPRESSION` names it.
///
/// A type change resets it to `default_toast_compression`, so it is
/// restated the same way as the storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColumnCompression {
    Pglz,
    Lz4,
}
