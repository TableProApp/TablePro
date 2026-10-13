//! Structure changes the MySQL dialect plans, run against both servers.

use tablepro_core::Connection;
use tablepro_core::ddl::{
    BuildDdlError, ColumnVisibility, DdlOperation, RefusalReason, TableDefinition, TableDraft, diff_table,
};
use tablepro_test_fixtures::MysqlFlavour;

use crate::support::{CALL, FLAVOURS, connect, setup, start, table, within};

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&table("kept"), within(CALL))
        .await
        .expect("the definition")
}

fn edit(
    definition: &TableDefinition,
    name: &str,
    change: impl FnOnce(&mut tablepro_core::ddl::DraftColumn),
) -> TableDraft {
    let mut draft = TableDraft::from_definition(definition);
    if let Some(column) = draft.columns.iter_mut().find(|column| column.name == name) {
        change(column);
    }
    draft
}

/// MODIFY replaces the whole definition, so each attribute the column
/// had is gone unless the plan writes it again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_restated_column_keeps_its_modeled_attributes() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        let spatial = match flavour {
            MysqlFlavour::Mysql => ", shape point NOT NULL SRID 4326",
            MysqlFlavour::Mariadb => "",
        };
        setup(
            connection.as_ref(),
            &[&format!(
                "CREATE TABLE kept (\
                 id int PRIMARY KEY, \
                 code varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL, \
                 changed timestamp(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3), \
                 hidden int NULL INVISIBLE, \
                 base int NULL, \
                 doubled int GENERATED ALWAYS AS (base * 2) STORED{spatial})"
            )],
        )
        .await;
        let original = read(connection.as_ref()).await;
        let dialect = connection.dialect();
        let ddl = dialect.ddl().expect("MySQL plans its DDL");

        let mut draft = TableDraft::from_definition(&original);
        for column in &mut draft.columns {
            match column.name.as_str() {
                "code" => column.nullable = false,
                "changed" | "hidden" | "shape" => column.comment = Some("touched".to_owned()),
                _ => {}
            }
        }
        let plan = ddl
            .plan_alter_table(&original, &diff_table(&original, &draft))
            .expect("the change plans");
        connection
            .write_batch(&plan.into_write_batch(table("kept")), within(CALL))
            .await
            .expect("the change runs");
        let after = read(connection.as_ref()).await;

        let code = after.column("code").expect("code");
        assert!(!code.info.nullable, "{flavour:?}");
        assert_eq!(
            code.attributes
                .collation
                .as_ref()
                .map(|collation| collation.name.as_str()),
            Some("utf8mb4_bin"),
            "{flavour:?}"
        );
        let changed = after.column("changed").expect("changed");
        assert_eq!(changed.info.comment.as_deref(), Some("touched"), "{flavour:?}");
        assert!(
            changed
                .attributes
                .on_update
                .as_ref()
                .is_some_and(|expression| expression
                    .as_sql()
                    .to_ascii_lowercase()
                    .starts_with("current_timestamp")),
            "{flavour:?}: {:?}",
            changed.attributes.on_update
        );
        let hidden = after.column("hidden").expect("hidden");
        assert_eq!(hidden.attributes.visibility, ColumnVisibility::Invisible, "{flavour:?}");
        if flavour == MysqlFlavour::Mysql {
            let shape = after.column("shape").expect("shape");
            assert_eq!(shape.attributes.spatial_reference, Some(4326));
            assert_eq!(shape.info.comment.as_deref(), Some("touched"));
        }

        let computed = edit(&after, "doubled", |column| column.comment = Some("x".to_owned()));
        let refused = ddl.plan_alter_table(&after, &diff_table(&after, &computed));
        assert!(
            matches!(
                refused,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::SetColumnComment,
                    reason: RefusalReason::GeneratedColumn,
                    ..
                })
            ),
            "{flavour:?}: {refused:?}"
        );
        connection.close().await.expect("a close");
    }
}
