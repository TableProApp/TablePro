//! The SQL dump round trip on SQL Server.

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, ConnectTarget, DatabaseDriver, EditorSession, EditorSessionOptions, RunEnd, RunOptions, UserSql,
    WorkspaceSettings,
};
use tablepro_driver_mssql::MssqlDriver;
use tablepro_test_support::conformance::{ConformanceEngine, ConformanceFailure, DumpEngine, test_liveness};
use tokio_util::sync::CancellationToken;

use crate::conformance_engine::MssqlEngine;
use crate::support::{Events, quoted};

/// CREATE and DROP DATABASE run outside a transaction, as the editor
/// runs them.
async fn run(session: &dyn EditorSession, sql: &str) -> Result<(), ConformanceFailure> {
    let summary = session
        .run(
            UserSql::new(sql),
            RunOptions::new(CancellationToken::new()),
            Box::new(Events::default()),
        )
        .await?;
    match summary.end {
        RunEnd::Completed => Ok(()),
        other => Err(ConformanceFailure::setup(format!("`{sql}` ended {other:?}"))),
    }
}

#[async_trait]
impl DumpEngine for MssqlEngine {
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let mut options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let connection = MssqlDriver.connect(options.clone(), CancellationToken::new()).await?;
        let session = connection
            .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
            .await?;
        let database = quoted(name);
        let literal = name.replace('\'', "''");
        let drop = format!(
            "IF DB_ID(N'{literal}') IS NOT NULL BEGIN \
             ALTER DATABASE {database} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {database}; END"
        );
        let mut made = run(session.as_ref(), &drop).await;
        if made.is_ok() {
            made = run(session.as_ref(), &format!("CREATE DATABASE {database}")).await;
        }
        session.close().await;
        connection.close().await?;
        made?;
        match &mut options.target {
            ConnectTarget::Network(target) => target.database = Some(name.to_owned()),
            _ => return Err(ConformanceFailure::setup("the fixture connects over the network")),
        }
        Ok(options)
    }

    /// Every object in a schema of its own, so the dump makes the schema
    /// too. The procedure is made under QUOTED_IDENTIFIER OFF, which the
    /// one session the sample runs in keeps until it is set back. The
    /// trigger comes after the first rows and before the last, so a row
    /// it touched is in the sample and a trigger firing during the load
    /// would touch the others.
    fn dump_fixture(&self) -> Vec<String> {
        [
            "CREATE SCHEMA app",
            "CREATE TYPE app.label FROM nvarchar(40) NOT NULL",
            "CREATE SEQUENCE app.ticket AS int START WITH 100 INCREMENT BY 5",
            "CREATE TABLE app.parent (\
                 id int IDENTITY(10, 5) NOT NULL, \
                 name app.label, \
                 note nvarchar(max) NULL, \
                 payload varbinary(max) NULL, \
                 price decimal(10, 2) NOT NULL CONSTRAINT df_parent_price DEFAULT (0), \
                 ticket int NOT NULL CONSTRAINT df_parent_ticket DEFAULT (NEXT VALUE FOR app.ticket), \
                 flag bit NULL, \
                 ref uniqueidentifier NULL, \
                 amount money NULL, \
                 ratio float NULL, \
                 created datetime2(3) NULL, \
                 stamped datetimeoffset(2) NULL, \
                 name_length AS LEN(name) PERSISTED, \
                 touched nvarchar(20) NULL, \
                 CONSTRAINT pk_parent PRIMARY KEY CLUSTERED (id), \
                 CONSTRAINT uq_parent_ticket UNIQUE NONCLUSTERED (ticket), \
                 CONSTRAINT ck_parent_price CHECK (price >= 0)\
             )",
            "CREATE TABLE app.child (\
                 id int IDENTITY(1, 1) NOT NULL CONSTRAINT pk_child PRIMARY KEY, \
                 parent_id int NOT NULL CONSTRAINT fk_child_parent REFERENCES app.parent (id) ON DELETE CASCADE, \
                 previous_id int NULL CONSTRAINT fk_child_previous REFERENCES app.child (id), \
                 label nvarchar(50) NOT NULL\
             )",
            "CREATE INDEX ix_child_label ON app.child (label DESC) INCLUDE (parent_id)",
            "EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'what the row says', \
             @level0type = N'SCHEMA', @level0name = N'app', @level1type = N'TABLE', @level1name = N'parent', \
             @level2type = N'COLUMN', @level2name = N'note'",
            "INSERT INTO app.parent (name, note, payload, price, flag, ref, amount, ratio, created, stamped) VALUES \
             (N'first', N'it''s; a \"quote\" \\ back' + NCHAR(10) + N'line two, Grüße 東京', 0x00FF27, 12.50, 1, \
              'c3c9a0d4-4b7e-4f43-9a52-6a1f0c1d2e3f', 12.3456, 0.1, '2024-01-02T03:04:05.678', \
              '2024-01-02T03:04:05.67+07:00'), \
             (N'second', NULL, 0xFF, 0, 0, NULL, -1, -2.5E-10, NULL, NULL)",
            "CREATE VIEW app.priced_parents AS SELECT id, name, price FROM app.parent WHERE price > 0",
            "CREATE VIEW app.parent_names AS SELECT name FROM app.priced_parents",
            "CREATE FUNCTION app.price_with_tax (@price decimal(10, 2)) RETURNS decimal(12, 2) \
             AS BEGIN RETURN @price * 1.1; END",
            "SET QUOTED_IDENTIFIER OFF",
            "CREATE PROCEDURE app.add_child @parent int, @label nvarchar(50) AS BEGIN SET NOCOUNT ON; \
             INSERT INTO app.child (parent_id, label) VALUES (@parent, @label); END",
            "SET QUOTED_IDENTIFIER ON",
            "CREATE TRIGGER app.parent_touch ON app.parent AFTER INSERT AS BEGIN SET NOCOUNT ON; \
             UPDATE p SET touched = N'trigger' FROM app.parent AS p JOIN inserted AS i ON i.id = p.id; END",
            "INSERT INTO app.parent (name, price) VALUES (N'third', 1), (N'fourth', 2)",
            "DELETE FROM app.parent WHERE name = N'fourth'",
            "INSERT INTO app.child (parent_id, previous_id, label) VALUES (10, NULL, N'a')",
            "INSERT INTO app.child (parent_id, previous_id, label) VALUES (15, 1, N'b')",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
}

mod suite {
    use super::MssqlEngine;

    tablepro_test_support::dump_suite! {
        engine: MssqlEngine,
        docker: true,
    }
}
