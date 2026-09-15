/// How a row in this table can be named again after it was read.
///
/// Everything the grid can edit depends on this: without a way to name
/// exactly one row, an UPDATE is a guess. The variants are in
/// descending order of confidence, and `Unordered` means the grid is
/// read-only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowIdentity {
    /// A primary key, or a unique index over columns that are all NOT
    /// NULL and cover every row.
    UniqueKey { columns: Vec<String> },
    /// The engine's own physical address for the row, projected as a
    /// hidden column.
    EngineRowId(EngineRowId),
    /// ClickHouse: the sorting key names a row well enough to probe
    /// for, but not uniquely enough to trust an affected-row count.
    SortingKey { expressions: Vec<String> },
    /// Nothing names a row. The grid shows the data and refuses edits.
    Unordered,
}

/// An engine's physical row address.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EngineRowId {
    PostgresCtid,
    /// A partitioned table, where a ctid is only unique within one
    /// partition, so the partition's oid goes with it.
    PostgresTableoidCtid,
    SqliteRowid,
}

/// One column of an engine row id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EngineRowIdPart {
    PostgresTableOid,
    PostgresCtid,
    SqliteRowid,
}

impl EngineRowId {
    /// The parts that make up the id, in the order they are projected
    /// and bound. One order for the page layout, the change set key
    /// and the DML predicate, so they cannot disagree.
    pub fn parts(self) -> &'static [EngineRowIdPart] {
        match self {
            Self::PostgresCtid => &[EngineRowIdPart::PostgresCtid],
            Self::PostgresTableoidCtid => &[EngineRowIdPart::PostgresTableOid, EngineRowIdPart::PostgresCtid],
            Self::SqliteRowid => &[EngineRowIdPart::SqliteRowid],
        }
    }
}

impl RowIdentity {
    /// Whether the grid may offer edits at all.
    pub fn is_editable(&self) -> bool {
        !matches!(self, Self::Unordered)
    }

    /// Whether an affected-row count is exact enough to be the proof
    /// that a write hit one row. A sorting key is not: it can match
    /// several rows.
    pub fn trusts_affected_counts(&self) -> bool {
        matches!(self, Self::UniqueKey { .. } | Self::EngineRowId(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_partitioned_ctid_carries_its_partition_first() {
        assert_eq!(
            EngineRowId::PostgresTableoidCtid.parts(),
            &[EngineRowIdPart::PostgresTableOid, EngineRowIdPart::PostgresCtid]
        );
        assert_eq!(EngineRowId::PostgresCtid.parts(), &[EngineRowIdPart::PostgresCtid]);
        assert_eq!(EngineRowId::SqliteRowid.parts(), &[EngineRowIdPart::SqliteRowid]);
    }

    #[test]
    fn unordered_rows_are_read_only() {
        assert!(!RowIdentity::Unordered.is_editable());
        assert!(
            RowIdentity::UniqueKey {
                columns: vec!["id".into()]
            }
            .is_editable()
        );
    }

    #[test]
    fn a_sorting_key_is_editable_but_its_counts_are_not_proof() {
        let sorting = RowIdentity::SortingKey {
            expressions: vec!["id".into()],
        };

        assert!(sorting.is_editable());
        assert!(
            !sorting.trusts_affected_counts(),
            "a sorting key was trusted to be unique"
        );
        assert!(RowIdentity::EngineRowId(EngineRowId::SqliteRowid).trusts_affected_counts());
    }
}
