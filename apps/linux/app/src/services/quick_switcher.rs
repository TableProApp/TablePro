pub use tablepro_app_services::quick_switcher::{QuickItem, QuickTarget, favorite_items, filter};
use tablepro_core::TableInfo;

pub fn relation_items(tables: &[TableInfo], views: &[TableInfo]) -> Vec<QuickItem> {
    tablepro_app_services::quick_switcher::relation_items(tables, views, &crate::tr!("Table"), &crate::tr!("View"))
}

fn commands() -> Vec<(&'static str, String)> {
    vec![
        ("open-editor", crate::tr!("New SQL tab")),
        ("new-window", crate::tr!("New window")),
        ("show-history", crate::tr!("Query history")),
        ("show-catalog", crate::tr!("Catalog objects")),
        ("show-activity", crate::tr!("Server activity")),
        ("explain-query", crate::tr!("Explain query")),
        ("jump-column", crate::tr!("Jump to column")),
        ("open-filter", crate::tr!("Filter rows")),
        ("refresh-page", crate::tr!("Refresh the current page")),
        ("save-changes", crate::tr!("Save changes")),
        ("undo-change", crate::tr!("Undo change")),
        ("redo-change", crate::tr!("Redo change")),
        ("reopen-closed-tab", crate::tr!("Reopen closed tab")),
        ("export-csv", crate::tr!("Export results as CSV")),
        ("export-json", crate::tr!("Export results as JSON")),
        ("export-all-csv", crate::tr!("Export all rows as CSV")),
        ("export-all-json", crate::tr!("Export all rows as JSON")),
        ("preferences", crate::tr!("Preferences")),
        ("shortcuts", crate::tr!("Keyboard shortcuts")),
    ]
}

pub fn command_items() -> Vec<QuickItem> {
    commands()
        .into_iter()
        .map(|(action, title)| QuickItem {
            target: QuickTarget::Command(action),
            title,
            subtitle: crate::tr!("Command"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_command_names_an_action_the_window_registers() {
        let registered = include_str!("../ui/app/shortcuts.rs");
        for (action, _) in commands() {
            assert!(registered.contains(&format!("\"{action}\"")), "{action}");
        }
    }
}
