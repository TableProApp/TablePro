use super::connection_lookup::resolve;
use crate::answers::{Export, ExportAnswer, parse};
use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::command_line::ExportArgs;
use crate::console::Console;
use crate::host::Host;
use crate::output::ExportFormat;
use crate::tool_arguments::ExportArguments;

pub(super) async fn run(
    arguments: &ExportArgs,
    host: &(impl Host + Clone + Send + Sync + 'static),
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = ExportArguments {
        connection_id: connection.id(),
        format: arguments.format,
        tables: &arguments.tables,
        database: arguments.database.as_deref(),
        schema: arguments.schema.as_deref(),
        max_rows: arguments.limit,
    };
    let deadline = client.deadlines().tables(arguments.tables.len());
    let answer = connection
        .call_within(&client, console, "export_data", &request, deadline)
        .await?;
    let answer: ExportAnswer = parse(&answer)?;
    console.write_out(joined(&answer.exports, arguments.format).as_bytes())?;
    report(&answer, console);
    Ok(())
}

fn report(answer: &ExportAnswer, console: &mut Console<'_>) {
    for note in &answer.notes {
        console.note(note);
    }
    for export in answer.exports.iter().filter(|export| export.truncated) {
        console.note(&format!(
            "Exported the first {} rows of “{}”. Pass --limit to change it.",
            export.row_count, export.table
        ));
    }
}

// Several JSON exports become one array of arrays, so the output stays one document, as a query's sets do.
fn joined(exports: &[Export], format: ExportFormat) -> String {
    match (format, exports) {
        (ExportFormat::Json, [_, _, ..]) => {
            let arrays: Vec<&str> = exports.iter().map(|export| export.data.trim_end()).collect();
            format!("[\n{}\n]\n", arrays.join(",\n"))
        }
        _ => exports
            .iter()
            .map(|export| match export.data.ends_with('\n') {
                true => export.data.clone(),
                false => format!("{}\n", export.data),
            })
            .collect::<Vec<String>>()
            .join("\n"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::Terminal;

    fn export(table: &str, data: &str) -> Export {
        Export {
            table: table.to_owned(),
            row_count: 1,
            truncated: false,
            data: data.to_owned(),
        }
    }

    #[test]
    fn one_export_is_written_as_the_tool_made_it() {
        assert_eq!(joined(&[export("a", "id\n1\n")], ExportFormat::Csv), "id\n1\n");
        assert_eq!(joined(&[export("a", "[]")], ExportFormat::Json), "[]\n");
    }

    #[test]
    fn several_exports_stay_apart() {
        let csv = [export("a", "id\n1\n"), export("b", "id\n2")];
        let json = [export("a", "[{\"id\":1}]\n"), export("b", "[]")];

        assert_eq!(joined(&csv, ExportFormat::Csv), "id\n1\n\nid\n2\n");
        assert_eq!(joined(&json, ExportFormat::Json), "[\n[{\"id\":1}],\n[]\n]\n");
    }

    #[test]
    fn the_servers_notes_go_to_standard_error() {
        let answer: ExportAnswer = parse(
            r#"{"format":"csv","exports":[{"table":"orders","row_count":2,"truncated":true,"data":"id\n1\n2\n"}],
            "notes":["Some values could not be decoded by TablePro and are written as null."]}"#,
        )
        .expect("an export document");
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut console = Console::new(&mut out, &mut err, Terminal::default());

        report(&answer, &mut console);

        assert!(out.is_empty());
        assert_eq!(
            String::from_utf8(err).expect("UTF-8"),
            "tablepro: Some values could not be decoded by TablePro and are written as null.\n\
             tablepro: Exported the first 2 rows of “orders”. Pass --limit to change it.\n"
        );
    }
}
