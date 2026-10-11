use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::SavedQuery;
use uuid::Uuid;

pub struct SavedQueriesDialog {
    root: adw::Dialog,
    search: gtk::SearchEntry,
    listbox: gtk::ListBox,
    stack: gtk::Stack,
    status_page: adw::StatusPage,
    saved: Vec<SavedQuery>,
}

#[derive(Debug)]
pub enum SavedQueriesInput {
    SearchChanged,
    Open(Uuid),
    AskRename(Uuid),
    Rename(Uuid, String),
    AskDelete(Uuid),
    Delete(Uuid),
}

#[derive(Debug)]
pub enum SavedQueriesOutput {
    OpenInNewTab(String),
    Changed(Vec<SavedQuery>),
}

#[derive(Debug)]
pub enum SavedQueriesCmd {
    Loaded(Vec<SavedQuery>),
    Failed(String),
}

pub fn visible_saved_queries(saved: &[SavedQuery], needle: &str) -> Vec<SavedQuery> {
    tablepro_storage::rank_favorites(saved)
        .into_iter()
        .filter(|candidate| tablepro_storage::matches_filter(candidate, needle))
        .collect()
}

pub fn statement_preview(sql: &str) -> String {
    let line = sql
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    if line.chars().count() <= 80 {
        return line.to_string();
    }
    let head: String = line.chars().take(79).collect();
    format!("{head}…")
}

pub fn cleaned_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_string())
}

impl SavedQueriesDialog {
    pub fn dialog(&self) -> &adw::Dialog {
        &self.root
    }

    fn renamed(&self, id: Uuid, name: String) -> Option<SavedQuery> {
        let existing = self.saved.iter().find(|candidate| candidate.id == id)?;
        Some(SavedQuery {
            name,
            ..existing.clone()
        })
    }

    fn sql_of(&self, id: Uuid) -> Option<String> {
        self.saved
            .iter()
            .find(|candidate| candidate.id == id)
            .map(|found| found.sql.clone())
    }

    fn ask_rename(&self, id: Uuid, sender: &ComponentSender<Self>) {
        let Some(existing) = self.saved.iter().find(|candidate| candidate.id == id) else {
            return;
        };
        let dialog = adw::AlertDialog::new(Some(&crate::tr!("Rename saved query")), None);
        let entry = adw::EntryRow::builder().title(crate::tr!("Name")).build();
        entry.set_text(&existing.name);
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        list.append(&entry);
        dialog.set_extra_child(Some(&list));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("rename", &crate::tr!("Rename"));
        dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("rename"));
        dialog.set_close_response("cancel");
        let sender = sender.clone();
        dialog.connect_response(None, move |_, response| {
            if response != "rename" {
                return;
            }
            sender.input(SavedQueriesInput::Rename(id, entry.text().to_string()));
        });
        dialog.present(Some(&self.root));
    }

    fn ask_delete(&self, id: Uuid, sender: &ComponentSender<Self>) {
        let Some(existing) = self.saved.iter().find(|candidate| candidate.id == id) else {
            return;
        };
        let body = crate::tr!("\"{name}\" will be removed from your saved queries.").replace("{name}", &existing.name);
        let dialog = adw::AlertDialog::new(Some(&crate::tr!("Delete saved query?")), Some(&body));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("delete", &crate::tr!("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_close_response("cancel");
        let sender = sender.clone();
        dialog.connect_response(None, move |_, response| {
            if response == "delete" {
                sender.input(SavedQueriesInput::Delete(id));
            }
        });
        dialog.present(Some(&self.root));
    }

    fn render(&self, sender: &ComponentSender<Self>) {
        while let Some(child) = self.listbox.first_child() {
            self.listbox.remove(&child);
        }
        let needle = self.search.text().to_string();
        let visible = visible_saved_queries(&self.saved, &needle);
        if visible.is_empty() {
            self.show_empty(!needle.trim().is_empty());
            return;
        }
        self.stack.set_visible_child_name("list");
        for saved in visible {
            self.listbox.append(&build_row(&saved, sender));
        }
    }

    fn show_empty(&self, searching: bool) {
        self.stack.set_visible_child_name("empty");
        if searching {
            self.status_page.set_title(&crate::tr!("No matches"));
            self.status_page
                .set_description(Some(&crate::tr!("Try a different search term.")));
            return;
        }
        self.status_page.set_title(&crate::tr!("No saved queries yet"));
        self.status_page.set_description(Some(&crate::tr!(
            "Press Ctrl+D in the SQL editor to save the query you are writing."
        )));
    }

    fn reload(&self, sender: &ComponentSender<Self>) {
        sender.oneshot_command(async move {
            match tablepro_storage::load_favorites().await {
                Ok(saved) => SavedQueriesCmd::Loaded(saved),
                Err(error) => SavedQueriesCmd::Failed(error.to_string()),
            }
        });
    }

    fn persist_rename(&self, favorite: SavedQuery, sender: &ComponentSender<Self>) {
        sender.oneshot_command(async move {
            match tablepro_storage::save_favorite(favorite).await {
                Ok(saved) => SavedQueriesCmd::Loaded(saved),
                Err(error) => SavedQueriesCmd::Failed(error.to_string()),
            }
        });
    }

    fn persist_delete(&self, id: Uuid, sender: &ComponentSender<Self>) {
        sender.oneshot_command(async move {
            match tablepro_storage::delete_favorite(id).await {
                Ok(saved) => SavedQueriesCmd::Loaded(saved),
                Err(error) => SavedQueriesCmd::Failed(error.to_string()),
            }
        });
    }
}

fn build_row(saved: &SavedQuery, sender: &ComponentSender<SavedQueriesDialog>) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(glib_escaped(&saved.name))
        .subtitle(glib_escaped(&statement_preview(&saved.sql)))
        .activatable(true)
        .build();
    row.add_suffix(&row_button(
        "document-edit-symbolic",
        &crate::tr!("Rename"),
        SavedQueriesInput::AskRename(saved.id),
        sender,
    ));
    let delete = row_button(
        "user-trash-symbolic",
        &crate::tr!("Delete"),
        SavedQueriesInput::AskDelete(saved.id),
        sender,
    );
    delete.add_css_class("destructive-action");
    row.add_suffix(&delete);
    let activate_sender = sender.clone();
    let id = saved.id;
    row.connect_activated(move |_| activate_sender.input(SavedQueriesInput::Open(id)));
    row
}

fn row_button(
    icon: &str,
    tooltip: &str,
    message: SavedQueriesInput,
    sender: &ComponentSender<SavedQueriesDialog>,
) -> gtk::Button {
    let button = gtk::Button::builder()
        .icon_name(icon)
        .tooltip_text(tooltip)
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    let sender = sender.clone();
    let message = std::cell::RefCell::new(Some(message));
    button.connect_clicked(move |_| {
        if let Some(message) = message.borrow_mut().take() {
            sender.input(message);
        }
    });
    button
}

fn glib_escaped(text: &str) -> String {
    gtk::glib::markup_escape_text(text).to_string()
}

impl Component for SavedQueriesDialog {
    type Init = Vec<SavedQuery>;
    type Input = SavedQueriesInput;
    type Output = SavedQueriesOutput;
    type CommandOutput = SavedQueriesCmd;
    type Root = adw::Dialog;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::Dialog::builder()
            .title(crate::tr!("Saved Queries"))
            .content_width(620)
            .content_height(600)
            .build()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::builder().show_end_title_buttons(true).build();
        toolbar.add_top_bar(&header);

        let search = gtk::SearchEntry::builder()
            .placeholder_text(crate::tr!("Search saved queries"))
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        let search_sender = sender.clone();
        search.connect_search_changed(move |_| search_sender.input(SavedQueriesInput::SearchChanged));

        let listbox = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        let group = adw::PreferencesGroup::builder()
            .margin_top(6)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .build();
        group.add(&listbox);

        let status_page = adw::StatusPage::builder().icon_name("starred-symbolic").build();
        let stack = gtk::Stack::new();
        let scrolled = gtk::ScrolledWindow::builder().vexpand(true).child(&group).build();
        stack.add_named(&scrolled, Some("list"));
        stack.add_named(&status_page, Some("empty"));

        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&search);
        content.append(&stack);
        toolbar.set_content(Some(&content));
        root.set_child(Some(&toolbar));

        let model = SavedQueriesDialog {
            root,
            search,
            listbox,
            stack,
            status_page,
            saved: init,
        };
        model.render(&sender);
        model.reload(&sender);
        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            SavedQueriesInput::SearchChanged => self.render(&sender),
            SavedQueriesInput::Open(id) => {
                let Some(sql) = self.sql_of(id) else {
                    return;
                };
                sender.output(SavedQueriesOutput::OpenInNewTab(sql)).ok();
                self.root.close();
            }
            SavedQueriesInput::AskRename(id) => self.ask_rename(id, &sender),
            SavedQueriesInput::Rename(id, name) => {
                let Some(name) = cleaned_name(&name) else {
                    return;
                };
                let Some(renamed) = self.renamed(id, name) else {
                    return;
                };
                self.persist_rename(renamed, &sender);
            }
            SavedQueriesInput::AskDelete(id) => self.ask_delete(id, &sender),
            SavedQueriesInput::Delete(id) => self.persist_delete(id, &sender),
        }
    }

    fn update_cmd(&mut self, message: Self::CommandOutput, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            SavedQueriesCmd::Loaded(saved) => {
                self.saved = saved.clone();
                self.render(&sender);
                sender.output(SavedQueriesOutput::Changed(saved)).ok();
            }
            SavedQueriesCmd::Failed(error) => {
                tracing::warn!(error = %error, "saved queries update failed");
                self.status_page.set_title(&crate::tr!("Saved queries are unavailable"));
                self.stack.set_visible_child_name("empty");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn saved(name: &str, sql: &str) -> SavedQuery {
        SavedQuery::new(name.into(), sql.into(), None, None)
    }

    #[test]
    fn an_empty_search_lists_every_saved_query_in_rank_order() {
        let mut recent = saved("zeta", "SELECT 1");
        recent.last_used_at = Some(chrono::Utc::now());
        let older = saved("alpha", "SELECT 2");

        let visible = visible_saved_queries(&[older, recent], "  ");

        assert_eq!(visible.len(), 2);
        assert_eq!(visible[0].name, "zeta");
    }

    #[test]
    fn a_search_matches_the_name_or_the_statement() {
        let list = vec![saved("people", "SELECT 1"), saved("orders", "SELECT * FROM invoices")];

        assert_eq!(visible_saved_queries(&list, "PEOPLE").len(), 1);
        assert_eq!(visible_saved_queries(&list, "invoices")[0].name, "orders");
        assert!(visible_saved_queries(&list, "nothing here").is_empty());
    }

    #[test]
    fn the_preview_is_the_first_non_empty_line() {
        assert_eq!(statement_preview("\n\n  SELECT 1\nFROM t"), "SELECT 1");
        assert_eq!(statement_preview("   "), "");
    }

    #[test]
    fn a_long_preview_is_shortened_on_a_character_boundary() {
        let preview = statement_preview(&"é".repeat(200));

        assert_eq!(preview.chars().count(), 80);
        assert!(preview.ends_with('…'));
    }

    #[test]
    fn a_blank_rename_is_rejected() {
        assert_eq!(cleaned_name("  "), None);
        assert_eq!(cleaned_name("  daily report "), Some("daily report".to_string()));
    }
}
