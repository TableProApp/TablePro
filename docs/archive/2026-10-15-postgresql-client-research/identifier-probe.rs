fn table_key(table: &str) -> String {
    table
        .split('.')
        .map(|part| {
            part.trim_matches(|c| c == '"' || c == '`' || c == '[' || c == ']')
                .to_ascii_lowercase()
        })
        .collect::<Vec<_>>()
        .join(".")
}

fn split_table_reference(reference: &str) -> (Option<String>, String) {
    let cleaned = reference.replace(['"', '`', '[', ']'], "");
    match cleaned.rsplit_once('.') {
        Some((schema, table)) if !schema.is_empty() && !table.is_empty() => {
            (Some(schema.to_string()), table.to_string())
        }
        _ => (None, cleaned),
    }
}

fn main() {
println!("users={:?}; quoted Users={:?}", table_key("public.users"), table_key("public.\"Users\""));
println!("quoted dot={:?}", split_table_reference("\"odd.schema\".\"a.b\""));
println!("embedded quote={:?}", split_table_reference("public.\"a\"\"b\""));
}