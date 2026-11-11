use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{ScriptPlan, ScriptToken};
use crate::sql_syntax::statement_access::{
    CLIENT_SPLITS, Code, Kind, code_of, decodes_unicode_names, is, may_be_space, spelled_in_escapes, split_at_blanks,
};
use crate::unicode_blank::is_blank;

const FILESYSTEM_WORD_RUNS: [[&str; 2]; 5] = [
    ["into", "outfile"],
    ["into", "dumpfile"],
    ["to", "program"],
    ["from", "program"],
    ["vacuum", "into"],
];

// A statement that opens with one of these reads or writes files, attaches another database or runs code.
const FILESYSTEM_OR_CODE_KEYWORDS: &[&str] = &[
    "copy", "attach", "detach", "do", "load", "install", "import", "export", "backup", "restore", "dump", "source",
    "unload", "bulk",
];

// Reached by name, called or not.
const FILESYSTEM_NAMES: &[&str] = &[
    "xp_cmdshell",
    "sp_oacreate",
    "xp_dirtree",
    "xp_fileexist",
    "xp_subdirs",
    "xp_regread",
    "xp_regwrite",
    "sp_execute_external_script",
    "utl_http",
    "utl_file",
    "utl_tcp",
    "utl_smtp",
    "utl_inaddr",
];

const FILESYSTEM_FUNCTIONS: &[&str] = &[
    "load_file",
    "pg_read_file",
    "pg_read_binary_file",
    "pg_ls_dir",
    "sys_read_file",
    "sys_read_binary_file",
    "sys_ls_dir",
    "lo_import",
    "lo_export",
    "pg_file_write",
    "load_extension",
    "readfile",
    "writefile",
    "fn_get_audit_file",
    "openrowset",
    "opendatasource",
    "fsdir",
    "pg_stat_file",
    "pg_ls_logdir",
    "pg_ls_waldir",
    "pg_ls_tmpdir",
    "pg_ls_archive_statusdir",
    "pg_ls_logicalsnapdir",
    "pg_ls_logicalmapdir",
    "pg_ls_replslotdir",
    "pg_file_unlink",
    "pg_file_rename",
    "pg_file_sync",
    "pg_file_read",
    "pg_logdir_ls",
    "fn_xe_file_target_read_file",
    "fn_trace_gettable",
    "fn_dump_dblog",
    "dm_os_enumerate_filesystem",
    "dm_os_file_exists",
    "bfilename",
    "httpuritype",
];

const DUCKDB_FUNCTIONS: &[&str] = &[
    "glob",
    "sniff_csv",
    "getenv",
    "query",
    "query_table",
    "json_execute_serialized_sql",
    "from_substrait",
    "from_substrait_json",
    "import_database",
    "arrow_scan",
    "arrow_scan_dumb",
    "load_aws_credentials",
    "enable_logging",
    "start_ui",
    "start_ui_server",
];

const DUCKDB_FAMILIES: &[&str] = &[
    "read_",
    "parquet_",
    "st_read",
    "iceberg_",
    "delta_",
    "sqlite_",
    "postgres_",
    "mysql_",
];

const CLICKHOUSE_FUNCTIONS: &[&str] = &[
    "file",
    "filecluster",
    "url",
    "urlcluster",
    "s3",
    "s3cluster",
    "gcs",
    "cosn",
    "oss",
    "hdfs",
    "hdfscluster",
    "remote",
    "remotesecure",
    "mysql",
    "postgresql",
    "mongodb",
    "redis",
    "sqlite",
    "jdbc",
    "odbc",
    "executable",
    "arrowflight",
    "ytsaurus",
];

const CLICKHOUSE_FAMILIES: &[&str] = &["azureblobstorage", "iceberg", "deltalake", "hudi", "paimon"];

// An allowlist: an editor LOAD, or an extension DuckDB loads on its own, brings table functions no list knows.
const DUCKDB_TABLE_FUNCTIONS: &[&str] = &[
    "range",
    "generate_series",
    "unnest",
    "repeat",
    "json_each",
    "json_tree",
    "duckdb_columns",
    "duckdb_constraints",
    "duckdb_databases",
    "duckdb_dependencies",
    "duckdb_functions",
    "duckdb_indexes",
    "duckdb_keywords",
    "duckdb_schemas",
    "duckdb_sequences",
    "duckdb_settings",
    "duckdb_tables",
    "duckdb_types",
    "duckdb_variables",
    "duckdb_views",
    "pragma_database_size",
    "pragma_platform",
    "pragma_show",
    "pragma_storage_info",
    "pragma_table_info",
    "pragma_version",
];

// DuckDB joins a dotted table name with `.` and reads it as a file in the working folder.
const FILE_EXTENSIONS: &[&str] = &[
    "csv", "tsv", "gz", "zst", "parquet", "json", "jsonl", "ndjson", "geojson", "geojsonl", "db", "ddb", "duckdb",
];

const TABLE_INTRODUCERS: &[&str] = &[
    "from",
    "join",
    "using",
    "table",
    "describe",
    "desc",
    "show",
    "summarize",
    "pivot",
    "unpivot",
];

// Reserved words, so none is the alias in `FROM notes AS n, 'payroll.csv'`.
const TABLE_LIST_ENDS: &[&str] = &[
    "select",
    "where",
    "group",
    "having",
    "window",
    "qualify",
    "order",
    "limit",
    "offset",
    "union",
    "intersect",
    "except",
    "returning",
    "do",
];

// Only a FROM or JOIN list holds table functions; PIVOT's and USING's parentheses hold expressions.
const CALLING_INTRODUCERS: &[&str] = &["from", "join"];

// Their arguments may hold a FROM that names no table.
const FROM_TAKING_FUNCTIONS: &[&str] = &["extract", "trim", "substring", "overlay"];

// Read every way statement_access reads the text. A read-only transaction stops none of these.
pub fn reaches_outside_database(sql: &str, grammar: SqlGrammar) -> bool {
    if matches!(grammar, SqlGrammar::Redis | SqlGrammar::Mongo) {
        return false;
    }
    if reaches_as_sent(sql, grammar, CLIENT_SPLITS) {
        return true;
    }
    let letters = matches!(grammar, SqlGrammar::PostgreSql | SqlGrammar::Sqlite);
    !letters && sql.contains(may_be_space) && reaches_as_sent(&sql.replace(may_be_space, " "), grammar, CLIENT_SPLITS)
}

fn reaches_as_sent(sql: &str, grammar: SqlGrammar, splits: u8) -> bool {
    reaches_every_way(sql, grammar)
        || (splits > 0
            && ScriptPlan::client_pieces(sql, grammar)
                .into_iter()
                .any(|piece| reaches_as_sent(piece, grammar, splits - 1)))
}

fn reaches_every_way(sql: &str, grammar: SqlGrammar) -> bool {
    let Some(mut plans) = ScriptPlan::server_readings(sql, grammar) else {
        return true;
    };
    plans.any(|plan| {
        plan.statements().iter().any(|statement| {
            let tokens: Vec<ScriptToken> = plan.tokens(statement.range.clone()).collect();
            let code = code_of(sql, &tokens);
            let blanks_inside = code
                .iter()
                .any(|token| token.kind == Kind::Word && token.text.contains(is_blank));
            reaches(&code, grammar) || (blanks_inside && reaches(&split_at_blanks(&code), grammar))
        })
    })
}

fn reaches(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    code.split(|token| token.kind == Kind::End)
        .filter(|part| !part.is_empty())
        .any(|part| {
            part.first()
                .is_some_and(|first| first.is_word(FILESYSTEM_OR_CODE_KEYWORDS))
                || names_filesystem(part)
                || (0..part.len()).any(|index| calls_outside(part, index, grammar))
                || (grammar == SqlGrammar::DuckDb && duckdb_reads_a_file_as_a_table(part))
        })
}

fn names_filesystem(part: &[Code<'_>]) -> bool {
    part.iter().enumerate().any(|(index, token)| {
        (matches!(token.kind, Kind::Word | Kind::Quoted) && is(token.text, FILESYSTEM_NAMES))
            || FILESYSTEM_WORD_RUNS.iter().any(|[first, second]| {
                token.is_word(&[*first]) && part.get(index + 1).is_some_and(|next| next.is_word(&[*second]))
            })
    })
}

// A name spelled U&"…" may be any of them.
fn calls_outside(part: &[Code<'_>], index: usize, grammar: SqlGrammar) -> bool {
    let token = &part[index];
    if !matches!(token.kind, Kind::Word | Kind::Quoted) || !opens_a_call(part, index) {
        return false;
    }
    if decodes_unicode_names(grammar) && spelled_in_escapes(part, index) {
        return true;
    }
    let name = token.text;
    is(name, FILESYSTEM_FUNCTIONS)
        || match grammar {
            SqlGrammar::DuckDb => is(name, DUCKDB_FUNCTIONS) || starts_with_any(name, DUCKDB_FAMILIES),
            SqlGrammar::ClickHouse => is(name, CLICKHOUSE_FUNCTIONS) || starts_with_any(name, CLICKHOUSE_FAMILIES),
            _ => false,
        }
}

// UESCAPE '!' may stand between a U&"…" name and its arguments.
fn opens_a_call(part: &[Code<'_>], index: usize) -> bool {
    let mut next = index + 1;
    if part.get(next).is_some_and(|word| word.is_word(&["uescape"])) {
        next += 1 + part[next + 1..]
            .iter()
            .take_while(|token| token.kind == Kind::Literal)
            .count();
    }
    part.get(next).is_some_and(|token| token.kind == Kind::Open)
}

fn starts_with_any(name: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|prefix| {
        name.get(..prefix.len())
            .is_some_and(|start| start.eq_ignore_ascii_case(prefix))
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Expectation {
    Nothing,
    Table,
    RestOfName,
}

#[derive(Clone, Copy)]
struct Level {
    separates_arguments_with_from: bool,
    lists_tables: bool,
    expects: Expectation,
    introducer: &'static str,
    name_parts: usize,
}

impl Level {
    fn new(separates_arguments_with_from: bool, expects: Expectation, introducer: &'static str) -> Level {
        Level {
            separates_arguments_with_from,
            lists_tables: false,
            expects,
            introducer,
            name_parts: 0,
        }
    }
}

// The walk of the macOS app's SQLFileNamedAsTable, plus the table functions and dotted file names it misses.
// DESCRIBE and EXPLAIN open the file too, so they get no shortcut here.
fn duckdb_reads_a_file_as_a_table(part: &[Code<'_>]) -> bool {
    let mut levels = vec![Level::new(false, Expectation::Nothing, "")];
    for (index, token) in part.iter().enumerate() {
        let Some(level) = levels.last_mut() else {
            return true;
        };
        let expected = level.expects;
        level.expects = Expectation::Nothing;
        match token.kind {
            Kind::Word
                if token.is_word(&["from"])
                    && (level.separates_arguments_with_from || compares_distinct(part, index)) => {}
            Kind::Word | Kind::Other if let Some(word) = introducer(token) => {
                level.expects = Expectation::Table;
                level.introducer = word;
                level.name_parts = 0;
                if word == "from" {
                    level.lists_tables = true;
                }
            }
            Kind::Word if is(token.text, TABLE_LIST_ENDS) && expected != Expectation::Table => {
                level.lists_tables = false;
            }
            Kind::Word if token.is_word(&["only", "lateral"]) && expected == Expectation::Table => {
                level.expects = Expectation::Table;
            }
            Kind::Word | Kind::Quoted if expected == Expectation::Table => {
                if token.kind == Kind::Quoted && token.text.contains(['/', '.', '\\']) {
                    return true;
                }
                level.name_parts += 1;
                if level.name_parts > 1 && is(token.text, FILE_EXTENSIONS) {
                    return true;
                }
                level.expects = Expectation::RestOfName;
            }
            Kind::Literal if expected == Expectation::Table || prefixes_string(part, index) => return true,
            Kind::Open => {
                let callee = index.checked_sub(1).map(|before| part[before]);
                if expected == Expectation::RestOfName
                    && is(level.introducer, CALLING_INTRODUCERS)
                    && callee.is_some_and(|name| !is(name.text, DUCKDB_TABLE_FUNCTIONS) && !name.is_word(&["values"]))
                {
                    return true;
                }
                let introducer = match expected {
                    Expectation::Table => level.introducer,
                    _ => "",
                };
                let separates = calls_function_taking_from(part, index);
                levels.push(Level::new(separates, expected_inside(expected), introducer));
            }
            Kind::Close => {
                if levels.len() > 1 {
                    levels.pop();
                }
            }
            Kind::Comma => {
                if level.lists_tables {
                    level.expects = Expectation::Table;
                    level.name_parts = 0;
                }
            }
            Kind::Other if expected == Expectation::RestOfName && matches!(token.text, "." | ":" | "&") => {
                level.expects = Expectation::Table;
                if token.text != "." {
                    level.name_parts = 0;
                }
            }
            _ => {}
        }
    }
    false
}

// `FROM (notes JOIN 'payroll.csv' USING (id))` groups tables, and any other `(` starts afresh.
fn expected_inside(expected: Expectation) -> Expectation {
    match expected {
        Expectation::Table => Expectation::Table,
        _ => Expectation::Nothing,
    }
}

// `SELECT 1_000FROM 'a.csv'` reaches FROM, since a number ends there.
fn introducer(token: &Code<'_>) -> Option<&'static str> {
    if let Some(word) = TABLE_INTRODUCERS.iter().find(|word| token.is_word(&[**word])) {
        return Some(word);
    }
    let starts_a_name = token
        .text
        .chars()
        .next()
        .is_some_and(|first| first.is_alphabetic() || first == '_');
    match starts_a_name {
        true => None,
        false => TABLE_INTRODUCERS.iter().copied().find(|word| {
            token.text.len() > word.len()
                && token
                    .text
                    .get(token.text.len() - word.len()..)
                    .is_some_and(|end| end.eq_ignore_ascii_case(word))
        }),
    }
}

// `E'payroll.csv'`: a letter written against the string is its prefix, not a table's name.
fn prefixes_string(part: &[Code<'_>], index: usize) -> bool {
    index > 0 && {
        let before = part[index - 1];
        before.kind == Kind::Word
            && before.text.as_ptr() as usize + before.text.len() == part[index].text.as_ptr() as usize
    }
}

fn compares_distinct(part: &[Code<'_>], index: usize) -> bool {
    index >= 2 && part[index - 1].is_word(&["distinct"]) && part[index - 2].is_word(&["is", "not"])
}

// `INSERT INTO trim (FROM 'a.csv')` holds a query: a table may carry one of the names.
fn calls_function_taking_from(part: &[Code<'_>], index: usize) -> bool {
    if index == 0 || !part[index - 1].is_word(FROM_TAKING_FUNCTIONS) {
        return false;
    }
    index < 2
        || !(part[index - 2].is_word(&["into"]) || (part[index - 2].kind == Kind::Other && part[index - 2].text == "."))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn reaches_on_duckdb(sql: &str) -> bool {
        reaches_outside_database(sql, SqlGrammar::DuckDb)
    }

    #[test]
    fn duckdb_file_readers_reach_outside() {
        for sql in [
            "SELECT content FROM read_text('/home/ada/.ssh/id_ed25519')",
            "SELECT * FROM read_blob('/etc/passwd')",
            "SELECT * FROM read_csv('/x.csv')",
            "SELECT * FROM read_csv_auto('/x.csv')",
            "SELECT * FROM read_json('/x.json')",
            "SELECT * FROM read_ndjson_objects('/x.json')",
            "SELECT * FROM read_parquet('/x.parquet')",
            "SELECT * FROM READ_PARQUET (['a', 'b'])",
            "SELECT * FROM parquet_metadata('/x.parquet')",
            "SELECT * FROM glob('/home/ada/**')",
            "SELECT * FROM sniff_csv('/x.csv')",
            "SELECT * FROM query_table('/x.csv')",
            "SELECT * FROM query('SELECT 1')",
            "SELECT * FROM 'x.csv'",
            "SELECT * FROM \"/home/ada/x.csv\"",
            "SELECT * FROM finances.csv",
            "SELECT * FROM notes.\"csv\"",
            "SELECT * FROM backup.duckdb",
            "TABLE \"/x.csv\"",
            "DESCRIBE '/x.csv'",
            "SHOW '/x.csv'",
            "DESCRIBE SELECT * FROM read_csv('/f', header = true, skip = 3)",
            "EXPLAIN SELECT * FROM read_csv('/f', header = true, skip = 3)",
            "SELECT * FROM enable_logging('QueryLog', storage_path = '/tmp/x')",
            "SELECT * FROM system.main.read_blob/* c */('/etc/passwd')",
            "WITH f AS (SELECT * FROM \"read_blob\" ('/etc/passwd')) SELECT * FROM f",
            "SELECT * FROM read_text\u{a0}('/etc/passwd')",
            "SELECT * FROM U&\"read_text\"('x')",
            "SELECT * FROM (FROM read_text('x'))",
            "FROM read_text('x')",
            "SELECT * FROM odbc_query('DSN=x', 'DROP TABLE t')",
            "SELECT * FROM quack_serve('x')",
            "SELECT * FROM notes, read_text('x')",
            "SELECT * FROM notes JOIN read_text('x') ON true",
            "SELECT getenv('HOME')",
            "SELECT * FROM notes AS values, 'payroll.csv'",
            "SELECT 1_000FROM 'payroll.csv'",
            "SELECT * FROM E'payroll.csv'",
            "SELECT * FROM U&'payroll.csv'",
            "SELECT * FROM p: 'payroll.csv'",
            "DELETE FROM notes USING 'payroll.csv' p WHERE p.id = notes.id",
            "SELECT * FROM notes LEFT OUTER JOIN 'payroll.parquet' p ON p.id = notes.id",
        ] {
            assert!(reaches_on_duckdb(sql), "{sql}");
        }
    }

    #[test]
    fn duckdb_reads_inside_the_database_stay_inside() {
        for sql in [
            "SELECT 'a.csv' FROM notes WHERE path = 'c.csv'",
            "SELECT * FROM \"main\".\"notes\"",
            "SELECT * FROM range(1, 10)",
            "SELECT * FROM main.range(1, 10)",
            "SELECT extract(year FROM '2026-01-01'::DATE)",
            "SELECT trim('x' FROM 'xax')",
            "SELECT substring('abc' FROM 2 FOR 1)",
            "SELECT read_at, glob, query FROM notes WHERE name GLOB 'a*'",
            "SELECT * FROM duckdb_tables()",
            "SELECT count(*) FROM notes GROUP BY kind ORDER BY kind DESC, count(*)",
            "SELECT * FROM notes n JOIN tags t ON t.note = n.id WHERE t.name IN ('a', 'b')",
            "SELECT * FROM (SELECT * FROM notes) AS n",
            "DESCRIBE notes",
            "SHOW TABLES",
            "TABLE notes",
            "SELECT * FROM notes WHERE id IN (SELECT note FROM tags)",
            "SELECT * FROM read_text",
            "SELECT * FROM notes, (SELECT 'a.csv', 'b.csv') s",
            "SELECT * FROM (VALUES ('a.csv'), ('b.csv')) AS t(path)",
            "SELECT * FROM notes WHERE body IS DISTINCT FROM 'a.csv' OR body IS NOT DISTINCT FROM 'b.csv'",
            "SELECT * FROM notes ORDER BY id DESC, \"meta.path\"",
            "CREATE TABLE notes (path VARCHAR DEFAULT 'a.csv')",
            "SELECT * FROM notes n JOIN tags t USING (id) WHERE t.name = 'x'",
            "PIVOT notes ON year USING sum(salary)",
            "SELECT * FROM generate_series(1, 3) AS t(x), notes",
            "SELECT _from, 'a.csv' FROM notes",
        ] {
            assert!(!reaches_on_duckdb(sql), "{sql}");
        }
    }

    #[test]
    fn file_and_server_functions_reach_outside_on_their_engines() {
        for (sql, grammar) in [
            ("SELECT pg_read_file('/etc/passwd')", SqlGrammar::PostgreSql),
            ("SELECT * FROM pg_ls_dir('.')", SqlGrammar::PostgreSql),
            ("SELECT pg_stat_file('postgresql.conf')", SqlGrammar::PostgreSql),
            ("SELECT U&\"pg_read_file\"('/etc/passwd')", SqlGrammar::PostgreSql),
            ("SELECT LOAD_FILE('/etc/passwd')", SqlGrammar::MySql),
            ("SELECT * FROM t INTO OUTFILE '/tmp/x'", SqlGrammar::MySql),
            (
                "SELECT * FROM sys.dm_os_enumerate_filesystem('C:\\', '*')",
                SqlGrammar::MsSql,
            ),
            (
                "SELECT * FROM sys.fn_get_audit_file('C:\\a\\*', default, default)",
                SqlGrammar::MsSql,
            ),
            ("EXEC xp_cmdshell 'dir'", SqlGrammar::MsSql),
            ("SELECT * FROM file('x.csv')", SqlGrammar::ClickHouse),
            ("SELECT * FROM url('http://x', CSV)", SqlGrammar::ClickHouse),
            ("SELECT * FROM remoteSecure('host', db.t)", SqlGrammar::ClickHouse),
            ("SELECT * FROM icebergS3('s3://b/t')", SqlGrammar::ClickHouse),
            ("SELECT readfile('/etc/passwd')", SqlGrammar::Sqlite),
            ("SELECT load_extension('x')", SqlGrammar::Sqlite),
            ("COPY orders TO '/tmp/orders.csv'", SqlGrammar::PostgreSql),
            ("COPY orders TO '/tmp/orders.csv'", SqlGrammar::DuckDb),
            ("ATTACH '/home/ada/other.duckdb' AS other", SqlGrammar::DuckDb),
            ("INSTALL httpfs", SqlGrammar::DuckDb),
            ("LOAD httpfs", SqlGrammar::DuckDb),
            ("EXPORT DATABASE '/tmp/dump'", SqlGrammar::DuckDb),
            ("DO $$ BEGIN PERFORM 1; END $$", SqlGrammar::PostgreSql),
            ("BULK INSERT t FROM 'C:\\x.csv'", SqlGrammar::MsSql),
        ] {
            assert!(reaches_outside_database(sql, grammar), "{sql} on {grammar:?}");
        }
    }

    #[test]
    fn engine_lists_stay_on_their_engine() {
        for (sql, grammar) in [
            ("SELECT * FROM 'x.csv'", SqlGrammar::PostgreSql),
            ("SELECT file, url FROM documents", SqlGrammar::ClickHouse),
            ("SELECT glob('a*', name) FROM t", SqlGrammar::Sqlite),
            ("SELECT * FROM read_text('x')", SqlGrammar::PostgreSql),
            ("SELECT query FROM history", SqlGrammar::DuckDb),
            ("SELECT * FROM orders", SqlGrammar::MySql),
        ] {
            assert!(!reaches_outside_database(sql, grammar), "{sql} on {grammar:?}");
        }
    }

    #[test]
    fn a_users_own_file_read_stays_a_read_in_the_editor() {
        use crate::sql_syntax::{StatementAccess, statement_access};

        assert_eq!(
            statement_access("SELECT * FROM read_csv('x.csv')", SqlGrammar::DuckDb),
            StatementAccess::Read
        );
    }

    #[test]
    fn the_names_are_the_ones_both_apps_share() {
        let shared: BTreeMap<String, Vec<String>> =
            serde_json::from_str(include_str!("../../tests/fixtures/outside_reach.json")).unwrap();
        let named = |names: &[&str]| names.iter().map(|name| name.to_string()).collect::<Vec<_>>();
        let listed: BTreeMap<String, Vec<String>> = [
            ("clickhouse_families", named(CLICKHOUSE_FAMILIES)),
            ("clickhouse_functions", named(CLICKHOUSE_FUNCTIONS)),
            ("duckdb_families", named(DUCKDB_FAMILIES)),
            ("duckdb_functions", named(DUCKDB_FUNCTIONS)),
            ("filesystem_functions", named(FILESYSTEM_FUNCTIONS)),
            ("filesystem_names", named(FILESYSTEM_NAMES)),
            ("filesystem_or_code_keywords", named(FILESYSTEM_OR_CODE_KEYWORDS)),
            (
                "filesystem_word_runs",
                FILESYSTEM_WORD_RUNS.iter().map(|run| run.join(" ")).collect(),
            ),
        ]
        .into_iter()
        .map(|(family, mut names)| {
            names.sort();
            (family.to_owned(), names)
        })
        .collect();
        assert_eq!(listed, shared);
    }
}
