use super::*;
use crate::dialect::{SqlDialect, TestDialect};
use crate::meta::TableRef;
use crate::sql_syntax::SqlGrammar;
use crate::write_batch::WriteKind;

#[derive(Debug)]
struct CatalogDdl {
    capabilities: DdlCapabilities,
    catalog: CatalogCapabilities,
    sql: TestDialect,
}

impl DdlDialect for CatalogDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        &self.sql
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        &["integer"]
    }

    fn default_column_type(&self) -> &'static str {
        "text"
    }

    fn plan_create_table(&self, _draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        Ok(DdlPlan::from_sql(Vec::new()))
    }

    fn plan_alter_table(&self, _original: &TableDefinition, _changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        Ok(DdlPlan::from_sql(Vec::new()))
    }

    fn catalog_capabilities(&self) -> CatalogCapabilities {
        self.catalog
    }
}

fn every_operation() -> CatalogCapabilities {
    CatalogCapabilities {
        truncate_table: true,
        truncate_cascade: true,
        truncate_restart_identity: true,
        create_schema: true,
        drop_schema: true,
        drop_schema_cascade: true,
        schema_owner: true,
        create_database: true,
        drop_database: true,
        ..CatalogCapabilities::default()
    }
}

fn ddl(catalog: CatalogCapabilities) -> CatalogDdl {
    CatalogDdl {
        capabilities: DdlCapabilities::default(),
        catalog,
        sql: TestDialect::exact(),
    }
}

#[test]
fn a_default_truncate_writes_the_options_the_engine_takes() {
    let table = TableRef::new(Some("app".to_owned()), "or\"ders");
    let both = TruncateTableOptions {
        cascade: true,
        restart_identity: true,
        cluster: None,
    };

    let plan = ddl(every_operation())
        .plan_truncate_table(&table, &both)
        .expect("a plan");

    assert_eq!(
        plan.sql(),
        ["TRUNCATE TABLE \"app\".\"or\"\"ders\" RESTART IDENTITY CASCADE"]
    );
    assert_eq!(plan.kind, WriteKind::SchemaChanges);
    let plain = CatalogCapabilities {
        truncate_table: true,
        ..CatalogCapabilities::default()
    };
    assert_eq!(
        ddl(plain).plan_truncate_table(&table, &both),
        Err(BuildDdlError::Unsupported(DdlOperation::TruncateTableCascade))
    );
    assert_eq!(
        ddl(CatalogCapabilities::default()).plan_truncate_table(&table, &TruncateTableOptions::default()),
        Err(BuildDdlError::Unsupported(DdlOperation::TruncateTable))
    );
    let on_cluster = TruncateTableOptions {
        cluster: Some("main".to_owned()),
        ..TruncateTableOptions::default()
    };
    assert_eq!(
        ddl(plain).plan_truncate_table(&table, &on_cluster),
        Err(BuildDdlError::Unsupported(DdlOperation::OnCluster))
    );
}

#[test]
fn a_default_schema_plan_quotes_its_name_and_owner() {
    let draft = SchemaDraft {
        name: "sa\"les".to_owned(),
        owner: Some("ann".to_owned()),
    };

    let created = ddl(every_operation()).plan_create_schema(&draft).expect("a plan");
    let dropped = ddl(every_operation())
        .plan_drop_schema("sales", DropSchemaOptions { cascade: true })
        .expect("a plan");

    assert_eq!(created.sql(), ["CREATE SCHEMA \"sa\"\"les\" AUTHORIZATION \"ann\""]);
    assert_eq!(dropped.sql(), ["DROP SCHEMA \"sales\" CASCADE"]);
    let no_owner = CatalogCapabilities {
        schema_owner: false,
        ..every_operation()
    };
    assert_eq!(
        ddl(no_owner).plan_create_schema(&draft),
        Err(BuildDdlError::Unsupported(DdlOperation::CatalogOwner))
    );
    let empty = SchemaDraft {
        name: "  ".to_owned(),
        owner: None,
    };
    assert!(matches!(
        ddl(every_operation()).plan_create_schema(&empty),
        Err(BuildDdlError::InvalidOption {
            option: CatalogOption::Name,
            ..
        })
    ));
}

#[test]
fn a_database_plan_runs_outside_a_transaction_and_refuses_options_it_has_no_place_for() {
    let created = ddl(every_operation())
        .plan_create_database(&DatabaseDraft::named("shop"))
        .expect("a plan");
    let dropped = ddl(every_operation())
        .plan_drop_database("shop", &DropDatabaseOptions::default())
        .expect("a plan");

    assert_eq!(created.sql(), ["CREATE DATABASE \"shop\""]);
    assert_eq!(created.kind, WriteKind::DatabaseChanges);
    assert_eq!(dropped.sql(), ["DROP DATABASE \"shop\""]);
    assert_eq!(
        dropped.into_write_batch(TableRef::unqualified("shop")).kind,
        WriteKind::DatabaseChanges
    );
    let with_template = DatabaseDraft {
        template: Some("template0".to_owned()),
        ..DatabaseDraft::named("shop")
    };
    assert!(matches!(
        ddl(every_operation()).plan_create_database(&with_template),
        Err(BuildDdlError::InvalidOption {
            option: CatalogOption::Template,
            ..
        })
    ));
    let forced = DropDatabaseOptions {
        force: true,
        cluster: None,
    };
    assert_eq!(
        ddl(every_operation()).plan_drop_database("shop", &forced),
        Err(BuildDdlError::Unsupported(DdlOperation::DropDatabaseForce))
    );
}

#[test]
fn a_bare_word_is_letters_digits_and_underscores() {
    assert_eq!(
        bare_word(CatalogOption::Collation, "utf8mb4_0900_ai_ci"),
        Ok("utf8mb4_0900_ai_ci")
    );
    for refused in ["", "latin1'; DROP", "a b", "a-b"] {
        assert!(bare_word(CatalogOption::Collation, refused).is_err(), "{refused:?}");
    }
}

#[test]
fn mongodb_empties_a_collection_and_makes_a_database_through_its_shell() {
    let shell = TestDialect::exact().parsing_as(SqlGrammar::Mongo);
    let table = TableRef::new(Some("shop".to_owned()), "orders");

    let emptied = plan_truncate_table(&shell, &table, &TruncateTableOptions::default()).expect("a plan");
    let mut draft = DatabaseDraft::named("shop");
    draft.first_collection = Some("orders".to_owned());
    let created = plan_create_database(&shell, &draft).expect("a plan");
    let dropped = plan_drop_database(&shell, "shop", &DropDatabaseOptions::default()).expect("a plan");

    assert_eq!(
        emptied.sql(),
        [r#"db.getSiblingDB("shop").getCollection("orders").deleteMany({})"#]
    );
    assert_eq!(created.sql(), [r#"db.getSiblingDB("shop").createCollection("orders")"#]);
    assert_eq!(dropped.sql(), [r#"db.getSiblingDB("shop").dropDatabase()"#]);
    assert_eq!(
        (created.kind, dropped.kind),
        (WriteKind::DatabaseChanges, WriteKind::DatabaseChanges)
    );
    assert_eq!(emptied.kind, WriteKind::SchemaChanges);
    assert!(protects_database(&shell, "admin") && !protects_database(&shell, "shop"));
    let capabilities = catalog_capabilities(&shell);
    assert!(capabilities.truncate_table && capabilities.create_database && capabilities.drop_database);
    assert!(!capabilities.create_schema && capabilities.database_fields.first_collection);
    assert!(matches!(
        plan_create_database(&shell, &DatabaseDraft::named("shop")),
        Err(BuildDdlError::InvalidOption {
            option: CatalogOption::Collection,
            ..
        })
    ));
    let cascade = TruncateTableOptions {
        cascade: true,
        ..TruncateTableOptions::default()
    };
    assert_eq!(
        plan_truncate_table(&shell, &table, &cascade),
        Err(BuildDdlError::Unsupported(DdlOperation::TruncateTableCascade))
    );
}

#[test]
fn an_engine_without_a_ddl_dialect_offers_nothing() {
    let plain = TestDialect::exact();

    assert_eq!(catalog_capabilities(&plain), CatalogCapabilities::default());
    assert_eq!(
        plan_create_schema(&plain, &SchemaDraft::default()),
        Err(BuildDdlError::Unsupported(DdlOperation::CreateSchema))
    );
}

#[test]
fn a_name_longer_than_the_server_keeps_is_refused() {
    let limited = CatalogCapabilities {
        name_limit: Some(NameLimit::Bytes(4)),
        ..every_operation()
    };

    assert!(ddl(limited).plan_create_database(&DatabaseDraft::named("shop")).is_ok());
    assert!(matches!(
        ddl(limited).plan_create_database(&DatabaseDraft::named("shops")),
        Err(BuildDdlError::InvalidOption {
            option: CatalogOption::Name,
            ..
        })
    ));
    assert!(NameLimit::Chars(3).admits("ŝöp"));
    assert!(!NameLimit::Bytes(4).admits("ŝöp"));
}
