use super::connection_lookup::resolve;
use super::sql_source;
use crate::answers::{Results, parse};
use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::command_line::QueryArgs;
use crate::console::Console;
use crate::host::Host;
use crate::output::{OutputFormat, Table};
use crate::tool_arguments::QueryArguments;

pub(super) async fn run(arguments: &QueryArgs, host: &dyn Host, console: &mut Console<'_>) -> Result<(), CommandError> {
    // A usage error is reported before TablePro is asked anything.
    let sql = sql_source::read(arguments, console.terminal())?;
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = QueryArguments {
        connection_id: connection.id(),
        query: &sql,
        database: arguments.database.as_deref(),
        read_only: arguments.read_only,
        max_rows: arguments.limit,
        timeout_seconds: arguments.timeout,
    };
    let deadline = client.deadlines().statement(arguments.timeout);
    // A connection can drop after the server ran a write, so only a statement held to reading is sent twice.
    let answer = match arguments.read_only {
        true => {
            connection
                .call_within(&client, console, "execute_query", &request, deadline)
                .await?
        }
        false => client.call_within("execute_query", &request, deadline).await?,
    };
    let results: Results = parse(&answer)?;
    write(&results, arguments.format, console)
}

// Rows go to standard output; what the database or this command says about them goes to standard error.
fn write(results: &Results, format: Option<OutputFormat>, console: &mut Console<'_>) -> Result<(), CommandError> {
    let tables: Vec<Table> = results.result_sets.iter().map(|set| set.to_table()).collect();
    console.tables(&tables, format)?;
    for notice in &results.notices {
        console.line(notice);
    }
    for note in results.notes() {
        console.note(note);
    }
    for (set, table) in results.result_sets.iter().zip(&tables) {
        if set.truncated {
            let shown = match table.rows.len() {
                1 => "row".to_owned(),
                count => format!("{count} rows"),
            };
            console.note(&format!("Showing the first {shown}. Pass --limit to change it."));
        }
    }
    if tables.iter().all(|table| table.columns.is_empty())
        && let Some(affected) = results.rows_affected
    {
        console.line(&match affected {
            1 => "1 row affected.".to_owned(),
            count => format!("{count} rows affected."),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::Terminal;

    fn written(text: &str, terminal: Terminal) -> (String, String) {
        let results: Results = parse(text).expect("a results document");
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut console = Console::new(&mut out, &mut err, terminal);
        write(&results, None, &mut console).expect("written");
        (
            String::from_utf8(out).expect("UTF-8"),
            String::from_utf8(err).expect("UTF-8"),
        )
    }

    #[test]
    fn the_servers_notes_go_to_standard_error_after_the_rows() {
        let text = r#"{"result_sets":[{"columns":[{"name":"id","type":"integer"}],"rows":[{"id":1}],
            "row_count":1,"truncated":true}],"execution_time_ms":2,
            "notes":["The statement left a transaction open, and it was rolled back when the call's connection closed.",
            "Some values could not be decoded by TablePro and are shown as null.",
            "A result set has more rows than the limit; ask for fewer with a WHERE clause or raise max_rows."]}"#;

        let (out, err) = written(text, Terminal::default());

        assert_eq!(out, "id\n1\n");
        assert_eq!(
            err,
            "tablepro: The statement left a transaction open, and it was rolled back when the call's connection closed.\n\
             tablepro: Some values could not be decoded by TablePro and are shown as null.\n\
             tablepro: Showing the first row. Pass --limit to change it.\n"
        );
    }

    #[test]
    fn a_note_on_a_terminal_is_escaped() {
        let text =
            r#"{"result_sets":[],"rows_affected":0,"execution_time_ms":1,"notes":["bad \u001b]52;c;eA==\u0007"]}"#;
        let terminal = Terminal {
            stderr: true,
            ..Terminal::default()
        };

        let (_, err) = written(text, terminal);

        assert_eq!(err, "tablepro: bad \\x1B]52;c;eA==\\x07\n0 rows affected.\n");
    }
}
