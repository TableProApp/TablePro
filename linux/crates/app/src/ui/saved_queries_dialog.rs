use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::SavedQueries;
use tablepro_storage::saved_queries::SavedQuery;
use uuid::Uuid;

/// The user's named queries, grouped by the connection each was saved
/// against.
///
/// The active connection comes first, because that is the one whose
/// tables the user is looking at. The rest stay listed rather than
/// hidden: a query saved against a connection is still worth reading
/// when connected elsewhere.
pub struct SavedQueriesDialog {
    store: Option<SavedQueries>,
    active_connection: Option<Uuid>,
    root: adw::Dialog,
    search: gtk::SearchEntry,
    groups: gtk::Box,
    stack: gtk::Stack,
    status_page: adw::StatusPage,
    queries: Vec<SavedQuery>,
}

pub struct SavedQueriesDialogInit {
    pub store: Option<SavedQueries>,
    pub active_connection: Option<Uuid>,
}

#[derive(Debug)]
pub enum SavedQueriesDialogInput {
    Refresh,
    SearchChanged,
    Activate(i64),
    ReplaceCurrent(i64),
    CopySql(i64),
    RenameRequested(i64),
    Rename(i64, String),
    DeleteRequested(i64),
    Delete(i64),
}

#[derive(Debug)]
pub enum SavedQueriesDialogOutput {
    OpenInNewTab(String),
    ReplaceCurrentTabQuery(String),
    CopyToClipboard(String),
    ShowToast(String),
}

#[derive(Debug)]
pub enum SavedQueriesDialogCmd {
    Loaded(Vec<SavedQuery>),
    Failed(String),
    Changed,
}

impl Component for SavedQueriesDialog {
    type Init = SavedQueriesDialogInit;
    type Input = SavedQueriesDialogInput;
    type Output = SavedQueriesDialogOutput;
    type CommandOutput = SavedQueriesDialogCmd;
    type Root = adw::Dialog;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::Dialog::builder()
            .title(crate::i18n::gettext("Saved Queries"))
            .content_width(560)
            .content_height(600)
            .build()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::builder().show_end_title_buttons(true).build();
        header.set_title_widget(Some(&adw::WindowTitle::new(&crate::i18n::gettext("Saved Queries"), "")));
        toolbar.add_top_bar(&header);

        let search = gtk::SearchEntry::builder()
            .placeholder_text(crate::i18n::gettext("Search saved queries"))
            .hexpand(true)
            .build();
        let search_bar = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .margin_start(12)
            .margin_end(12)
            .margin_top(6)
            .margin_bottom(6)
            .build();
        search_bar.append(&search);
        toolbar.add_top_bar(&search_bar);
        let sender_for_search = sender.clone();
        search.connect_search_changed(move |_| sender_for_search.input(SavedQueriesDialogInput::SearchChanged));

        let groups = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(18)
            .margin_start(12)
            .margin_end(12)
            .margin_top(12)
            .margin_bottom(12)
            .build();
        let scroller = gtk::ScrolledWindow::builder()
            .hexpand(true)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&groups)
            .build();

        let status_page = adw::StatusPage::builder()
            .icon_name(crate::ui::icons::DOCUMENT_OPEN_RECENT)
            .title(crate::i18n::gettext("No saved queries"))
            .description(crate::i18n::gettext(
                "Save a query from the editor and it will be listed here.",
            ))
            .build();

        let stack = gtk::Stack::new();
        stack.add_named(&scroller, Some("list"));
        stack.add_named(&status_page, Some("empty"));
        stack.set_visible_child_name("empty");
        toolbar.set_content(Some(&stack));
        root.set_child(Some(&toolbar));

        let model = SavedQueriesDialog {
            store: init.store,
            active_connection: init.active_connection,
            root: root.clone(),
            search,
            groups,
            stack,
            status_page,
            queries: Vec::new(),
        };
        sender.input(SavedQueriesDialogInput::Refresh);

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            SavedQueriesDialogInput::Refresh => self.load(&sender),
            SavedQueriesDialogInput::SearchChanged => self.render(&sender),
            SavedQueriesDialogInput::Activate(id) => {
                if let Some(query) = self.query_for(id) {
                    let _ = sender.output(SavedQueriesDialogOutput::OpenInNewTab(query));
                    self.root.close();
                }
            }
            SavedQueriesDialogInput::ReplaceCurrent(id) => {
                if let Some(query) = self.query_for(id) {
                    let _ = sender.output(SavedQueriesDialogOutput::ReplaceCurrentTabQuery(query));
                    self.root.close();
                }
            }
            SavedQueriesDialogInput::CopySql(id) => {
                if let Some(query) = self.query_for(id) {
                    let _ = sender.output(SavedQueriesDialogOutput::CopyToClipboard(query));
                }
            }
            SavedQueriesDialogInput::RenameRequested(id) => self.prompt_rename(id, &sender),
            SavedQueriesDialogInput::Rename(id, name) => {
                let Some(store) = self.store.clone() else { return };
                sender.oneshot_command(async move {
                    match store.rename(id, &name).await {
                        Ok(()) => SavedQueriesDialogCmd::Changed,
                        // The only rename that fails for a reason the
                        // user can act on is a name the connection
                        // already has.
                        Err(error) => {
                            tracing::warn!(%error, "could not rename the saved query");
                            SavedQueriesDialogCmd::Failed(crate::i18n::gettext(
                                "That name is already used by another saved query.",
                            ))
                        }
                    }
                });
            }
            SavedQueriesDialogInput::DeleteRequested(id) => self.confirm_delete(id, &sender),
            SavedQueriesDialogInput::Delete(id) => {
                let Some(store) = self.store.clone() else { return };
                sender.oneshot_command(async move {
                    match store.delete(id).await {
                        Ok(()) => SavedQueriesDialogCmd::Changed,
                        Err(error) => {
                            tracing::warn!(%error, "could not delete the saved query");
                            SavedQueriesDialogCmd::Failed(crate::i18n::gettext("Could not delete that saved query."))
                        }
                    }
                });
            }
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            SavedQueriesDialogCmd::Loaded(queries) => {
                self.queries = queries;
                self.render(&sender);
            }
            SavedQueriesDialogCmd::Changed => sender.input(SavedQueriesDialogInput::Refresh),
            SavedQueriesDialogCmd::Failed(message) => {
                let _ = sender.output(SavedQueriesDialogOutput::ShowToast(message));
                sender.input(SavedQueriesDialogInput::Refresh);
            }
        }
    }
}

impl SavedQueriesDialog {
    pub fn dialog(&self) -> &adw::Dialog {
        &self.root
    }

    fn load(&self, sender: &ComponentSender<Self>) {
        let Some(store) = self.store.clone() else {
            return;
        };
        sender.oneshot_command(async move {
            match store.list(None).await {
                Ok(queries) => SavedQueriesDialogCmd::Loaded(queries),
                Err(error) => {
                    tracing::warn!(%error, "could not read the saved queries");
                    SavedQueriesDialogCmd::Loaded(Vec::new())
                }
            }
        });
    }

    fn query_for(&self, id: i64) -> Option<String> {
        self.queries
            .iter()
            .find(|saved| saved.id == id)
            .map(|saved| saved.query.clone())
    }

    fn name_for(&self, id: i64) -> Option<String> {
        self.queries
            .iter()
            .find(|saved| saved.id == id)
            .map(|saved| saved.name.clone())
    }

    fn render(&self, sender: &ComponentSender<Self>) {
        while let Some(child) = self.groups.first_child() {
            self.groups.remove(&child);
        }

        let groups = grouped(&self.queries, &self.search.text(), self.active_connection);
        if groups.is_empty() {
            let searching = !self.search.text().to_string().trim().is_empty();
            if searching {
                self.status_page.set_title(&crate::i18n::gettext("No matches"));
                self.status_page
                    .set_description(Some(&crate::i18n::gettext("Try a different search term.")));
                self.status_page.set_icon_name(Some(crate::ui::icons::SYSTEM_SEARCH));
            } else {
                self.status_page.set_title(&crate::i18n::gettext("No saved queries"));
                self.status_page.set_description(Some(&crate::i18n::gettext(
                    "Save a query from the editor and it will be listed here.",
                )));
                self.status_page
                    .set_icon_name(Some(crate::ui::icons::DOCUMENT_OPEN_RECENT));
            }
            self.stack.set_visible_child_name("empty");
            return;
        }
        self.stack.set_visible_child_name("list");

        for (connection_name, rows) in groups {
            let group = adw::PreferencesGroup::builder().title(&connection_name).build();
            for saved in rows {
                group.add(&self.build_row(saved, sender.clone()));
            }
            self.groups.append(&group);
        }
    }

    fn build_row(&self, saved: &SavedQuery, sender: ComponentSender<Self>) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&saved.name))
            .subtitle(glib::markup_escape_text(saved.summary()))
            .activatable(true)
            .build();
        row.set_subtitle_lines(1);

        let id = saved.id;
        let sender_for_activate = sender.clone();
        row.connect_activated(move |_| sender_for_activate.input(SavedQueriesDialogInput::Activate(id)));

        let menu = gio::Menu::new();
        let open_section = gio::Menu::new();
        open_section.append(Some(&crate::i18n::gettext("Open in New Tab")), Some("saved.open"));
        open_section.append(
            Some(&crate::i18n::gettext("Replace Current Tab")),
            Some("saved.replace"),
        );
        open_section.append(Some(&crate::i18n::gettext("Copy SQL")), Some("saved.copy"));
        menu.append_section(None, &open_section);
        let edit_section = gio::Menu::new();
        edit_section.append(Some(&crate::i18n::gettext("Rename…")), Some("saved.rename"));
        menu.append_section(None, &edit_section);
        let danger_section = gio::Menu::new();
        danger_section.append(Some(&crate::i18n::gettext("Delete")), Some("saved.delete"));
        menu.append_section(None, &danger_section);

        let actions = gio::SimpleActionGroup::new();
        let entry = |name: &str, message: fn(i64) -> SavedQueriesDialogInput, sender: ComponentSender<Self>| {
            gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
                .activate(move |_, _, _| sender.input(message(id)))
                .build()
        };
        actions.add_action_entries([
            entry("open", SavedQueriesDialogInput::Activate, sender.clone()),
            entry("replace", SavedQueriesDialogInput::ReplaceCurrent, sender.clone()),
            entry("copy", SavedQueriesDialogInput::CopySql, sender.clone()),
            entry("rename", SavedQueriesDialogInput::RenameRequested, sender.clone()),
            entry("delete", SavedQueriesDialogInput::DeleteRequested, sender),
        ]);

        let button = gtk::MenuButton::builder()
            .icon_name(crate::ui::icons::VIEW_MORE)
            .valign(gtk::Align::Center)
            .tooltip_text(crate::i18n::gettext("Saved query options"))
            .menu_model(&menu)
            .build();
        button.add_css_class("flat");
        button.insert_action_group("saved", Some(&actions));
        row.add_suffix(&button);

        row
    }

    fn prompt_rename(&self, id: i64, sender: &ComponentSender<Self>) {
        let Some(current) = self.name_for(id) else {
            return;
        };
        let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Rename Saved Query")), None);
        let entry = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
        entry.set_text(&current);
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("rename", &crate::i18n::gettext("Rename"));
        dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("rename"));
        dialog.set_close_response("cancel");

        let sender = sender.clone();
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "rename" {
                return;
            }
            let name = entry.text().to_string();
            if name.trim().is_empty() {
                return;
            }
            sender.input(SavedQueriesDialogInput::Rename(id, name));
        });
        dialog.present(Some(&self.root));
    }

    fn confirm_delete(&self, id: i64, sender: &ComponentSender<Self>) {
        let Some(name) = self.name_for(id) else {
            return;
        };
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext_f("Delete “{name}”?", &[("name", &name)])),
            Some(&crate::i18n::gettext(
                "The saved query is removed. The SQL itself is not run or changed.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("delete", &crate::i18n::gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let sender = sender.clone();
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response == "delete" {
                sender.input(SavedQueriesDialogInput::Delete(id));
            }
        });
        dialog.present(Some(&self.root));
    }
}

/// Everything matching the search, grouped by connection, with the
/// active connection's group first and the rest in the order the store
/// returned them.
fn grouped<'a>(queries: &'a [SavedQuery], needle: &str, active: Option<Uuid>) -> Vec<(String, Vec<&'a SavedQuery>)> {
    let needle = needle.to_lowercase();
    let mut groups: Vec<(String, Vec<&SavedQuery>)> = Vec::new();
    for saved in queries.iter().filter(|saved| matches(saved, &needle)) {
        match groups.iter_mut().find(|(_, rows)| {
            rows.first()
                .is_some_and(|first| first.connection_id == saved.connection_id)
        }) {
            Some((_, rows)) => rows.push(saved),
            None => groups.push((saved.connection_name.clone(), vec![saved])),
        }
    }
    if let Some(active) = active {
        // A stable sort, so everything but the active connection keeps
        // the order the store gave it.
        groups.sort_by_key(|(_, rows)| !rows.first().is_some_and(|first| first.connection_id == active));
    }
    groups
}

/// A saved query matches when the needle is in its name, its SQL or the
/// connection it was saved against, so searching for the connection
/// narrows to it without a filter control.
fn matches(saved: &SavedQuery, needle: &str) -> bool {
    if needle.trim().is_empty() {
        return true;
    }
    let needle = needle.trim();
    saved.name.to_lowercase().contains(needle)
        || saved.query.to_lowercase().contains(needle)
        || saved.connection_name.to_lowercase().contains(needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;

    fn saved(name: &str, query: &str, connection: &str) -> SavedQuery {
        on_connection(name, query, connection, Uuid::nil())
    }

    fn on_connection(name: &str, query: &str, connection: &str, connection_id: Uuid) -> SavedQuery {
        SavedQuery {
            id: 1,
            name: name.to_owned(),
            query: query.to_owned(),
            connection_id,
            connection_name: connection.to_owned(),
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    fn group_names(groups: &[(String, Vec<&SavedQuery>)]) -> Vec<String> {
        groups.iter().map(|(name, _)| name.clone()).collect()
    }

    #[test]
    fn queries_are_grouped_by_the_connection_they_were_saved_against() {
        let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", local),
            on_connection("b", "SELECT 2", "staging", staging),
            on_connection("c", "SELECT 3", "local", local),
        ];

        let groups = grouped(&queries, "", None);

        assert_eq!(group_names(&groups), vec!["local", "staging"]);
        assert_eq!(groups[0].1.len(), 2);
        assert_eq!(groups[1].1.len(), 1);
    }

    #[test]
    fn the_connection_the_user_is_on_is_listed_first() {
        let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", local),
            on_connection("b", "SELECT 2", "staging", staging),
        ];

        let groups = grouped(&queries, "", Some(staging));

        assert_eq!(group_names(&groups), vec!["staging", "local"]);
    }

    #[test]
    fn two_connections_sharing_a_name_stay_apart() {
        // Duplicating a connection and renaming neither is enough for
        // this: the id is what says they are different.
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", first),
            on_connection("b", "SELECT 2", "local", second),
        ];

        let groups = grouped(&queries, "", None);

        assert_eq!(groups.len(), 2);
    }

    #[test]
    fn a_search_that_matches_nothing_leaves_no_groups() {
        let queries = vec![saved("daily", "SELECT 1", "local")];

        assert!(grouped(&queries, "invoices", None).is_empty());
    }

    #[test]
    fn an_empty_search_matches_everything() {
        assert!(matches(&saved("daily", "SELECT 1", "local"), ""));
        assert!(matches(&saved("daily", "SELECT 1", "local"), "   "));
    }

    #[test]
    fn a_search_reads_the_name_the_sql_and_the_connection() {
        let query = saved("daily report", "SELECT * FROM orders", "staging");

        assert!(matches(&query, "report"));
        assert!(matches(&query, "orders"));
        assert!(matches(&query, "staging"));
        assert!(!matches(&query, "invoices"));
    }

    #[test]
    fn a_search_ignores_case_and_surrounding_space() {
        assert!(matches(&saved("Daily", "SELECT 1", "local"), "  daily  "));
    }
}

#[cfg(test)]
mod dialog_tests {
    use super::*;
    use std::time::Duration;

    use tablepro_storage::QueryHistory;
    use tablepro_storage::saved_queries::NewSavedQuery;

    const RENDER_WAIT: Duration = Duration::from_secs(5);

    /// A store on a temporary database, seeded with one query per
    /// connection. The directory is returned so it outlives the store.
    fn seeded() -> (tempfile::TempDir, SavedQueries, Uuid, Uuid) {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = tablepro_storage::StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
        let store = relm4::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(async {
                let store = QueryHistory::open(&paths).await.expect("open").saved_queries();
                for (name, sql, id, connection) in [
                    ("daily orders", "SELECT * FROM orders", local, "local"),
                    ("stale carts", "SELECT * FROM carts", staging, "staging"),
                ] {
                    store
                        .save(NewSavedQuery {
                            name: name.to_owned(),
                            query: sql.to_owned(),
                            connection_id: id,
                            connection_name: connection.to_owned(),
                        })
                        .await
                        .expect("save");
                }
                store
            });
        (root, store, local, staging)
    }

    fn row_titles(dialog: &SavedQueriesDialog) -> Vec<String> {
        crate::test_support::descendants(&dialog.groups)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
            .map(|row| row.title().to_string())
            .collect()
    }

    #[gtk4::test]
    fn the_saved_queries_reach_the_list() {
        let (_root, store, local, _staging) = seeded();
        let dialog = SavedQueriesDialog::builder().launch(SavedQueriesDialogInit {
            store: Some(store),
            active_connection: Some(local),
        });

        crate::test_support::wait_until(RENDER_WAIT, || !row_titles(&dialog.model()).is_empty())
            .expect("the saved queries never rendered");

        // The active connection's query comes first, whatever order the
        // store returned them in.
        assert_eq!(row_titles(&dialog.model()), vec!["daily orders", "stale carts"]);
    }

    #[gtk4::test]
    fn searching_narrows_the_list_to_what_matches() {
        let (_root, store, local, _staging) = seeded();
        let dialog = SavedQueriesDialog::builder().launch(SavedQueriesDialogInit {
            store: Some(store),
            active_connection: Some(local),
        });
        crate::test_support::wait_until(RENDER_WAIT, || row_titles(&dialog.model()).len() == 2)
            .expect("the saved queries never rendered");

        dialog.model().search.set_text("carts");

        crate::test_support::wait_until(RENDER_WAIT, || row_titles(&dialog.model()) == vec!["stale carts"])
            .expect("the search did not narrow the list");
    }

    #[gtk4::test]
    fn deleting_a_query_takes_it_out_of_the_list() {
        let (_root, store, local, _staging) = seeded();
        let dialog = SavedQueriesDialog::builder().launch(SavedQueriesDialogInit {
            store: Some(store),
            active_connection: Some(local),
        });
        crate::test_support::wait_until(RENDER_WAIT, || row_titles(&dialog.model()).len() == 2)
            .expect("the saved queries never rendered");
        let id = dialog
            .model()
            .queries
            .iter()
            .find(|saved| saved.name == "daily orders")
            .expect("the seeded query")
            .id;

        dialog.sender().send(SavedQueriesDialogInput::Delete(id)).expect("send");

        crate::test_support::wait_until(RENDER_WAIT, || row_titles(&dialog.model()) == vec!["stale carts"])
            .expect("the deleted query stayed in the list");
    }

    #[gtk4::test]
    fn a_dialog_with_no_database_shows_the_empty_state_rather_than_failing() {
        let dialog = SavedQueriesDialog::builder().launch(SavedQueriesDialogInit {
            store: None,
            active_connection: None,
        });

        crate::test_support::drain_main_context();

        assert_eq!(dialog.model().stack.visible_child_name().as_deref(), Some("empty"));
        assert!(row_titles(&dialog.model()).is_empty());
    }
}
