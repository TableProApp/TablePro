use std::fmt;
use std::sync::Arc;

use crate::statement::Statement;
use crate::value::{Value, same_value};

/// Where in the table a page starts.
#[derive(Debug, Clone, PartialEq)]
pub enum PagePosition {
    First,
    /// The table's last rows, read backward from its end. The SQL
    /// reverses the order and the reader puts the rows back.
    Last,
    Offset(u64),
    /// Forward from the last row of the page before, by its key.
    AfterKey(Vec<Value>),
    /// Backward from the first row of the page after, by its key. The
    /// SQL reverses the order and the reader puts the rows back.
    BeforeKey(Vec<Value>),
    /// One range of PostgreSQL heap addresses, for a table with no key.
    /// A page is read through as many of these as it takes to fill it.
    CtidWindow(CtidWindow),
    /// Forward from where the server stopped the page before, by the
    /// paging state it handed back.
    Resume(PagingState),
}

/// Where a server-paged read stopped, as the server handed it back.
///
/// The bytes mean something only to the statement that produced them:
/// the server reads a paging state against any statement without
/// checking, and returns rows from the wrong place for another. So the
/// state keeps its statement, and a page resumes from it only with the
/// same one.
#[derive(Clone)]
pub struct PagingState {
    bytes: Arc<[u8]>,
    statement: Arc<Statement>,
}

impl PagingState {
    pub fn new(bytes: Arc<[u8]>, statement: Statement) -> Self {
        Self {
            bytes,
            statement: Arc::new(statement),
        }
    }

    /// The server's bytes, to send back with `statement`.
    pub fn bytes_for(&self, statement: &Statement) -> Option<&Arc<[u8]>> {
        same_statement(&self.statement, statement).then_some(&self.bytes)
    }
}

impl PartialEq for PagingState {
    fn eq(&self, other: &Self) -> bool {
        self.bytes == other.bytes && same_statement(&self.statement, &other.statement)
    }
}

/// The same text with the same values, a NaN filter value included,
/// which `==` on a float never finds equal to itself.
fn same_statement(left: &Statement, right: &Statement) -> bool {
    left.sql() == right.sql()
        && left.params().len() == right.params().len()
        && left
            .params()
            .iter()
            .zip(right.params())
            .all(|(left, right)| left.param_type() == right.param_type() && same_value(left.value(), right.value()))
}

impl fmt::Debug for PagingState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PagingState")
            .field("bytes", &self.bytes.len())
            .field("sql", &self.statement.sql())
            .finish()
    }
}

/// A PostgreSQL heap address: block, then line pointer. Line pointers
/// start at 1, so `(block, 0)` sorts before every row in that block.
pub type HeapAddress = (u32, u16);

/// The rows between two heap addresses. A bound left out runs to that
/// end of the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CtidWindow {
    pub after: Option<HeapAddress>,
    pub before: Option<HeapAddress>,
    /// Read from `before` down, for a page that ends there.
    pub backward: bool,
}

/// Whether the same page read twice shows the same rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageStability {
    /// A total order over a unique key: paging cannot skip or repeat.
    Stable,
    /// The order has ties, so rows can move between pages.
    NonUniqueOrder,
    /// No order at all. The engine may return rows in any order each
    /// time.
    Unordered,
}

/// What the page costs the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageCost {
    /// An index seek. Constant whatever the offset.
    KeySeek,
    /// A scan of one physical block range.
    BlockWindow,
    /// A sort of the whole table per page, which is what OFFSET costs
    /// at a large offset.
    SortPerPage,
    /// The server resumes where its last page stopped. Constant
    /// whatever the page.
    ServerResume,
    /// The server reads every row before the page and the driver drops
    /// them, which is what an offset costs where the server pages itself.
    ReadPastSkipped,
}

impl PageStability {
    /// Whether the grid should warn that paging may skip or repeat a
    /// row.
    pub fn needs_warning(self) -> bool {
        !matches!(self, Self::Stable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_paging_state_resumes_only_the_statement_it_came_from() {
        let mut builder = crate::statement::StatementBuilder::new();
        builder.push_sql("SELECT a FROM t");
        let page = builder.finish();
        let mut other = crate::statement::StatementBuilder::new();
        other.push_sql("SELECT b FROM t");
        let state = PagingState::new(Arc::from(&b"\x01\x02"[..]), page.clone());

        assert_eq!(state.bytes_for(&page).map(|bytes| bytes.len()), Some(2));
        assert_eq!(state.bytes_for(&other.finish()), None);
        assert_eq!(
            format!("{state:?}"),
            "PagingState { bytes: 2, sql: \"SELECT a FROM t\" }"
        );
    }

    #[test]
    fn a_nan_filter_value_resumes_its_own_statement() {
        use crate::column::{ColumnDefault, ColumnInfo, ColumnKind, ColumnType, FloatWidth, ReadForm};
        use crate::dialect::{BindTarget, TestDialect};

        let column = ColumnInfo {
            name: "f".to_owned(),
            column_type: ColumnType {
                name: "double".to_owned(),
                kind: ColumnKind::Float(FloatWidth::F64),
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        };
        let page = |value: f64| {
            let mut builder = crate::statement::StatementBuilder::new();
            builder.push_sql("SELECT a FROM t WHERE f = ");
            builder
                .push_value(
                    &TestDialect::default(),
                    Value::Float64(value),
                    BindTarget::Column(&column),
                )
                .expect("a float binds");
            builder.finish()
        };
        let state = PagingState::new(Arc::from(&b"\x01"[..]), page(f64::NAN));

        assert!(state.bytes_for(&page(f64::NAN)).is_some());
        assert!(state.bytes_for(&page(1.0)).is_none());
        assert_eq!(state, state.clone());
    }

    #[test]
    fn anything_but_a_total_order_is_worth_warning_about() {
        assert!(!PageStability::Stable.needs_warning());
        assert!(PageStability::NonUniqueOrder.needs_warning());
        assert!(PageStability::Unordered.needs_warning());
    }
}
