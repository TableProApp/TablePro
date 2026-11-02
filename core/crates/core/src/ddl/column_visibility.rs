/// Whether `SELECT *` includes the column.
///
/// MySQL and MariaDB can hide a column from `*`. A redefinition that
/// does not restate `INVISIBLE` makes it visible again, which changes
/// every `SELECT *` and `INSERT` without a column list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ColumnVisibility {
    #[default]
    Visible,
    Invisible,
}
