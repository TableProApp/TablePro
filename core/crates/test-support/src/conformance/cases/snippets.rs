//! The SQL editor's built-in snippets, with their stops filled in, run
//! the way the editor runs a script.

use tablepro_core::EditorSessionOptions;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, builtin_snippets};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{connect, expect, run_completed, run_options, unexpected, unique, writable};
use crate::conformance::{ConformanceEngine, ConformanceFailure};
use crate::snippet_text::expand_snippet;

const CASE: &str = "builtin_snippets_run_as_written";

/// The table comes first and the rows last, so each one has what it
/// names. A grammar runs the ones it offers.
const ORDER: [&str; 7] = ["ctab", "cidx", "ins", "sel", "selj", "upd", "del"];

/// The key of the row the CQL snippets write.
const CQL_KEY: &str = "5b6962dd-3f90-4c93-8f61-eabfa4a803e2";

/// Each built-in snippet of the connection's grammar, its table and
/// index names and its values filled in and the rest left as written,
/// is one statement the server runs.
pub async fn builtin_snippets_run_as_written<E: ConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    let dialect = connection.dialect();
    let grammar = dialect.grammar();
    let snippets = builtin_snippets(grammar);
    let order: Vec<&str> = ORDER
        .into_iter()
        .filter(|trigger| snippets.iter().any(|snippet| snippet.trigger == *trigger))
        .collect();
    expect(CASE, snippets.len() == order.len(), || {
        format!(
            "{grammar:?} offers {} snippets and the case runs {}",
            snippets.len(),
            order.len()
        )
    })?;
    let table = dialect.qualify(&engine.scratch_table(&unique("snippet")));
    let index = unique("snippet_index");
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;

    for trigger in order {
        let snippet = snippets
            .iter()
            .find(|snippet| snippet.trigger == trigger)
            .ok_or_else(|| unexpected(CASE, format!("{grammar:?} has no `{trigger}` snippet")))?;
        let sql = expand_snippet(snippet.text, |default| fill(grammar, default, &table, &index))
            .ok_or_else(|| unexpected(CASE, format!("`{trigger}` does not expand: {}", snippet.text)))?;
        let plan = ScriptPlan::build(&sql, grammar, LexicalSettings::default_for(grammar));
        let statements: Vec<&str> = plan
            .batches()
            .iter()
            .filter_map(|batch| sql.get(batch.range.clone()))
            .map(str::trim)
            .filter(|statement| !statement.is_empty())
            .collect();
        let [statement] = statements.as_slice() else {
            return Err(unexpected(
                CASE,
                format!("`{trigger}` is {} statements: {statements:?}", statements.len()),
            ));
        };
        run_completed(CASE, session.as_ref(), statement, run_options()).await?;
    }

    run_completed(CASE, session.as_ref(), &format!("DROP TABLE {table}"), run_options()).await?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

/// The text a user would type into a stop, by the stop's default. A
/// default not named here, such as a column type, runs as written. CQL
/// writes and finds a row only by its whole key, so there the row and
/// the condition name `id` too.
fn fill(grammar: SqlGrammar, default: &str, table: &str, index: &str) -> Option<String> {
    let keyed = grammar == SqlGrammar::Cql;
    let text = match default {
        "table_name" | "other_table" => table.to_owned(),
        "index_name" => index.to_owned(),
        "column" => "name".to_owned(),
        "columns" if keyed => "id, name".to_owned(),
        "columns" => "name".to_owned(),
        "values" if keyed => format!("{CQL_KEY}, 'a'"),
        "values" => "'a'".to_owned(),
        "value" => "'b'".to_owned(),
        "condition" if keyed => format!("id = {CQL_KEY}"),
        "condition" => "name = 'a'".to_owned(),
        _ => return None,
    };
    Some(text)
}
