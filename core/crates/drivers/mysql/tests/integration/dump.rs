//! The SQL dump round trip on MySQL and MariaDB.

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig, WorkspaceSettings, WriteKind};
use tablepro_driver_mysql::MysqlDriver;
use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::conformance::{ConformanceFailure, DumpEngine, NativeDump, test_liveness};
use tokio_util::sync::CancellationToken;

use crate::conformance_engine::{MySqlEngine, Server};
use crate::support::{apply, direct, options_over, password};

fn quoted(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

#[async_trait]
impl<S: Server> DumpEngine for MySqlEngine<S> {
    /// Made and reached as root: the password user may create no
    /// database, and under MySQL's binary log only an account with SUPER
    /// may create a trigger.
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let fixture = self.fixture();
        let options = |database: &str| {
            let liveness = test_liveness();
            options_over(
                direct(fixture.host(), fixture.port(), &liveness),
                password(&fixture.root_credentials()),
                database,
                TlsConfig::disabled(),
                WorkspaceSettings::workspace(false),
                liveness,
            )
        };
        let connection = MysqlDriver
            .connect(options(fixture.database()), CancellationToken::new())
            .await?;
        let database = quoted(name);
        let drop = format!("DROP DATABASE IF EXISTS {database}");
        let create = format!("CREATE DATABASE {database}");
        let made = apply(connection.as_ref(), WriteKind::SchemaChanges, &[&drop, &create]).await;
        connection.close().await?;
        made?;
        Ok(options(name))
    }

    /// The parent row with key 0 loads only under the header's
    /// `NO_AUTO_VALUE_ON_ZERO`. The view that calls a function is printed
    /// with the database's name by MySQL, and MariaDB names it in the
    /// sequence a default takes from.
    fn dump_fixture(&self) -> Vec<String> {
        let mariadb = S::FLAVOUR == MysqlFlavour::Mariadb;
        let mut statements: Vec<&str> = Vec::new();
        if mariadb {
            statements.push("CREATE SEQUENCE invoice_no START WITH 1000 INCREMENT BY 1 CACHE 10");
        }
        statements.extend([
            "CREATE TABLE parent (\
                 id int NOT NULL AUTO_INCREMENT, \
                 name varchar(50) NOT NULL, \
                 PRIMARY KEY (id), \
                 CONSTRAINT parent_name_present CHECK (name <> '')\
             )",
            "CREATE TABLE child (\
                 id int NOT NULL AUTO_INCREMENT, \
                 parent_id int NOT NULL, \
                 next_id int NULL, \
                 note text, \
                 payload varbinary(16), \
                 amount decimal(10,2) NOT NULL DEFAULT 0, \
                 doubled decimal(12,2) GENERATED ALWAYS AS (amount * 2) STORED, \
                 PRIMARY KEY (id), \
                 CONSTRAINT child_parent FOREIGN KEY (parent_id) REFERENCES parent (id), \
                 CONSTRAINT child_next FOREIGN KEY (next_id) REFERENCES child (id), \
                 CONSTRAINT child_amount_positive CHECK (amount >= 0)\
             )",
        ]);
        if mariadb {
            statements.push(
                "CREATE TABLE invoice (\
                     no bigint NOT NULL DEFAULT NEXTVAL(invoice_no), \
                     note varchar(20), \
                     PRIMARY KEY (no)\
                 )",
            );
        }
        let typed = typed_table(S::FLAVOUR);
        statements.push(&typed.0);
        statements.extend([
            "CREATE FUNCTION label_of(p int) RETURNS varchar(80) DETERMINISTIC READS SQL DATA\n\
             BEGIN\n\
               DECLARE found varchar(50);\n\
               SELECT name INTO found FROM parent WHERE id = p;\n\
               RETURN CONCAT('#', p, ' ', COALESCE(found, '?'));\n\
             END",
            "CREATE PROCEDURE add_parent(IN n varchar(50))\n\
             BEGIN\n\
               INSERT INTO parent (name) VALUES (n);\n\
               SELECT LAST_INSERT_ID() AS id;\n\
             END",
            "CREATE VIEW parent_names AS SELECT id, name FROM parent",
            "CREATE VIEW parent_labels AS SELECT id, label_of(id) AS label FROM parent_names",
            "CREATE TRIGGER child_touch BEFORE INSERT ON child FOR EACH ROW \
             SET NEW.note = CONCAT(COALESCE(NEW.note, ''), ';')",
            "INSERT INTO parent (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'zero'), (5, 'gone')",
            "UPDATE parent SET id = 0 WHERE id = 4",
            "DELETE FROM parent WHERE id = 5",
            "INSERT INTO child (id, parent_id, next_id, note, payload, amount) VALUES \
             (1, 1, NULL, 'it''s \"quoted\" back\\\\slash; line\\nbreak naïve 日本', X'00FF7F', 10.50), \
             (2, 0, 1, NULL, NULL, 0), \
             (3, 2, 2, 'plain', X'FF', 3.25), \
             (4, 3, NULL, 'gone', NULL, 1)",
            "UPDATE child SET next_id = 3 WHERE id = 1",
            "DELETE FROM child WHERE id = 4",
        ]);
        if mariadb {
            statements.push("INSERT INTO invoice (note) VALUES ('first'), ('second')");
        }
        statements.push(&typed.1);
        statements.push("INSERT INTO typed (id) VALUES (2)");
        statements.into_iter().map(str::to_owned).collect()
    }

    /// Each server's own tool, with `--hex-blob --routines`: without
    /// `--hex-blob` the file holds raw bytes and is not UTF-8.
    fn native_dump(&self) -> Option<NativeDump> {
        let file = match S::FLAVOUR {
            MysqlFlavour::Mysql => include_str!("fixtures/mysqldump-8.4-hex-blob.sql"),
            MysqlFlavour::Mariadb => include_str!("fixtures/mariadb-dump-11.4-hex-blob.sql"),
        };
        let checks = [
            ("SELECT COUNT(*) FROM child", "4"),
            ("SELECT id FROM parent WHERE name = 'zero'", "0"),
            ("SELECT note FROM child WHERE id = 2", "line1\nline2;"),
            ("SELECT HEX(payload) FROM child WHERE id = 1", "00FF27"),
            ("SELECT COUNT(*) FROM v2", "3"),
            ("SELECT f_double(21)", "42"),
        ];
        Some(NativeDump {
            file,
            checks: checks
                .into_iter()
                .map(|(sql, value)| (sql.to_owned(), value.to_owned()))
                .collect(),
        })
    }
}

/// A column of each kind the value corpus covers, one row of values at
/// their edges and one of NULLs.
fn typed_table(flavour: MysqlFlavour) -> (String, String) {
    let (columns, values) = match flavour {
        MysqlFlavour::Mysql => (
            "doc json, packed_uuid binary(16)",
            "'{\"b\": 1, \"a\": [1, 2.50, \"x\"], \"ü\": null}', \
             UUID_TO_BIN('123e4567-e89b-12d3-a456-426614174000')",
        ),
        MysqlFlavour::Mariadb => (
            "doc json, uid uuid, address inet6",
            "'{\"b\": 1, \"a\": [1, 2.50, \"x\"]}', '123e4567-e89b-12d3-a456-426614174000', '::ffff:192.0.2.1'",
        ),
    };
    let create = format!(
        "CREATE TABLE typed (\
             id int NOT NULL PRIMARY KEY, \
             fine datetime(6), at datetime, stamp timestamp(3) NULL, day date, span time(6), yr year, \
             wide decimal(65, 30), money decimal(10, 2), huge bigint unsigned, low bigint, small tinyint unsigned, \
             single float, twice double, word varchar(100), latin varchar(20) CHARACTER SET latin1, \
             fixed char(5), body text, bytes varbinary(8), blob_value blob, flags bit(10), \
             mood enum('happy', 'sad'), tags set('a', 'b', 'c'), {columns}\
         )"
    );
    let insert = format!(
        "INSERT INTO typed VALUES (1, \
             '9999-12-31 23:59:59.999999', '2024-03-10 02:30:00', '2038-01-19 03:14:07.999', '2024-02-29', \
             '-838:59:59', 2155, \
             12345678901234567890123456789012345.123456789012345678901234567890, -12345678.9, \
             18446744073709551615, -9223372036854775808, 255, \
             1.5, -2.5e-5, '🦀 emoji 👩‍💻', 'café', \
             'ab', 'tab\\there', X'DEADBEEF', X'00FF', b'1010101010', \
             'sad', 'a,c', {values})"
    );
    (create, insert)
}

mod mysql_suite {
    use crate::conformance_engine::{MySqlEngine, MysqlServer};

    tablepro_test_support::dump_suite! {
        engine: MySqlEngine<MysqlServer>,
        docker: true,
    }
}

mod mariadb_suite {
    use crate::conformance_engine::{MariadbServer, MySqlEngine};

    tablepro_test_support::dump_suite! {
        engine: MySqlEngine<MariadbServer>,
        docker: true,
    }
}
