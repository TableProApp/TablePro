use serde::Deserialize;

use crate::conformance::ConformanceFailure;

// One column of an engine's value corpus: the clause `ALTER TABLE ... ADD` takes, naming the column `v`, the
// statements run before it, and values of it the way a real table holds them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusColumn {
    pub setup_sql: Vec<String>,
    pub declaration: String,
    pub values: Vec<CorpusValue>,
}

// A value written as SQL and the text the grid shows for it, `None` for NULL. `edited` is what an editor run shows
// where it differs from a browse page.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CorpusValue {
    pub sql: String,
    #[serde(rename = "shows")]
    pub shown: Option<String>,
    #[serde(default)]
    pub edited: Option<String>,
}

// The corpora live in `corpus/` as JSON, which the Windows interop tests read too (`windows/tests/TablePro.Interop.Tests`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValueCorpus {
    Cassandra,
    Clickhouse,
    Duckdb,
    Mariadb,
    Mssql,
    Mysql,
    Postgres,
    Sqlite,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CorpusFile {
    #[serde(default, rename = "why")]
    _why: Option<String>,
    columns: Vec<CorpusEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CorpusEntry {
    #[serde(default, rename = "why")]
    _why: Option<String>,
    #[serde(default)]
    only: Option<String>,
    column: String,
    #[serde(default)]
    setup: Vec<String>,
    values: Vec<CorpusValue>,
}

impl ValueCorpus {
    pub fn columns(self) -> Result<Vec<CorpusColumn>, ConformanceFailure> {
        let file: CorpusFile = serde_json::from_str(self.file())
            .map_err(|error| ConformanceFailure::setup(format!("the {self:?} corpus: {error}")))?;
        Ok(file
            .columns
            .into_iter()
            .filter(|entry| entry.only.as_deref().is_none_or(|only| Some(only) == self.flavour()))
            .map(|entry| CorpusColumn {
                setup_sql: entry.setup,
                declaration: entry.column,
                values: entry.values,
            })
            .collect())
    }

    fn file(self) -> &'static str {
        match self {
            Self::Cassandra => include_str!("../../corpus/cassandra.json"),
            Self::Clickhouse => include_str!("../../corpus/clickhouse.json"),
            Self::Duckdb => include_str!("../../corpus/duckdb.json"),
            Self::Mariadb | Self::Mysql => include_str!("../../corpus/mysql.json"),
            Self::Mssql => include_str!("../../corpus/mssql.json"),
            Self::Postgres => include_str!("../../corpus/postgres.json"),
            Self::Sqlite => include_str!("../../corpus/sqlite.json"),
        }
    }

    // A column marked `only` belongs to one flavour of a file two engines share.
    fn flavour(self) -> Option<&'static str> {
        match self {
            Self::Mariadb => Some("mariadb"),
            Self::Mysql => Some("mysql"),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ValueCorpus;

    const EVERY: [ValueCorpus; 8] = [
        ValueCorpus::Cassandra,
        ValueCorpus::Clickhouse,
        ValueCorpus::Duckdb,
        ValueCorpus::Mariadb,
        ValueCorpus::Mssql,
        ValueCorpus::Mysql,
        ValueCorpus::Postgres,
        ValueCorpus::Sqlite,
    ];

    #[test]
    fn every_corpus_parses_and_names_its_column_v() {
        for corpus in EVERY {
            let columns = corpus.columns().unwrap();
            assert!(!columns.is_empty(), "{corpus:?} lists no column");
            for column in columns {
                assert!(
                    column.declaration.starts_with("v ") || column.declaration.starts_with("COLUMN v ") || column.declaration == "v",
                    "{corpus:?}: `{}` does not add `v`",
                    column.declaration
                );
                assert!(!column.values.is_empty(), "{corpus:?}: `{}` has no value", column.declaration);
            }
        }
    }

    #[test]
    fn mysql_and_mariadb_share_the_common_columns_and_keep_their_own() {
        let declarations = |corpus: ValueCorpus| -> Vec<String> {
            corpus.columns().unwrap().into_iter().map(|column| column.declaration).collect()
        };
        let (mysql, mariadb) = (declarations(ValueCorpus::Mysql), declarations(ValueCorpus::Mariadb));

        assert_eq!(mysql.first(), mariadb.first());
        assert!(mysql.contains(&"v BINARY(16)".to_owned()));
        assert!(!mariadb.contains(&"v BINARY(16)".to_owned()));
        assert!(mariadb.contains(&"v INET6".to_owned()));
        assert!(!mysql.contains(&"v INET6".to_owned()));
    }
}
