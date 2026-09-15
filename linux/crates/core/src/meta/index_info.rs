/// A secondary index.
///
/// The keys are typed rather than a list of names, because an index on
/// `lower(email)` has no column to name, and a descending key changes
/// what a keyset page has to compare.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexInfo {
    pub name: String,
    pub keys: Vec<IndexKey>,
    pub unique: bool,
    /// The index behind the primary key. The column definition owns
    /// it, so the structure tab renders it read-only.
    pub primary: bool,
    /// A partial index's WHERE clause. An index with one cannot
    /// identify a row, because it does not cover every row.
    pub predicate: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexKey {
    Column { name: String, descending: bool },
    Expression { sql: String, descending: bool },
}

impl IndexKey {
    /// The column this key is on, or `None` for an expression.
    pub fn column_name(&self) -> Option<&str> {
        match self {
            Self::Column { name, .. } => Some(name),
            Self::Expression { .. } => None,
        }
    }

    pub fn descending(&self) -> bool {
        match self {
            Self::Column { descending, .. } | Self::Expression { descending, .. } => *descending,
        }
    }
}

impl IndexInfo {
    /// Whether this index could identify a row: unique, over plain
    /// columns, and covering every row.
    pub fn can_identify_rows(&self) -> bool {
        self.unique
            && self.predicate.is_none()
            && !self.keys.is_empty()
            && self.keys.iter().all(|key| key.column_name().is_some())
    }

    /// The columns the keys name, in order. Empty when any key is an
    /// expression.
    pub fn key_columns(&self) -> Vec<String> {
        self.keys
            .iter()
            .filter_map(|key| key.column_name().map(str::to_owned))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(keys: Vec<IndexKey>, unique: bool, predicate: Option<&str>) -> IndexInfo {
        IndexInfo {
            name: "idx".to_owned(),
            keys,
            unique,
            primary: false,
            predicate: predicate.map(str::to_owned),
        }
    }

    fn column(name: &str) -> IndexKey {
        IndexKey::Column {
            name: name.to_owned(),
            descending: false,
        }
    }

    #[test]
    fn only_a_total_unique_index_over_columns_identifies_a_row() {
        assert!(index(vec![column("id")], true, None).can_identify_rows());
        assert!(!index(vec![column("id")], false, None).can_identify_rows());
        assert!(
            !index(vec![column("id")], true, Some("deleted_at IS NULL")).can_identify_rows(),
            "a partial index was accepted, and it does not cover every row"
        );
        assert!(!index(Vec::new(), true, None).can_identify_rows());
    }

    #[test]
    fn an_expression_key_cannot_identify_a_row() {
        let functional = index(
            vec![IndexKey::Expression {
                sql: "lower(email)".to_owned(),
                descending: false,
            }],
            true,
            None,
        );

        assert!(!functional.can_identify_rows());
        assert!(functional.key_columns().is_empty());
    }
}
