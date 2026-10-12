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
    /// The transaction that wrote this tuple version. VACUUM can hand a
    /// freed ctid to a new row, and xmin is what tells the two apart,
    /// so a save against the old row matches nothing instead of the
    /// stranger now living at its address.
    PostgresXmin,
    SqliteRowid,
}

impl EngineRowIdPart {
    /// Whether rows can be ordered by this part. xmin names a version,
    /// not a position, and PostgreSQL's xid type has no ordering
    /// operator, so it never reaches an ORDER BY or a keyset bound.
    pub fn orders_rows(self) -> bool {
        !matches!(self, Self::PostgresXmin)
    }

    /// The name a page gives the hidden column that carries this part.
    /// Fixed here so every dialect projects the same names.
    pub fn projection_alias(self) -> &'static str {
        match self {
            Self::PostgresTableOid => "__tablepro_row_oid",
            Self::PostgresCtid | Self::SqliteRowid => "__tablepro_row_id",
            Self::PostgresXmin => "__tablepro_row_xmin",
        }
    }
}

impl EngineRowId {
    /// The parts that make up the id, in the order they are projected
    /// and bound. One order for the page layout, the change set key
    /// and the DML predicate, so they cannot disagree.
    pub fn parts(self) -> &'static [EngineRowIdPart] {
        match self {
            Self::PostgresCtid => &[EngineRowIdPart::PostgresCtid, EngineRowIdPart::PostgresXmin],
            Self::PostgresTableoidCtid => &[
                EngineRowIdPart::PostgresTableOid,
                EngineRowIdPart::PostgresCtid,
                EngineRowIdPart::PostgresXmin,
            ],
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
            &[
                EngineRowIdPart::PostgresTableOid,
                EngineRowIdPart::PostgresCtid,
                EngineRowIdPart::PostgresXmin
            ]
        );
        assert_eq!(EngineRowId::SqliteRowid.parts(), &[EngineRowIdPart::SqliteRowid]);
    }

    #[test]
    fn a_postgres_row_address_carries_its_tuple_version() {
        assert_eq!(
            EngineRowId::PostgresCtid.parts(),
            &[EngineRowIdPart::PostgresCtid, EngineRowIdPart::PostgresXmin],
            "a ctid reused after VACUUM would name the wrong row"
        );
        assert!(
            !EngineRowIdPart::PostgresXmin.orders_rows(),
            "xid has no ordering operator"
        );
        assert!(EngineRowIdPart::PostgresCtid.orders_rows());
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
