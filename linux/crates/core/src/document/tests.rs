use crate::browse::{ExportRequest, PageRequest, RowKeyLayout, SortKey, build_count, build_export, build_page};
use crate::column::{
    ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, TextLength,
};
use crate::dialect::TestDialect;
use crate::dml::{BuildSqlError, build_delete, build_insert, build_multi_row_insert, build_update};
use crate::edit::CellInput;
use crate::filter::{BuildFilterError, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, build_filter};
use crate::meta::{PagePosition, PageStability, RowIdentity, TableRef};
use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::mongo::parse_bound_statement;
use crate::statement::{ParamType, Statement, StatementBuilder};
use crate::value::{OtherValue, Value};

fn shell() -> TestDialect {
    TestDialect::exact().parsing_as(SqlGrammar::Mongo)
}

fn column(name: &str, type_name: &str, kind: ColumnKind) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType {
            name: type_name.to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        },
        nullable: true,
        primary_key: name == "_id",
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn columns() -> Vec<ColumnInfo> {
    vec![
        column("_id", "objectId", ColumnKind::Other),
        column(
            "name",
            "string",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        ),
        column(
            "qty",
            "int",
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
        ),
        column(
            "a.b",
            "string",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        ),
    ]
}

fn by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["_id".to_owned()],
    }
}

fn users() -> TableRef {
    TableRef::new(Some("shop".to_owned()), "users")
}

fn object_id() -> Value {
    Value::Other(Box::new(OtherValue {
        type_name: "objectId".to_owned(),
        text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
    }))
}

/// The statement reads back as a bound shell statement, which is what
/// the driver does with it.
fn checked(statement: &Statement) -> &str {
    let parsed = parse_bound_statement(statement.sql(), statement.params().len());
    assert!(parsed.is_ok(), "{}: {parsed:?}", statement.sql());
    statement.sql()
}

fn page_at(position: &PagePosition, sort: &[SortKey], filter: &FilterSet) -> Statement {
    let columns = columns();
    let request = PageRequest {
        table: &users(),
        columns: &columns,
        filter,
        sort,
        identity: &by_id(),
        position,
        limit: 50,
    };
    let spec = build_page(&shell(), &request).expect("a page");
    assert_eq!(spec.layout.width(), 4);
    spec.statement
}

const PROJECTION: &str = r#"{"$project": {"_id": 1, "name": 1, "qty": 1, "__field_3": {"$getField": {"field": {"$literal": "a.b"}, "input": "$$ROOT"}}}}"#;

#[test]
fn the_first_page_seeks_on_the_id_and_projects_the_columns_in_order() {
    let statement = page_at(&PagePosition::First, &[], &FilterSet::default());

    assert_eq!(
        checked(&statement),
        format!(
            r#"db.getSiblingDB("shop").getCollection("users").aggregate([{{"$sort": {{"_id": 1}}}}, {{"$limit": 50}}, {PROJECTION}], {{"allowDiskUse": true}})"#
        )
    );
}

#[test]
fn a_later_page_reads_past_the_key_and_into_the_types_sorted_after_it() {
    let statement = page_at(&PagePosition::AfterKey(vec![object_id()]), &[], &FilterSet::default());

    assert!(
        checked(&statement).contains(
            r#"{"$match": {"$or": [{"_id": {"$gt": $1}}, {"_id": {"$type": ["bool", "date", "timestamp", "regex", "maxKey"]}}]}}, {"$sort": {"_id": 1}}"#
        ),
        "{}",
        statement.sql()
    );
    assert_eq!(statement.params()[0].value(), &object_id());
    assert!(matches!(statement.params()[0].param_type(), ParamType::ServerText(_)));

    let before = page_at(
        &PagePosition::BeforeKey(vec![Value::Int(7)]),
        &[],
        &FilterSet::default(),
    );
    assert!(
        checked(&before).contains(
            r#"{"$match": {"$or": [{"_id": {"$lt": $1}}, {"_id": {"$type": ["minKey", "null"]}}]}}, {"$sort": {"_id": -1}}"#
        ),
        "{}",
        before.sql()
    );
}

#[test]
fn a_sorted_page_ends_its_order_on_the_id_and_skips_to_its_offset() {
    let sort = [SortKey {
        column: 1,
        ascending: false,
    }];
    let statement = page_at(&PagePosition::Offset(100), &sort, &FilterSet::default());

    assert!(
        checked(&statement).contains(r#"[{"$sort": {"name": -1, "_id": 1}}, {"$skip": 100}, {"$limit": 50}"#),
        "{}",
        statement.sql()
    );
    let columns = columns();
    let dotted = [SortKey {
        column: 3,
        ascending: true,
    }];
    let refused = build_page(
        &shell(),
        &PageRequest {
            table: &users(),
            columns: &columns,
            filter: &FilterSet::default(),
            sort: &dotted,
            identity: &by_id(),
            position: &PagePosition::First,
            limit: 50,
        },
    );
    assert!(refused.is_err(), "a sort named a dotted field");
}

fn filter() -> FilterSet {
    FilterSet {
        combinator: Combinator::And,
        rules: vec![
            FilterRule {
                column: "name".to_owned(),
                op: FilterOp::Contains,
                value: Some(FilterValue::Single("a.b".to_owned())),
            },
            FilterRule {
                column: "qty".to_owned(),
                op: FilterOp::Between,
                value: Some(FilterValue::Pair("1".to_owned(), "5".to_owned())),
            },
        ],
        extra_sql: Some("{ tags: { $in: ['x'] } }".to_owned()),
    }
}

#[test]
fn a_filter_binds_what_was_typed_and_keeps_the_typed_document() {
    let statement = build_count(&shell(), &users(), &columns(), &filter()).expect("a count");

    assert_eq!(
        checked(&statement),
        r#"db.getSiblingDB("shop").getCollection("users").countDocuments({"$and": [{"name": {"$regex": $1, "$options": ""}}, {"qty": {"$gte": $2, "$lte": $3}}, {"tags": {"$in": ["x"]}}]})"#
    );
    let values: Vec<&Value> = statement.params().iter().map(|param| param.value()).collect();
    assert_eq!(
        values,
        [&Value::Text(r"a\.b".to_owned()), &Value::Int(1), &Value::Int(5)]
    );
    assert_eq!(statement.params()[1].param_type(), &ParamType::Int32);
}

#[test]
fn a_filter_that_is_not_one_document_or_names_a_dotted_field_is_refused() {
    let mut builder = StatementBuilder::new();
    let typed = |text: &str| FilterSet {
        extra_sql: Some(text.to_owned()),
        ..FilterSet::default()
    };

    assert!(matches!(
        build_filter(&mut builder, &shell(), &columns(), &typed("{a: 1}).drop(")),
        Err(BuildFilterError::RawDocument(_))
    ));
    assert_eq!(
        build_filter(&mut builder, &shell(), &columns(), &typed("'x'")),
        Err(BuildFilterError::RawNotDocument)
    );
    let dotted = FilterSet {
        rules: vec![FilterRule {
            column: "a.b".to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("x".to_owned())),
        }],
        ..FilterSet::default()
    };
    assert_eq!(
        build_filter(&mut builder, &shell(), &columns(), &dotted),
        Err(BuildFilterError::UnaddressableField("a.b".to_owned()))
    );
}

#[test]
fn build_filter_writes_the_document_after_parameters_already_bound() {
    let mut builder = StatementBuilder::new();
    builder.push_bound(crate::document::bind_param(Value::Int(1), None).expect("a param"));

    assert_eq!(build_filter(&mut builder, &shell(), &columns(), &filter()), Ok(true));

    let statement = builder.finish();
    assert!(
        statement.sql().starts_with(r#"{"$and": [{"name": {"$regex": $2"#),
        "{}",
        statement.sql()
    );
    assert_eq!(statement.params().len(), 4);
}

#[test]
fn a_view_pages_by_offset_in_its_own_order_and_takes_no_edits() {
    let columns = columns();
    let page = |position: &PagePosition, sort: &[SortKey]| {
        let request = PageRequest {
            table: &users(),
            columns: &columns,
            filter: &FilterSet::default(),
            sort,
            identity: &RowIdentity::Unordered,
            position,
            limit: 50,
        };
        build_page(&shell(), &request).expect("a page")
    };

    let first = page(&PagePosition::First, &[]);
    let later = page(
        &PagePosition::Offset(100),
        &[SortKey {
            column: 2,
            ascending: false,
        }],
    );

    assert_eq!(
        checked(&first.statement),
        format!(
            r#"db.getSiblingDB("shop").getCollection("users").aggregate([{{"$limit": 50}}, {PROJECTION}], {{"allowDiskUse": true}})"#
        )
    );
    assert_eq!(first.row_key, RowKeyLayout::ReadOnly);
    assert_eq!(first.stability, PageStability::Unordered);
    assert!(
        checked(&later.statement).contains(r#"[{"$sort": {"qty": -1}}, {"$skip": 100}, {"$limit": 50}"#),
        "{}",
        later.statement.sql()
    );
    assert_eq!(later.stability, PageStability::NonUniqueOrder);
}

#[test]
fn an_alias_never_takes_the_name_of_a_field() {
    let mut columns = columns();
    columns.push(column(
        "__field_3",
        "string",
        ColumnKind::Text {
            length: TextLength::Unbounded,
        },
    ));
    let request = PageRequest {
        table: &users(),
        columns: &columns,
        filter: &FilterSet::default(),
        sort: &[],
        identity: &by_id(),
        position: &PagePosition::First,
        limit: 50,
    };

    let spec = build_page(&shell(), &request).expect("a page");

    let text = checked(&spec.statement);
    assert!(text.contains(r#""___field_3": {"$getField""#), "{text}");
    assert!(text.contains(r#""__field_3": 1"#), "{text}");
}

#[test]
fn an_export_reads_every_document_in_page_order() {
    let columns = columns();
    let sort = [SortKey {
        column: 2,
        ascending: true,
    }];
    let statement = build_export(
        &shell(),
        &ExportRequest {
            table: &TableRef::unqualified("users"),
            columns: &columns,
            filter: &FilterSet::default(),
            sort: &sort,
            identity: &by_id(),
        },
    )
    .expect("an export");

    assert_eq!(
        checked(&statement),
        format!(
            r#"db.getCollection("users").aggregate([{{"$sort": {{"qty": 1, "_id": 1}}}}, {PROJECTION}], {{"allowDiskUse": true}})"#
        )
    );
}

#[test]
fn a_change_names_its_document_by_id_and_sets_only_the_fields_changed() {
    let dialect = shell();
    let table = users();
    let update = build_update(
        &dialect,
        &table,
        &columns(),
        &by_id(),
        &[object_id()],
        &[(1, Value::Text("ann".to_owned())), (2, Value::Null)],
    )
    .expect("an update");
    assert_eq!(
        checked(&update),
        r#"db.getSiblingDB("shop").getCollection("users").updateOne({"_id": $3}, {"$set": {"name": $1, "qty": $2}})"#
    );
    assert_eq!(
        update.params()[1].param_type(),
        &ParamType::Int32,
        "a null keeps its field's type"
    );

    let delete = build_delete(&dialect, &table, &columns(), &by_id(), &[object_id()]).expect("a delete");
    assert_eq!(
        checked(&delete),
        r#"db.getSiblingDB("shop").getCollection("users").deleteOne({"_id": $1})"#
    );

    let insert = build_insert(
        &dialect,
        &table,
        &columns(),
        &[
            CellInput::Default,
            CellInput::Value(Value::Text("ann".to_owned())),
            CellInput::Value(Value::Int(3)),
            CellInput::Default,
        ],
    )
    .expect("an insert");
    assert_eq!(
        checked(&insert),
        r#"db.getSiblingDB("shop").getCollection("users").insertOne({"name": $1, "qty": $2})"#
    );

    let columns = columns();
    let many = build_multi_row_insert(
        &dialect,
        &table,
        &[&columns[1], &columns[2]],
        vec![
            vec![Value::Text("a".to_owned()), Value::Int(1)],
            vec![Value::Text("b".to_owned()), Value::Int(2)],
        ],
    )
    .expect("an insert of two");
    assert_eq!(
        checked(&many),
        r#"db.getSiblingDB("shop").getCollection("users").insertMany([{"name": $1, "qty": $2}, {"name": $3, "qty": $4}])"#
    );
}

#[test]
fn a_dotted_field_cannot_be_updated_by_name() {
    let refused = build_update(
        &shell(),
        &users(),
        &columns(),
        &by_id(),
        &[object_id()],
        &[(3, Value::Text("x".to_owned()))],
    );

    assert_eq!(
        refused,
        Err(BuildSqlError::UnaddressableField { name: "a.b".to_owned() })
    );
}
