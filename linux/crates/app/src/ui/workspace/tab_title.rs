use tablepro_core::meta::TableRef;

use super::editor_label::EditorLabel;
use super::structure_target::StructureTarget;
use super::tab_identity::TabIdentity;
use super::table_naming::TableNaming;
use crate::ui::editor::derive_tab_label;

/// A tab's title and the tooltip that says more than it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TabTitle {
    pub label: String,
    pub tooltip: Option<String>,
}

/// The one place a tab's title is made. Unsaved changes never change it;
/// the page's icon says so.
pub(crate) fn resolve_tab_title(identity: &TabIdentity, naming: TableNaming) -> TabTitle {
    match identity {
        TabIdentity::Table(table) => table_title(table, naming),
        TabIdentity::Structure(StructureTarget::Existing(table)) => {
            let structure = |name: &str| crate::i18n::gettext_f("{table} · Structure", &[("table", name)]);
            let base = table_title(table, naming);
            TabTitle {
                label: structure(&base.label),
                tooltip: base.tooltip.as_deref().map(structure),
            }
        }
        TabIdentity::Structure(StructureTarget::NewDraft { .. }) => TabTitle {
            label: crate::i18n::gettext("New Table"),
            tooltip: None,
        },
        TabIdentity::Editor(EditorLabel::Untitled(ordinal)) => TabTitle {
            label: numbered_query(*ordinal),
            tooltip: None,
        },
        TabIdentity::Editor(EditorLabel::File { name, location }) => TabTitle {
            label: name.clone(),
            tooltip: Some(location.clone()),
        },
        TabIdentity::Editor(EditorLabel::Query { prefix, truncated }) => {
            let label = derive_tab_label(prefix);
            let text = prefix.trim();
            let tooltip = match truncated {
                true => format!("{}…", prefix.trim_start()),
                false => text.to_owned(),
            };
            let tooltip = (!text.is_empty() && tooltip != label).then_some(tooltip);
            TabTitle { label, tooltip }
        }
    }
}

pub(crate) fn numbered_query(ordinal: usize) -> String {
    crate::i18n::gettext_f("Query {n}", &[("n", &ordinal.to_string())])
}

/// `schema.table` when the naming asks for it; a bare name has the
/// qualified one as its tooltip.
fn table_title(table: &TableRef, naming: TableNaming) -> TabTitle {
    let qualified = table.schema.as_ref().map(|schema| format!("{schema}.{}", table.name));
    match (naming, qualified) {
        (TableNaming::SchemaQualified, Some(qualified)) => TabTitle {
            label: qualified,
            tooltip: None,
        },
        (_, qualified) => TabTitle {
            label: table.name.clone(),
            tooltip: qualified,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn orders() -> TableRef {
        TableRef::new(Some("public".to_owned()), "orders")
    }

    #[test]
    fn a_table_is_named_bare_with_its_schema_in_the_tooltip() {
        let title = resolve_tab_title(&TabIdentity::Table(orders()), TableNaming::Bare);

        assert_eq!(title.label, "orders");
        assert_eq!(title.tooltip.as_deref(), Some("public.orders"));
        assert_eq!(
            resolve_tab_title(
                &TabIdentity::Table(TableRef::unqualified("t")),
                TableNaming::SchemaQualified
            ),
            TabTitle {
                label: "t".to_owned(),
                tooltip: None,
            }
        );
    }

    #[test]
    fn structure_title_keeps_suffix_regardless_of_dirty_state() {
        let identity = TabIdentity::Structure(StructureTarget::Existing(orders()));

        let title = resolve_tab_title(&identity, TableNaming::Bare);

        assert_eq!(title.label, "orders · Structure");
        assert_eq!(title.tooltip.as_deref(), Some("public.orders · Structure"));
        assert!(!title.label.contains('•'));
    }

    #[test]
    fn structure_title_is_schema_qualified_with_multiple_schemas() {
        let identity = TabIdentity::Structure(StructureTarget::Existing(orders()));

        let title = resolve_tab_title(&identity, TableNaming::SchemaQualified);

        assert_eq!(title.label, "public.orders · Structure");
        assert_eq!(title.tooltip, None);
    }

    #[test]
    fn blank_table_name_resolves_to_new_table() {
        let identity = TabIdentity::Structure(StructureTarget::of(Some("public"), ""));

        assert_eq!(resolve_tab_title(&identity, TableNaming::Bare).label, "New Table");
    }

    #[test]
    fn blank_query_resolves_to_query_ordinal() {
        let identity = TabIdentity::Editor(EditorLabel::of(3, "  \n\t", false));

        let title = resolve_tab_title(&identity, TableNaming::Bare);

        assert_eq!(title.label, "Query 3");
        assert_eq!(title.tooltip, None);
    }

    #[test]
    fn a_query_is_named_from_its_start_with_the_rest_in_the_tooltip() {
        let long = format!("SELECT * FROM orders WHERE id = 1;\n{}", "-- x\n".repeat(50));
        let prefix: String = long.chars().take(200).collect();

        let title = resolve_tab_title(
            &TabIdentity::Editor(EditorLabel::of(1, &prefix, true)),
            TableNaming::Bare,
        );

        assert_eq!(title.label, derive_tab_label(&prefix));
        let tooltip = title.tooltip.expect("a tooltip");
        assert!(tooltip.starts_with("SELECT * FROM orders"), "{tooltip}");
        assert!(tooltip.ends_with('…'), "{tooltip}");
    }

    #[test]
    fn a_tab_saved_to_a_file_is_named_after_it() {
        let title = resolve_tab_title(
            &TabIdentity::Editor(EditorLabel::File {
                name: "daily.sql".to_owned(),
                location: "/home/ada/reports/daily.sql".to_owned(),
            }),
            TableNaming::Bare,
        );

        assert_eq!(title.label, "daily.sql");
        assert_eq!(title.tooltip.as_deref(), Some("/home/ada/reports/daily.sql"));
    }

    #[test]
    fn a_script_its_label_shows_whole_has_no_tooltip() {
        let title = resolve_tab_title(
            &TabIdentity::Editor(EditorLabel::of(1, "SELECT 1;", false)),
            TableNaming::Bare,
        );

        assert_eq!(title.label, "SELECT 1;");
        assert_eq!(title.tooltip, None);
    }
}
