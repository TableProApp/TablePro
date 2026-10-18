use std::ops::Range;

use tablepro_core::browse::PageLayout;
use tablepro_core::meta::RowIdentity;
use tablepro_core::{ColumnInfo, Value};

use crate::services::change_tracker::{KeyValue, RowKey};

/// Names each row of a page by every cell of the identity it was keyed
/// on, so two rows that share part of it never share a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowKeyBuilder {
    source: KeySource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum KeySource {
    /// Positions among the visible cells, in key order.
    Visible(Box<[usize]>),
    /// Positions among the identity cells the page projected after the
    /// visible ones.
    Identity(Range<usize>),
}

impl RowKeyBuilder {
    /// `None` when nothing on the page names a row, so its rows are
    /// read-only: a sorting key can match several rows.
    pub fn for_page(identity: &RowIdentity, columns: &[ColumnInfo], layout: &PageLayout) -> Option<Self> {
        let source = match identity {
            RowIdentity::UniqueKey { columns: key } if !key.is_empty() => {
                let positions = key
                    .iter()
                    .map(|name| {
                        columns
                            .iter()
                            .position(|column| column.name == *name)
                            .filter(|position| layout.visible.contains(position))
                    })
                    .collect::<Option<Box<[usize]>>>()?;
                KeySource::Visible(positions)
            }
            RowIdentity::EngineRowId(_) if !layout.identity.is_empty() => KeySource::Identity(0..layout.identity.len()),
            RowIdentity::UniqueKey { .. }
            | RowIdentity::EngineRowId(_)
            | RowIdentity::SortingKey { .. }
            | RowIdentity::Unordered => return None,
        };
        Some(Self { source })
    }

    /// The row's key, `None` when a cell of it could not be read and so
    /// cannot name the row to the server again.
    pub fn key_for(&self, visible: &[Value], identity: &[Value]) -> Option<RowKey> {
        let parts = match &self.source {
            KeySource::Visible(positions) => positions
                .iter()
                .map(|position| visible.get(*position).filter(|value| readable(value)))
                .map(|value| value.cloned().map(KeyValue::new))
                .collect::<Option<Vec<_>>>()?,
            // A null row address names nothing.
            KeySource::Identity(range) => identity
                .get(range.clone())?
                .iter()
                .map(|value| (readable(value) && !value.is_null()).then(|| KeyValue::new(value.clone())))
                .collect::<Option<Vec<_>>>()?,
        };
        Some(RowKey::Persisted(parts))
    }
}

fn readable(value: &Value) -> bool {
    !matches!(value, Value::Undecodable(_))
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::browse::{PageLayout, PageRequest, build_page};
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::meta::{EngineRowId, PagePosition, RowIdentity, TableRef};
    use tablepro_core::value::{UndecodableReason, UndecodedValue};
    use tablepro_core::{ColumnInfo, FilterSet};

    use super::RowKeyBuilder;
    use crate::services::change_tracker::RowKey;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn columns(names: &[&str]) -> Vec<ColumnInfo> {
        names.iter().map(|name| column(name)).collect()
    }

    /// The layout the page builder gives `identity` over `columns`.
    fn layout(identity: &RowIdentity, columns: &[ColumnInfo]) -> PageLayout {
        let dialect =
            tablepro_driver_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        build_page(
            &dialect,
            &PageRequest {
                table: &TableRef::unqualified("t"),
                columns,
                filter: &FilterSet::default(),
                sort: &[],
                identity,
                position: &PagePosition::First,
                limit: 100,
            },
        )
        .expect("a page")
        .layout
    }

    fn key(values: &[Value]) -> Option<RowKey> {
        RowKey::from_pk_values(values)
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn row_key_builder_unique_key_uses_visible_key_columns() {
        let columns = columns(&["tenant", "name", "id"]);
        let identity = RowIdentity::UniqueKey {
            columns: vec!["id".to_owned(), "tenant".to_owned()],
        };
        let layout = layout(&identity, &columns);
        let builder = RowKeyBuilder::for_page(&identity, &columns, &layout).expect("a keyed page");

        let row = [text("eu"), text("Ada"), Value::Int(7)];

        assert!(layout.identity.is_empty(), "a unique key needs no hidden column");
        assert_eq!(builder.key_for(&row, &[]), key(&[Value::Int(7), text("eu")]));
    }

    #[test]
    fn row_key_builder_tableoid_ctid_keys_on_both_identity_columns() {
        let columns = columns(&["name"]);
        let identity = RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid);
        let layout = layout(&identity, &columns);
        let builder = RowKeyBuilder::for_page(&identity, &columns, &layout).expect("a keyed page");
        let ctid = text("(0,1)");
        let xmin = text("812");

        let first = builder.key_for(&[text("a")], &[Value::Int(16_401), ctid.clone(), xmin.clone()]);
        let second = builder.key_for(&[text("a")], &[Value::Int(16_402), ctid, xmin]);

        assert_eq!(layout.identity.len(), 3, "tableoid, ctid and xmin");
        assert!(first.is_some());
        assert_ne!(first, second, "a ctid from another partition named the same row");
    }

    #[test]
    fn row_key_builder_rowid_uses_single_identity_column() {
        let columns = columns(&["name", "note"]);
        let identity = RowIdentity::EngineRowId(EngineRowId::SqliteRowid);
        let layout = tablepro_core::browse::PageLayout {
            visible: 0..2,
            identity: 2..3,
        };
        let builder = RowKeyBuilder::for_page(&identity, &columns, &layout).expect("a keyed page");

        assert_eq!(
            builder.key_for(&[text("a"), text("b")], &[Value::Int(11)]),
            key(&[Value::Int(11)])
        );
        assert_eq!(
            builder.key_for(&[text("a"), text("b")], &[Value::Null]),
            None,
            "a null row address named a row"
        );
    }

    #[test]
    fn row_key_builder_returns_none_for_undecodable_key() {
        let unreadable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));
        let columns = columns(&["id", "name"]);
        let identity = RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        };
        let layout = layout(&identity, &columns);
        let builder = RowKeyBuilder::for_page(&identity, &columns, &layout).expect("a keyed page");

        assert_eq!(builder.key_for(&[unreadable, text("a")], &[]), None);
        assert_eq!(
            builder.key_for(&[Value::Null, text("a")], &[]),
            key(&[Value::Null]),
            "a NULL key cell still names its row, as SQLite allows"
        );
    }

    #[test]
    fn a_page_nothing_names_has_no_builder() {
        let columns = columns(&["day", "hits"]);
        let layout = PageLayout {
            visible: 0..2,
            identity: 2..2,
        };
        let sorting = RowIdentity::SortingKey {
            expressions: vec!["day".to_owned()],
        };
        let missing = RowIdentity::UniqueKey {
            columns: vec!["gone".to_owned()],
        };

        assert_eq!(RowKeyBuilder::for_page(&sorting, &columns, &layout), None);
        assert_eq!(
            RowKeyBuilder::for_page(&RowIdentity::Unordered, &columns, &layout),
            None
        );
        assert_eq!(RowKeyBuilder::for_page(&missing, &columns, &layout), None);
        assert_eq!(
            RowKeyBuilder::for_page(&RowIdentity::UniqueKey { columns: Vec::new() }, &columns, &layout),
            None,
            "a table with no primary key"
        );
    }
}
