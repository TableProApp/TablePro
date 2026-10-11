use sqlparser::dialect::Dialect;
use sqlparser::tokenizer::{Token, Tokenizer};

use crate::admin_functions::is_administrative_function_name;
use crate::classify::{StatementClass, StatementDetails};
use crate::effects::Effects;
use sqlparser::ast::{CopySource, CopyTarget, Set, Statement};

pub(crate) fn merge_script_class(current: StatementClass, next: StatementClass) -> StatementClass {
    if current == StatementClass::Administrative || next == StatementClass::Administrative {
        return StatementClass::Administrative;
    }
    if current == StatementClass::Select {
        return next;
    }
    if next == StatementClass::Select || current == next {
        return current;
    }
    StatementClass::Other
}

pub(crate) fn truncate_facts<T: ToString>(tables: impl IntoIterator<Item = T>) -> StatementDetails {
    StatementDetails {
        effects: Effects::WRITES_ROWS,
        class: StatementClass::Ddl,
        tables: tables.into_iter().map(|table| table.to_string()).collect(),
        has_where: false,
        contains_unscoped_dml: true,
    }
}

pub(crate) fn statement_effects(stmt: &Statement, facts: &StatementDetails) -> Effects {
    read_effects(stmt, facts)
        .union(write_effects(stmt, facts))
        .union(administrative_effects(stmt, facts))
        .union(transaction_effects(stmt, facts))
        .union(session_effects(stmt))
        .union(host_access_effects(stmt))
}

fn read_effects(stmt: &Statement, facts: &StatementDetails) -> Effects {
    if statement_reads(stmt, facts) {
        Effects::READS
    } else {
        Effects::EMPTY
    }
}

fn write_effects(stmt: &Statement, facts: &StatementDetails) -> Effects {
    let writes_rows = facts.effects.contains(Effects::WRITES_ROWS)
        || matches!(
            stmt,
            Statement::Insert(_) | Statement::Truncate { .. } | Statement::Update { .. } | Statement::Delete(_)
        )
        || matches!(stmt, Statement::Copy { to: false, .. });
    let writes_schema = facts.effects.contains(Effects::WRITES_SCHEMA)
        || (facts.class == StatementClass::Ddl && !matches!(stmt, Statement::Truncate { .. }));
    let unknown = facts.effects.contains(Effects::UNKNOWN)
        || (facts.class == StatementClass::Other && !matches!(stmt, Statement::Query(_)));
    let mut effects = Effects::EMPTY;
    if writes_rows {
        effects = effects.union(Effects::WRITES_ROWS);
    }
    if writes_schema {
        effects = effects.union(Effects::WRITES_SCHEMA);
    }
    if unknown {
        effects = effects.union(Effects::UNKNOWN);
    }
    effects
}

fn administrative_effects(stmt: &Statement, facts: &StatementDetails) -> Effects {
    if facts.class == StatementClass::Administrative
        || matches!(
            stmt,
            Statement::Install { .. }
                | Statement::Load { .. }
                | Statement::Grant { .. }
                | Statement::Revoke { .. }
                | Statement::CreateRole { .. }
                | Statement::AlterRole { .. }
                | Statement::CreateDatabase { .. }
                | Statement::CreateExtension { .. }
                | Statement::DropExtension { .. }
                | Statement::Kill { .. }
        )
    {
        Effects::ADMIN
    } else {
        Effects::EMPTY
    }
}

fn transaction_effects(stmt: &Statement, facts: &StatementDetails) -> Effects {
    if facts.class == StatementClass::Transaction || matches!(stmt, Statement::Set(Set::SetTransaction { .. })) {
        Effects::TRANSACTION_CONTROL
    } else {
        Effects::EMPTY
    }
}

fn session_effects(stmt: &Statement) -> Effects {
    if matches!(
        stmt,
        Statement::Set(_)
            | Statement::Use(_)
            | Statement::Pragma { .. }
            | Statement::Discard { .. }
            | Statement::Declare { .. }
            | Statement::Deallocate { .. }
            | Statement::Execute { .. }
            | Statement::Prepare { .. }
            | Statement::Open(_)
            | Statement::Fetch { .. }
            | Statement::Close { .. }
    ) {
        Effects::SESSION_STATE
    } else {
        Effects::EMPTY
    }
}

fn host_access_effects(stmt: &Statement) -> Effects {
    if matches!(
        stmt,
        Statement::Copy {
            target: CopyTarget::File { .. } | CopyTarget::Program { .. },
            ..
        }
    ) || matches!(
        stmt,
        Statement::Install { .. }
            | Statement::Load { .. }
            | Statement::Directory { .. }
            | Statement::Unload { .. }
            | Statement::CopyIntoSnowflake { .. }
    ) {
        Effects::HOST_OR_FILE_ACCESS
    } else {
        Effects::EMPTY
    }
}

fn statement_reads(stmt: &Statement, facts: &StatementDetails) -> bool {
    if facts.class == StatementClass::Select || matches!(stmt, Statement::Query(_) | Statement::ExplainTable { .. }) {
        return true;
    }
    match stmt {
        Statement::Insert(insert) => insert.source.is_some(),
        Statement::Update { .. } | Statement::Delete(_) | Statement::Merge { .. } => true,
        Statement::CreateTable(create) => create.query.is_some(),
        Statement::CreateView { .. } => true,
        Statement::Copy { source, .. } => matches!(source, CopySource::Table { .. } | CopySource::Query(_)),
        _ => false,
    }
}

pub(crate) fn sql_effects_from_tokens(sql: &str, dialect: &dyn Dialect, driver_id: &str) -> (Effects, bool) {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return (Effects::EMPTY, false);
    };
    let mut effects = Effects::EMPTY;
    let mut legacy_administrative_call = false;
    for (index, token) in tokens.iter().enumerate() {
        let Token::Word(word) = token else {
            continue;
        };
        let name = word.value.as_str();
        let call = tokens[index + 1..]
            .iter()
            .find(|next| !matches!(next, Token::Whitespace(_)))
            .is_some_and(|next| matches!(next, Token::LParen));
        if is_administrative_procedure_name(driver_id, name) {
            effects = effects.union(Effects::ADMIN);
            legacy_administrative_call = true;
            if name.to_ascii_lowercase().starts_with("xp_") {
                effects = effects.union(Effects::HOST_OR_FILE_ACCESS);
            }
        }
        if !call {
            continue;
        }
        if is_administrative_function_name(name) || is_engine_administrative_function_name(driver_id, name) {
            effects = effects.union(Effects::ADMIN);
            legacy_administrative_call = true;
        }
        if is_host_or_file_access_function(driver_id, name) {
            effects = effects.union(Effects::HOST_OR_FILE_ACCESS);
        }
        if is_session_state_function(driver_id, name) {
            effects = effects.union(Effects::SESSION_STATE);
            if driver_id == "mysql" {
                effects = effects.union(Effects::ADMIN);
            }
        }
        if is_host_write_function(driver_id, name) {
            effects = effects.union(Effects::ADMIN);
        }
    }
    (effects, legacy_administrative_call)
}

fn is_host_or_file_access_function(driver_id: &str, name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    match driver_id {
        "postgres" => matches!(
            lowered.as_str(),
            "lo_export"
                | "lo_import"
                | "pg_read_file"
                | "pg_read_binary_file"
                | "pg_stat_file"
                | "pg_ls_dir"
                | "pg_ls_logdir"
                | "pg_ls_waldir"
                | "pg_ls_archive_statusdir"
                | "pg_ls_tmpdir"
                | "pg_file_write"
                | "pg_file_rename"
                | "pg_file_unlink"
        ),
        "mysql" => lowered == "load_file",
        "sqlite" => matches!(lowered.as_str(), "readfile" | "writefile" | "load_extension"),
        "duckdb" => matches!(
            lowered.as_str(),
            "read_text"
                | "read_blob"
                | "read_csv"
                | "read_csv_auto"
                | "read_parquet"
                | "read_json"
                | "read_json_auto"
                | "read_ndjson"
                | "read_ndjson_auto"
                | "write_csv"
                | "write_parquet"
        ),
        _ => false,
    }
}

fn is_session_state_function(driver_id: &str, name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    lowered == "set_config"
        || (driver_id == "postgres" && lowered.starts_with("pg_advisory_"))
        || (driver_id == "mysql" && matches!(lowered.as_str(), "get_lock" | "release_lock" | "release_all_locks"))
}

fn is_host_write_function(driver_id: &str, name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    match driver_id {
        "duckdb" => matches!(lowered.as_str(), "write_csv" | "write_parquet"),
        _ => false,
    }
}

fn is_engine_administrative_function_name(driver_id: &str, name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    match driver_id {
        "mysql" => matches!(lowered.as_str(), "benchmark" | "load_file" | "sleep"),
        // The fileio and misc loadable extensions turn a SELECT into host
        // file access or module loading; SELECT writefile('~/.bashrc', ...)
        // must not classify as a plain read wherever they are loaded.
        "sqlite" => matches!(
            lowered.as_str(),
            "writefile" | "readfile" | "edit" | "load_extension" | "fts3_tokenizer"
        ),
        _ => false,
    }
}

fn is_administrative_procedure_name(driver_id: &str, name: &str) -> bool {
    if driver_id != "mssql" {
        return false;
    }
    let lowered = name.to_ascii_lowercase();
    lowered.starts_with("xp_")
        || matches!(
            lowered.as_str(),
            "sp_addsrvrolemember" | "sp_configure" | "sp_lock" | "sp_password" | "sp_who" | "sp_who2"
        )
}
