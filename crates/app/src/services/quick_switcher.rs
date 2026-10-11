use tablepro_core::TableInfo;
use tablepro_storage::SavedQuery;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QuickTarget {
    Favorite(Uuid),
    Tab(Uuid),
    Connection(Uuid),
    Relation { schema: Option<String>, name: String },
    Command(&'static str),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickItem {
    pub target: QuickTarget,
    pub title: String,
    pub subtitle: String,
}

pub fn favorite_items(favorites: &[SavedQuery]) -> Vec<QuickItem> {
    tablepro_storage::rank_favorites(favorites)
        .into_iter()
        .map(|favorite| QuickItem {
            target: QuickTarget::Favorite(favorite.id),
            title: favorite.name.clone(),
            subtitle: one_line(&favorite.sql),
        })
        .collect()
}

pub fn relation_items(tables: &[TableInfo], views: &[TableInfo]) -> Vec<QuickItem> {
    let tables = tables.iter().map(|table| (table, crate::tr!("Table")));
    let views = views.iter().map(|view| (view, crate::tr!("View")));
    tables
        .chain(views)
        .map(|(relation, kind)| QuickItem {
            target: QuickTarget::Relation {
                schema: relation.schema.clone(),
                name: relation.name.clone(),
            },
            title: match &relation.schema {
                Some(schema) => format!("{schema}.{}", relation.name),
                None => relation.name.clone(),
            },
            subtitle: kind,
        })
        .collect()
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

fn is_command(item: &QuickItem) -> bool {
    matches!(item.target, QuickTarget::Command(_))
}

pub fn filter(items: &[QuickItem], needle: &str) -> Vec<QuickItem> {
    let needle = needle.trim().to_lowercase();
    if let Some(command_needle) = needle.strip_prefix('>') {
        let commands: Vec<QuickItem> = items.iter().filter(|item| is_command(item)).cloned().collect();
        if command_needle.trim().is_empty() {
            return commands;
        }
        return filter(&commands, command_needle);
    }
    if needle.is_empty() {
        return items.iter().filter(|item| !is_command(item)).cloned().collect();
    }
    let mut scored: Vec<(u32, usize, QuickItem)> = items
        .iter()
        .enumerate()
        .filter_map(|(position, item)| score(item, &needle).map(|score| (score, position, item.clone())))
        .collect();
    scored.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| left.1.cmp(&right.1)));
    scored.into_iter().map(|(_, _, item)| item).collect()
}

fn score(item: &QuickItem, needle: &str) -> Option<u32> {
    let title = item.title.to_lowercase();
    let name = match &item.target {
        QuickTarget::Relation { name, .. } => name.to_lowercase(),
        _ => title.clone(),
    };
    if title == needle || name == needle {
        return Some(100);
    }
    if title.starts_with(needle) || name.starts_with(needle) {
        return Some(80);
    }
    if title.contains(needle) {
        return Some(60);
    }
    if item.subtitle.to_lowercase().contains(needle) {
        return Some(40);
    }
    is_subsequence(&title, needle).then_some(20)
}

fn is_subsequence(haystack: &str, needle: &str) -> bool {
    let mut characters = haystack.chars();
    needle
        .chars()
        .all(|wanted| characters.any(|candidate| candidate == wanted))
}

fn one_line(sql: &str) -> String {
    let collapsed = sql.split_whitespace().collect::<Vec<&str>>().join(" ");
    let mut out: String = collapsed.chars().take(80).collect();
    if collapsed.chars().count() > 80 {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(title: &str, subtitle: &str) -> QuickItem {
        QuickItem {
            target: QuickTarget::Favorite(Uuid::new_v4()),
            title: title.to_string(),
            subtitle: subtitle.to_string(),
        }
    }

    fn command(action: &'static str, title: &str) -> QuickItem {
        QuickItem {
            target: QuickTarget::Command(action),
            title: title.to_string(),
            subtitle: "Command".to_string(),
        }
    }

    #[test]
    fn commands_stay_out_of_the_empty_list_and_are_the_only_hits_after_a_prompt_character() {
        let items = vec![
            item("daily revenue", ""),
            command("export-csv", "Export results as CSV"),
        ];
        assert_eq!(filter(&items, "").len(), 1);
        assert_eq!(filter(&items, ">").len(), 1);
        assert_eq!(filter(&items, ">export")[0].target, QuickTarget::Command("export-csv"));
        assert!(filter(&items, ">daily").is_empty());
    }

    #[test]
    fn a_plain_search_finds_commands_beside_the_other_items() {
        let items = vec![item("export notes", ""), command("export-csv", "Export results as CSV")];
        assert_eq!(filter(&items, "export").len(), 2);
    }

    #[test]
    fn every_command_names_an_action_the_window_registers() {
        let registered = include_str!("../ui/app/shortcuts.rs");
        for (action, _) in commands() {
            assert!(registered.contains(&format!("\"{action}\"")), "{action}");
        }
    }

    #[test]
    fn an_empty_needle_keeps_the_incoming_order() {
        let items = vec![item("zeta", ""), item("alpha", "")];
        assert_eq!(filter(&items, "  "), items);
    }

    #[test]
    fn exact_and_prefix_matches_rank_above_substring_matches() {
        let items = vec![
            item("revenue by month", ""),
            item("daily", ""),
            item("daily revenue", ""),
        ];
        let filtered = filter(&items, "daily");
        assert_eq!(filtered[0].title, "daily");
        assert_eq!(filtered[1].title, "daily revenue");
        assert_eq!(filtered.len(), 2);
    }

    #[test]
    fn a_statement_match_ranks_below_a_title_match() {
        let items = vec![
            item("nightly job", "SELECT * FROM orders"),
            item("orders overview", "SELECT 1"),
        ];
        let filtered = filter(&items, "orders");
        assert_eq!(filtered[0].title, "orders overview");
        assert_eq!(filtered[1].title, "nightly job");
    }

    #[test]
    fn initials_match_as_a_subsequence() {
        let items = vec![item("daily revenue export", "")];
        assert_eq!(filter(&items, "dre").len(), 1);
        assert!(filter(&items, "zzz").is_empty());
    }

    fn relation(schema: Option<&str>, name: &str) -> TableInfo {
        TableInfo {
            schema: schema.map(str::to_string),
            name: name.to_string(),
        }
    }

    #[test]
    fn a_table_matches_by_its_own_name_and_by_its_schema_qualified_name() {
        let items = relation_items(
            &[
                relation(Some("sales"), "orders"),
                relation(Some("public"), "order_lines"),
            ],
            &[relation(Some("reporting"), "orders")],
        );

        let by_name: Vec<String> = filter(&items, "orders").into_iter().map(|item| item.title).collect();
        assert_eq!(by_name, vec!["sales.orders", "reporting.orders", "public.order_lines"]);

        let qualified = filter(&items, "reporting.ord");
        assert_eq!(qualified.len(), 1);
        assert_eq!(
            qualified[0].target,
            QuickTarget::Relation {
                schema: Some("reporting".into()),
                name: "orders".into()
            }
        );
    }

    #[test]
    fn a_table_without_a_schema_is_titled_by_its_name() {
        let items = relation_items(&[relation(None, "notes")], &[]);
        assert_eq!(items[0].title, "notes");
    }

    #[test]
    fn matching_ignores_case() {
        let items = vec![item("Daily Revenue", "")];
        assert_eq!(filter(&items, "DAILY").len(), 1);
    }

    #[test]
    fn favorite_items_use_recency_order_and_a_single_line_statement() {
        let mut recent = SavedQuery::new("zeta".into(), "SELECT\n  1".into(), None, None);
        recent.last_used_at = Some(chrono::Utc::now());
        let older = SavedQuery::new("alpha".into(), "SELECT 2".into(), None, None);

        let items = favorite_items(&[older, recent]);

        assert_eq!(items[0].title, "zeta");
        assert_eq!(items[0].subtitle, "SELECT 1");
        assert_eq!(items[1].title, "alpha");
    }

    #[test]
    fn long_statements_are_truncated_for_display() {
        let sql = "SELECT ".to_string() + &"column_name, ".repeat(20);
        let favorite = SavedQuery::new("wide".into(), sql, None, None);
        let items = favorite_items(&[favorite]);
        assert!(items[0].subtitle.ends_with('…'));
        assert!(items[0].subtitle.chars().count() <= 81);
    }
}
