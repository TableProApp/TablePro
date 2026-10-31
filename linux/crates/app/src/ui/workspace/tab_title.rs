use std::cell::Cell;
use std::rc::Rc;

use gtk4::glib;
use libadwaita as adw;
use tablepro_core::meta::TableRef;
use tablepro_session::SessionKey;

use super::editor_label::EditorLabel;
use super::structure_target::StructureTarget;
use super::tab_identity::TabIdentity;
use super::table_naming::TableNaming;
use crate::services::active_session::ActiveSession;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::editor::derive_tab_label;

/// A tab's title and the tooltip that says more than it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TabTitle {
    pub label: String,
    pub tooltip: Option<String>,
}

/// The connection a session's tabs belong to, as the saved connections
/// name it now, so a renamed connection retitles its tabs. A file opened
/// without a saved connection keeps the name it connected with.
pub(crate) struct ConnectionLabel {
    key: SessionKey,
    saved: Rc<SavedConnectionList>,
    session: ActiveSession,
    /// Another session has a tab in the bar beside this one's.
    shares_bar: Cell<bool>,
}

impl ConnectionLabel {
    pub(crate) fn new(key: SessionKey, saved: Rc<SavedConnectionList>, session: ActiveSession) -> Self {
        Self {
            key,
            saved,
            session,
            shares_bar: Cell::new(false),
        }
    }

    pub(crate) fn key(&self) -> &SessionKey {
        &self.key
    }

    pub(crate) fn name(&self) -> String {
        let saved = match &self.key {
            SessionKey::Saved(id) => self.saved.get(*id).map(|saved| saved.name),
            SessionKey::SavedIn { id, database } => self.saved.get(*id).map(|saved| {
                // Translators: a connection and another of its server's databases, open beside it.
                crate::i18n::gettext_f(
                    "{connection} · {database}",
                    &[("connection", &saved.name), ("database", database)],
                )
            }),
            SessionKey::File(_) => None,
        };
        saved
            .or_else(|| self.session.metadata().map(|metadata| metadata.name))
            .unwrap_or_default()
    }

    pub(crate) fn shares_bar(&self) -> bool {
        self.shares_bar.get()
    }

    /// What a tab names after its title: the connection while the bar is
    /// shared, and the tab's database when it moved off the connection's.
    fn suffix(&self, moved_to: Option<&str>) -> Option<String> {
        let connection = self.shares_bar().then(|| self.name());
        suffix(connection, moved_to)
    }

    /// True when that changed, and the tabs have to be titled again.
    pub(crate) fn set_shares_bar(&self, shares: bool) -> bool {
        self.shares_bar.replace(shares) != shares
    }
}

/// Give `page` its title, tooltip and keyword. libadwaita treats an
/// empty tooltip as none, which clears the last one. The tooltip says
/// what the unsaved icon shows, since a screen reader reads a tab's
/// tooltip and not its icon, and it is escaped: AdwTab shows it as Pango
/// markup.
pub(crate) fn apply_tab_title(
    page: &adw::TabPage,
    title: &TabTitle,
    connection: &ConnectionLabel,
    moved_to: Option<&str>,
) {
    // The overview's search finds a connection's tabs by its name.
    page.set_keyword(&connection.name());
    let title = match connection.suffix(moved_to) {
        Some(suffix) => name_place(title.clone(), &suffix),
        None => title.clone(),
    };
    page.set_title(&title.label);
    let unsaved = page.icon().is_some().then(|| crate::i18n::gettext("Unsaved changes"));
    let lines: Vec<&str> = [title.tooltip.as_deref(), unsaved.as_deref()]
        .into_iter()
        .flatten()
        .collect();
    page.set_tooltip(&glib::markup_escape_text(&lines.join("\n")));
}

/// The connection, the database, or both, as "prod, analytics".
fn suffix(connection: Option<String>, database: Option<&str>) -> Option<String> {
    match (connection, database) {
        // Translators: a connection and one of its databases, after a tab's title.
        (Some(connection), Some(database)) => Some(crate::i18n::gettext_f(
            "{connection}, {database}",
            &[("connection", &connection), ("database", database)],
        )),
        (connection, database) => connection.or_else(|| database.map(str::to_owned)),
    }
}

/// A tab beside another connection's names its own after its title, and
/// a tab in another database names that, since the title stays the
/// useful part once ellipsized. The tooltip names them on a line of its
/// own, which a cut label loses.
fn name_place(title: TabTitle, place: &str) -> TabTitle {
    let tooltip = [title.tooltip.as_deref().unwrap_or(&title.label), place].join("\n");
    TabTitle {
        // Translators: a tab's title and its connection while several connections share the tab bar, or the database it runs in when not the connection's.
        label: crate::i18n::gettext_f(
            "{title} ({connection})",
            &[("title", &title.label), ("connection", place)],
        ),
        tooltip: Some(tooltip),
    }
}

/// The one place a tab's title is made. Unsaved changes never change it;
/// the page's icon says so.
pub(crate) fn resolve_tab_title(identity: &TabIdentity, naming: TableNaming) -> TabTitle {
    match identity {
        TabIdentity::Table(table) => table_title(table, naming),
        TabIdentity::Key(key) => TabTitle {
            label: key.clone(),
            tooltip: None,
        },
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
        TabIdentity::Diagram(schema) => TabTitle {
            label: match schema {
                Some(schema) => crate::i18n::gettext_f("{schema} · ER Diagram", &[("schema", schema)]),
                None => crate::i18n::gettext("ER Diagram"),
            },
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
    fn a_diagram_is_named_for_its_schema() {
        let public = resolve_tab_title(&TabIdentity::Diagram(Some("public".to_owned())), TableNaming::Bare);
        let unnamed = resolve_tab_title(&TabIdentity::Diagram(None), TableNaming::SchemaQualified);

        assert_eq!(public.label, "public · ER Diagram");
        assert_eq!(unnamed.label, "ER Diagram");
        assert_eq!(public.tooltip, None);
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
    fn a_tab_beside_another_connections_names_its_own_after_its_title() {
        let title = name_place(
            resolve_tab_title(&TabIdentity::Table(orders()), TableNaming::Bare),
            "Shop",
        );

        assert_eq!(title.label, "orders (Shop)");
        assert_eq!(title.tooltip.as_deref(), Some("public.orders\nShop"));
        assert!(!title.label.contains('·'));
    }

    #[test]
    fn a_tab_names_its_database_and_the_connection_it_shares_the_bar_with() {
        assert_eq!(suffix(None, Some("analytics")).as_deref(), Some("analytics"));
        assert_eq!(
            suffix(Some("Shop".to_owned()), Some("analytics")).as_deref(),
            Some("Shop, analytics")
        );
        assert_eq!(suffix(Some("Shop".to_owned()), None).as_deref(), Some("Shop"));
        assert_eq!(suffix(None, None), None);
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
