//! The SQL dump round trip on ClickHouse.

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, ConnectTarget, DatabaseDriver, WorkspaceSettings, WriteKind};
use tablepro_driver_clickhouse::ClickhouseDriver;
use tablepro_test_support::conformance::{ConformanceEngine, ConformanceFailure, DumpEngine, test_liveness};
use tokio_util::sync::CancellationToken;

use crate::conformance_engine::ClickHouseEngine;
use crate::support::{apply, quoted};

#[async_trait]
impl DumpEngine for ClickHouseEngine {
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let mut options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let connection = ClickhouseDriver
            .connect(options.clone(), CancellationToken::new())
            .await?;
        let database = quoted(name);
        let drop = format!("DROP DATABASE IF EXISTS {database} SYNC");
        let create = format!("CREATE DATABASE {database}");
        let made = apply(connection.as_ref(), WriteKind::SchemaChanges, &[&drop, &create]).await;
        connection.close().await?;
        made?;
        match &mut options.target {
            ConnectTarget::Network(target) => target.database = Some(name.to_owned()),
            _ => return Err(ConformanceFailure::setup("the fixture connects over the network")),
        }
        Ok(options)
    }

    /// ClickHouse has no foreign keys, sequences, routines or triggers.
    /// The materialized view stands in for a trigger: it is made after
    /// the rows load, or its target would hold their counts twice.
    fn dump_fixture(&self) -> Vec<String> {
        [
            "CREATE TABLE parent (\
                 id UInt64, \
                 name String, \
                 note Nullable(String), \
                 tags Array(String), \
                 attrs Map(String, UInt8), \
                 kind LowCardinality(String) DEFAULT 'plain', \
                 payload String, \
                 amount Decimal(18, 4), \
                 created DateTime64(3, 'UTC'), \
                 name_length UInt64 MATERIALIZED length(name)\
             ) ENGINE = MergeTree ORDER BY id",
            "CREATE TABLE child (id UInt64, parent_id UInt64, label String, version UInt32) \
             ENGINE = ReplacingMergeTree(version) ORDER BY id",
            "CREATE TABLE child_counts (parent_id UInt64, n UInt64) ENGINE = MergeTree ORDER BY (parent_id, n)",
            "CREATE MATERIALIZED VIEW mv_child_counts TO child_counts \
             AS SELECT parent_id, count() AS n FROM child GROUP BY parent_id",
            "CREATE VIEW v_top AS SELECT id, name FROM parent WHERE id > 1",
            "CREATE VIEW v_over AS SELECT id FROM v_top WHERE name != ''",
            "INSERT INTO parent (id, name, note, tags, attrs, kind, payload, amount, created) VALUES \
             (1, 'it\\'s; a \"quote\" \\\\ back\\nline two, Grüße 東京', NULL, ['x', 'y'], {'k': 1}, 'rare', \
              unhex('00FF27'), 12.5, '2024-01-02 03:04:05.678'), \
             (2, 'plain', 'a note', [], {}, DEFAULT, '', -0.0001, '1970-01-01 00:00:00.000'), \
             (3, '', 'ünïcode', ['only'], {'a': 0, 'b': 255}, 'plain', unhex('FF'), 0, '2038-01-19 03:14:08.000')",
            "INSERT INTO child (id, parent_id, label, version) VALUES \
             (1, 1, 'first', 1), (2, 1, 'second', 1), (3, 2, 'old', 1)",
            "INSERT INTO child (id, parent_id, label, version) VALUES (3, 1, 'replaced', 2)",
            "OPTIMIZE TABLE child FINAL",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
}

mod suite {
    use super::ClickHouseEngine;

    tablepro_test_support::dump_suite! {
        engine: ClickHouseEngine,
        docker: true,
    }
}
