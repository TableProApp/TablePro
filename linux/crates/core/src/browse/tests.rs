use crate::column::{
    ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, TextLength,
};
use crate::dialect::{RecordedTarget, TestDialect, TestMarkers};
use crate::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use crate::meta::{EngineRowId, EngineRowIdPart, PageCost, PagePosition, PageStability, RowIdentity, TableRef};
use crate::query_result::QueryResult;
use crate::value::Value;

use super::*;

fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        },
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn bigint() -> ColumnKind {
    ColumnKind::Integer(IntegerKind {
        width: IntegerWidth::W64,
        signed: true,
    })
}

fn columns() -> Vec<ColumnInfo> {
    vec![
        column("id", bigint()),
        column(
            "name",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        ),
    ]
}

fn table() -> TableRef {
    TableRef::new(Some("public".to_owned()), "users")
}

fn by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }
}

fn adults() -> FilterSet {
    FilterSet {
        combinator: Combinator::Or,
        rules: vec![
            FilterRule {
                column: "id".to_owned(),
                op: FilterOp::Gt,
                value: Some(FilterValue::Single("18".to_owned())),
            },
            FilterRule {
                column: "name".to_owned(),
                op: FilterOp::IsNull,
                value: None,
            },
        ],
        extra_sql: None,
    }
}

struct Page {
    identity: RowIdentity,
    filter: FilterSet,
    sort: Vec<SortKey>,
    position: PagePosition,
}

impl Page {
    fn of(identity: RowIdentity) -> Self {
        Self {
            identity,
            filter: FilterSet::default(),
            sort: Vec::new(),
            position: PagePosition::First,
        }
    }

    fn at(self, position: PagePosition) -> Self {
        Self { position, ..self }
    }

    fn filtered(self, filter: FilterSet) -> Self {
        Self { filter, ..self }
    }

    fn sorted(self, sort: Vec<SortKey>) -> Self {
        Self { sort, ..self }
    }

    fn build(&self, dialect: &TestDialect) -> Result<PageSpec, BrowseSqlError> {
        let columns = columns();
        let table = table();
        build_page(
            dialect,
            &PageRequest {
                table: &table,
                columns: &columns,
                filter: &self.filter,
                sort: &self.sort,
                identity: &self.identity,
                position: &self.position,
                limit: 50,
            },
        )
    }
}

fn built(page: &Page, dialect: &TestDialect) -> PageSpec {
    match page.build(dialect) {
        Ok(spec) => spec,
        Err(error) => panic!("the page did not build: {error}"),
    }
}

#[test]
fn build_page_keyset_after_uses_row_value_after() {
    let dialect = TestDialect::exact();
    let page = Page::of(by_id()).at(PagePosition::AfterKey(vec![Value::Int(40)]));

    let spec = built(&page, &dialect);

    assert_eq!(
        spec.statement.sql(),
        r#"SELECT "id", "name" FROM "public"."users" WHERE ("users"."id") > ($1) ORDER BY "users"."id" ASC LIMIT 50"#
    );
    assert_eq!(spec.statement.params()[0].value(), &Value::Int(40));
    assert_eq!(dialect.targets(), vec![RecordedTarget::Column("id".to_owned())]);
    assert_eq!(spec.stability, PageStability::Stable);
    assert_eq!(spec.cost, PageCost::KeySeek);
}

#[test]
fn a_keyset_page_backward_reverses_the_order_after_the_filter() {
    let dialect = TestDialect::exact().with_markers(TestMarkers::Positional);
    let page = Page::of(by_id())
        .filtered(adults())
        .at(PagePosition::BeforeKey(vec![Value::Int(40)]));

    let spec = built(&page, &dialect);

    assert_eq!(
        spec.statement.sql(),
        r#"SELECT "id", "name" FROM "public"."users" WHERE ("id" > ? OR "name" IS NULL) AND (("users"."id") < (?)) ORDER BY "users"."id" DESC LIMIT 50"#
    );
    let values: Vec<_> = spec
        .statement
        .params()
        .iter()
        .map(|param| param.value().clone())
        .collect();
    assert_eq!(
        values,
        vec![Value::Int(18), Value::Int(40)],
        "a positional marker took the wrong value"
    );
}

#[test]
fn build_page_user_sort_appends_identity_tiebreak() {
    let dialect = TestDialect::exact();
    let page = Page::of(by_id())
        .sorted(vec![SortKey {
            column: 1,
            ascending: false,
        }])
        .at(PagePosition::Offset(100));

    let spec = built(&page, &dialect);

    assert_eq!(
        spec.statement.sql(),
        r#"SELECT "id", "name" FROM "public"."users" ORDER BY "users"."name" DESC, "users"."id" ASC LIMIT 50 OFFSET 100"#
    );
    assert_eq!(spec.stability, PageStability::Stable);
    assert_eq!(spec.cost, PageCost::SortPerPage);
}

#[test]
fn a_sort_on_the_key_itself_is_not_repeated_as_its_tiebreak() {
    let page = Page::of(by_id()).sorted(vec![SortKey {
        column: 0,
        ascending: false,
    }]);

    let spec = built(&page, &TestDialect::exact());

    assert!(
        spec.statement.sql().ends_with(r#"ORDER BY "users"."id" DESC LIMIT 50"#),
        "{}",
        spec.statement.sql()
    );
}

#[test]
fn build_page_ctid_window_bounds() {
    let dialect = TestDialect::exact();
    let page = Page::of(RowIdentity::EngineRowId(EngineRowId::PostgresCtid)).at(PagePosition::CtidWindow {
        after: Some((3, 7)),
        end_block: 10,
    });

    let spec = built(&page, &dialect);

    assert_eq!(
        spec.statement.sql(),
        r#"SELECT "id", "name", ctid AS "__tablepro_row_id", xmin AS "__tablepro_row_xmin" FROM "public"."users" WHERE ctid > $1 AND ctid < $2 ORDER BY ctid ASC LIMIT 50"#
    );
    let bounds: Vec<_> = spec
        .statement
        .params()
        .iter()
        .map(|param| param.value().clone())
        .collect();
    assert_eq!(
        bounds,
        vec![Value::Text("(3,7)".to_owned()), Value::Text("(10,0)".to_owned())]
    );
    assert_eq!(
        dialect.targets(),
        vec![
            RecordedTarget::EngineRowId(EngineRowIdPart::PostgresCtid),
            RecordedTarget::EngineRowId(EngineRowIdPart::PostgresCtid),
        ]
    );
    assert_eq!(spec.cost, PageCost::BlockWindow);
}

#[test]
fn the_first_ctid_window_has_only_its_upper_bound() {
    let page = Page::of(RowIdentity::EngineRowId(EngineRowId::PostgresCtid)).at(PagePosition::CtidWindow {
        after: None,
        end_block: 4,
    });

    let spec = built(&page, &TestDialect::exact());

    assert!(
        spec.statement.sql().contains("WHERE ctid < $1 ORDER BY"),
        "{}",
        spec.statement.sql()
    );
    assert_eq!(spec.statement.params().len(), 1);
}

#[test]
fn build_count_reuses_filter_predicate() {
    let dialect = TestDialect::exact();
    let filter = adults();

    let count = build_count(&dialect, &table(), &columns(), &filter).expect("the count");
    let page = built(&Page::of(by_id()).filtered(filter), &TestDialect::exact());

    assert_eq!(
        count.sql(),
        r#"SELECT COUNT(*) FROM "public"."users" WHERE "id" > $1 OR "name" IS NULL"#
    );
    assert!(
        page.statement.sql().contains(r#"WHERE "id" > $1 OR "name" IS NULL "#),
        "the page and the count filter differently: {}",
        page.statement.sql()
    );
    assert_eq!(count.params(), page.statement.params());
}

#[test]
fn build_count_counts_with_the_dialects_expression() {
    let dialect = TestDialect::exact().counting_with("COUNT_BIG(*)");

    let count = build_count(&dialect, &table(), &columns(), &FilterSet::default()).expect("the count");

    assert_eq!(count.sql(), r#"SELECT COUNT_BIG(*) FROM "public"."users""#);
}

#[test]
fn build_page_layout_identity_follows_visible() {
    let cases = [
        (by_id(), 0, RowKeyLayout::Columns(vec![0])),
        (
            RowIdentity::EngineRowId(EngineRowId::SqliteRowid),
            1,
            RowKeyLayout::EngineRowId {
                first_hidden: 2,
                parts: EngineRowId::SqliteRowid.parts(),
            },
        ),
        (
            RowIdentity::EngineRowId(EngineRowId::PostgresCtid),
            2,
            RowKeyLayout::EngineRowId {
                first_hidden: 2,
                parts: EngineRowId::PostgresCtid.parts(),
            },
        ),
        (
            RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid),
            3,
            RowKeyLayout::EngineRowId {
                first_hidden: 2,
                parts: EngineRowId::PostgresTableoidCtid.parts(),
            },
        ),
        (RowIdentity::Unordered, 0, RowKeyLayout::ReadOnly),
    ];

    for (identity, hidden, row_key) in cases {
        let spec = built(&Page::of(identity.clone()), &TestDialect::exact());

        assert_eq!(spec.layout.visible, 0..2, "{identity:?}");
        assert_eq!(spec.layout.identity, 2..2 + hidden, "{identity:?}");
        assert_eq!(spec.row_key, row_key, "{identity:?}");
        assert_eq!(spec.visible_columns(), 2);
    }
}

#[test]
fn a_page_of_an_unkeyed_table_is_read_only_and_says_its_order_is_not_stable() {
    let spec = built(&Page::of(RowIdentity::Unordered), &TestDialect::exact());

    assert_eq!(
        spec.statement.sql(),
        r#"SELECT "id", "name" FROM "public"."users" LIMIT 50"#
    );
    assert_eq!(spec.stability, PageStability::Unordered);
    assert!(spec.row_key.is_read_only());
}

#[test]
fn a_sorting_key_orders_but_is_not_unique() {
    let identity = RowIdentity::SortingKey {
        expressions: vec!["name".to_owned()],
    };

    let spec = built(&Page::of(identity), &TestDialect::estimated());

    assert!(
        spec.statement
            .sql()
            .ends_with(r#"ORDER BY "users"."name" ASC LIMIT 50"#),
        "{}",
        spec.statement.sql()
    );
    assert_eq!(spec.stability, PageStability::NonUniqueOrder);
    assert_eq!(spec.row_key, RowKeyLayout::Columns(vec![1]));
}

#[test]
fn a_position_the_mode_cannot_read_is_an_error() {
    let ctid_after_key = Page::of(RowIdentity::EngineRowId(EngineRowId::PostgresCtid))
        .at(PagePosition::AfterKey(vec![Value::Text("(0,1)".to_owned())]));
    let sorted_after_key = Page::of(by_id())
        .sorted(vec![SortKey {
            column: 1,
            ascending: true,
        }])
        .at(PagePosition::AfterKey(vec![Value::Int(1)]));

    assert_eq!(
        ctid_after_key.build(&TestDialect::exact()),
        Err(BrowseSqlError::UnsupportedPosition {
            mode: PagingMode::CtidWindow
        })
    );
    assert_eq!(
        sorted_after_key.build(&TestDialect::exact()),
        Err(BrowseSqlError::UnsupportedPosition {
            mode: PagingMode::Offset
        })
    );
}

#[test]
fn a_keyset_anchor_must_be_a_whole_readable_key() {
    let null = Page::of(by_id()).at(PagePosition::AfterKey(vec![Value::Null]));
    let short = Page::of(by_id()).at(PagePosition::AfterKey(Vec::new()));

    assert_eq!(null.build(&TestDialect::exact()), Err(BrowseSqlError::NullAnchor));
    assert!(matches!(
        short.build(&TestDialect::exact()),
        Err(BrowseSqlError::Build(crate::dml::BuildSqlError::LengthMismatch { .. }))
    ));
}

#[test]
fn a_raw_predicate_saved_before_validation_is_refused_on_replay() {
    let page = Page::of(by_id()).filtered(FilterSet {
        extra_sql: Some("1=1) OR (1=1".to_owned()),
        ..FilterSet::default()
    });

    assert!(matches!(
        page.build(&TestDialect::exact()),
        Err(BrowseSqlError::Filter(crate::filter::BuildFilterError::RawPredicate(_)))
    ));
}

#[test]
fn an_unknown_sort_column_is_an_error() {
    let page = Page::of(by_id()).sorted(vec![SortKey {
        column: 9,
        ascending: true,
    }]);

    assert_eq!(
        page.build(&TestDialect::exact()),
        Err(BrowseSqlError::UnknownSortColumn(9))
    );
}

#[test]
fn build_export_projects_only_visible_columns() {
    let dialect = TestDialect::exact();
    let columns = columns();
    let identity = RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid);
    let filter = adults();
    let sort = [SortKey {
        column: 1,
        ascending: true,
    }];

    let statement = build_export(
        &dialect,
        &ExportRequest {
            table: &table(),
            columns: &columns,
            filter: &filter,
            sort: &sort,
            identity: &identity,
        },
    )
    .expect("the export");

    let sql = statement.sql();
    let projection = sql
        .strip_prefix("SELECT ")
        .and_then(|rest| rest.split_once(" FROM "))
        .map(|(projection, _)| projection);
    assert_eq!(
        projection,
        Some(r#""id", "name""#),
        "an engine row id reached the export"
    );
    assert_eq!(
        sql,
        r#"SELECT "id", "name" FROM "public"."users" WHERE "id" > $1 OR "name" IS NULL ORDER BY "users"."name" ASC, tableoid ASC, ctid ASC"#
    );
}

#[test]
fn a_page_splits_into_keys_the_dml_can_bind_back() {
    let dialect = TestDialect::exact();
    let identity = RowIdentity::EngineRowId(EngineRowId::SqliteRowid);
    let spec = built(&Page::of(identity.clone()), &dialect);
    let result = QueryResult {
        columns: ["id", "name", "__tablepro_row_id"]
            .iter()
            .map(|name| crate::column::ResultColumn::new(*name, ColumnType::untyped_text("t")))
            .collect::<Vec<_>>()
            .into(),
        rows: vec![vec![Value::Int(1), Value::Text("a".to_owned()), Value::Int(77)]],
        truncated: false,
    };

    let page = split_page(result, &spec).expect("the page");
    let key = page.key(0).cloned().expect("an editable row");
    let delete = crate::dml::build_delete(&dialect, &table(), &columns(), &identity, &key).expect("the delete");

    assert_eq!(page.columns.len(), 2, "the row id reached the grid");
    assert_eq!(delete.sql(), r#"DELETE FROM "public"."users" WHERE rowid = $1"#);
    assert_eq!(delete.params()[0].value(), &Value::Int(77));
}
