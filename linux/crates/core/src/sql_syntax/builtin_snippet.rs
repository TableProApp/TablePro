use super::SqlGrammar;

/// A statement the editor offers to write, with stops to fill in.
///
/// `text` is in GtkSourceView's snippet syntax, and uses only `${N:text}`
/// for a stop, `$N` for the text of stop N and `$0` for where the cursor
/// ends. A bare `$` starts a stop in that syntax, so none of these
/// statements may hold one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuiltinSnippet {
    pub trigger: &'static str,
    /// The statement's shape, which is SQL and reads the same in every
    /// language.
    pub name: &'static str,
    pub text: &'static str,
}

impl BuiltinSnippet {
    const fn new(trigger: &'static str, name: &'static str, text: &'static str) -> Self {
        Self { trigger, name, text }
    }
}

const SELECT: BuiltinSnippet = BuiltinSnippet::new(
    "sel",
    "SELECT … FROM … WHERE",
    "SELECT ${1:*}\nFROM ${2:table_name}\nWHERE ${3:condition};$0",
);
const INSERT: BuiltinSnippet = BuiltinSnippet::new(
    "ins",
    "INSERT INTO … VALUES",
    "INSERT INTO ${1:table_name} (${2:columns})\nVALUES (${3:values});$0",
);
const UPDATE: BuiltinSnippet = BuiltinSnippet::new(
    "upd",
    "UPDATE … SET … WHERE",
    "UPDATE ${1:table_name}\nSET ${2:column} = ${3:value}\nWHERE ${4:condition};$0",
);
const DELETE: BuiltinSnippet = BuiltinSnippet::new(
    "del",
    "DELETE FROM … WHERE",
    "DELETE FROM ${1:table_name}\nWHERE ${2:condition};$0",
);
const JOIN: BuiltinSnippet = BuiltinSnippet::new(
    "selj",
    "SELECT … JOIN … ON",
    "SELECT ${1:*}\nFROM ${2:table_name} AS ${3:a}\nJOIN ${4:other_table} AS ${5:b} ON $5.${6:id} = $3.${7:id};$0",
);
const CREATE_INDEX: BuiltinSnippet = BuiltinSnippet::new(
    "cidx",
    "CREATE INDEX",
    "CREATE INDEX ${1:index_name}\nON ${2:table_name} (${3:column});$0",
);

const POSTGRESQL: [BuiltinSnippet; 7] = [
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    JOIN,
    BuiltinSnippet::new(
        "ctab",
        "CREATE TABLE",
        "CREATE TABLE ${1:table_name} (\n    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n    ${2:name} ${3:TEXT} NOT NULL$0\n);",
    ),
    CREATE_INDEX,
];

const MYSQL: [BuiltinSnippet; 7] = [
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    JOIN,
    BuiltinSnippet::new(
        "ctab",
        "CREATE TABLE",
        "CREATE TABLE ${1:table_name} (\n    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n    ${2:name} ${3:VARCHAR(255)} NOT NULL$0\n);",
    ),
    CREATE_INDEX,
];

const SQLITE: [BuiltinSnippet; 7] = [
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    JOIN,
    // An INTEGER PRIMARY KEY is the rowid, which numbers itself.
    BuiltinSnippet::new(
        "ctab",
        "CREATE TABLE",
        "CREATE TABLE ${1:table_name} (\n    id INTEGER PRIMARY KEY,\n    ${2:name} ${3:TEXT} NOT NULL$0\n);",
    ),
    CREATE_INDEX,
];

const MSSQL: [BuiltinSnippet; 7] = [
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    JOIN,
    BuiltinSnippet::new(
        "ctab",
        "CREATE TABLE",
        "CREATE TABLE ${1:table_name} (\n    id BIGINT IDENTITY(1, 1) PRIMARY KEY,\n    ${2:name} ${3:NVARCHAR(255)} NOT NULL$0\n);",
    ),
    CREATE_INDEX,
];

// ClickHouse changes rows through a mutation, and a table needs an
// engine and a sort key; a skipping index needs its type.
const CLICKHOUSE: [BuiltinSnippet; 7] = [
    SELECT,
    INSERT,
    BuiltinSnippet::new(
        "upd",
        "ALTER TABLE … UPDATE … WHERE",
        "ALTER TABLE ${1:table_name}\nUPDATE ${2:column} = ${3:value}\nWHERE ${4:condition};$0",
    ),
    DELETE,
    JOIN,
    BuiltinSnippet::new(
        "ctab",
        "CREATE TABLE",
        "CREATE TABLE ${1:table_name} (\n    id UInt64,\n    ${2:name} ${3:String}$0\n)\nENGINE = MergeTree\nORDER BY id;",
    ),
    BuiltinSnippet::new(
        "cidx",
        "CREATE INDEX",
        "CREATE INDEX ${1:index_name}\nON ${2:table_name} (${3:column}) TYPE ${4:minmax};$0",
    ),
];

/// The statements the editor offers on an engine of `grammar`. Redis is
/// not SQL and has none.
pub fn builtin_snippets(grammar: SqlGrammar) -> &'static [BuiltinSnippet] {
    match grammar {
        SqlGrammar::PostgreSql => &POSTGRESQL,
        SqlGrammar::MySql => &MYSQL,
        SqlGrammar::Sqlite => &SQLITE,
        SqlGrammar::MsSql => &MSSQL,
        SqlGrammar::ClickHouse => &CLICKHOUSE,
        SqlGrammar::Redis => &[],
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn every_sql_engine_offers_the_same_seven_triggers_once() {
        for grammar in SqlGrammar::SQL {
            let triggers: Vec<&str> = builtin_snippets(grammar)
                .iter()
                .map(|snippet| snippet.trigger)
                .collect();
            let unique: HashSet<&str> = triggers.iter().copied().collect();

            assert_eq!(
                triggers,
                ["sel", "ins", "upd", "del", "selj", "ctab", "cidx"],
                "{grammar:?}"
            );
            assert_eq!(unique.len(), triggers.len(), "{grammar:?} repeats a trigger");
        }
    }

    #[test]
    fn redis_has_no_sql_snippets() {
        assert!(builtin_snippets(SqlGrammar::Redis).is_empty());
    }

    #[test]
    fn insert_stops_on_the_table_the_columns_and_the_values() {
        for grammar in SqlGrammar::SQL {
            let insert = builtin_snippets(grammar)
                .iter()
                .find(|snippet| snippet.trigger == "ins")
                .expect("an INSERT");

            assert_eq!(
                insert.text, "INSERT INTO ${1:table_name} (${2:columns})\nVALUES (${3:values});$0",
                "{grammar:?}"
            );
        }
    }
}
