use relm4::ComponentSender;
use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_storage::SavedQuery;
use uuid::Uuid;

use crate::services::quick_switcher::{QuickItem, QuickTarget, favorite_items, relation_items};

use super::types::{WorkspaceTab, read_workspace_tab_id};
use super::{App, AppMsg};

impl App {
    pub(super) fn load_favorites(&self, sender: ComponentSender<Self>) {
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match tablepro_storage::load_favorites().await {
                        Ok(favorites) => sender_clone.input(AppMsg::FavoritesLoaded(favorites)),
                        Err(error) => tracing::warn!(error = %error, "load favorites failed"),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_favorites_loaded(&mut self, favorites: Vec<SavedQuery>) {
        self.favorites = favorites;
    }

    pub(super) fn on_save_query_as_favorite(&self, sender: ComponentSender<Self>) {
        let Some(query) = self.selected_editor_query() else {
            self.show_toast(&crate::tr!("Open a SQL editor tab to save a favorite."));
            return;
        };
        if query.trim().is_empty() {
            self.show_toast(&crate::tr!("The editor is empty."));
            return;
        }

        let dialog = adw::AlertDialog::new(Some(&crate::tr!("Save as favorite")), None);
        let entry = adw::EntryRow::builder().title(crate::tr!("Name")).build();
        entry.set_text(&crate::ui::editor::derive_tab_label(&query));
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        list.append(&entry);
        dialog.set_extra_child(Some(&list));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("save", &crate::tr!("Save"));
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");

        let driver_id = self.current_driver_id.clone();
        let connection_id = self.connection_id;
        let sender_for_response = sender.clone();
        dialog.connect_response(None, move |_, response| {
            if response != "save" {
                return;
            }
            let favorite = SavedQuery::new(
                entry.text().to_string(),
                query.clone(),
                driver_id.clone(),
                connection_id,
            );
            sender_for_response.input(AppMsg::PersistFavorite(favorite));
        });
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_persist_favorite(&self, favorite: SavedQuery, sender: ComponentSender<Self>) {
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match tablepro_storage::save_favorite(favorite).await {
                        Ok(favorites) => {
                            sender_clone.input(AppMsg::FavoritesLoaded(favorites));
                            sender_clone.input(AppMsg::FavoriteSaved);
                        }
                        Err(error) => sender_clone.input(AppMsg::FavoriteSaveFailed(error.to_string())),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_show_quick_switcher(&self, sender: ComponentSender<Self>) {
        let mut items = favorite_items(&self.favorites);
        items.extend(self.open_tab_items());
        items.extend(relation_items(&self.sidebar_tables, &self.sidebar_views));
        items.extend(self.connection_items());
        items.extend(crate::services::quick_switcher::command_items());
        let sender_for_choice = sender.clone();
        crate::ui::quick_switcher_dialog::present(&self.window, items, move |target| {
            sender_for_choice.input(AppMsg::QuickSwitcherChose(target));
        });
    }

    pub(super) fn on_quick_switcher_chose(&mut self, target: QuickTarget, sender: ComponentSender<Self>) {
        match target {
            QuickTarget::Favorite(id) => {
                let Some(favorite) = self.favorites.iter().find(|favorite| favorite.id == id).cloned() else {
                    return;
                };
                self.append_editor_tab(Some(favorite.sql), sender.clone());
                sender.command(move |_, shutdown| {
                    shutdown
                        .register(async move {
                            if let Err(error) = tablepro_storage::touch_favorite(id).await {
                                tracing::warn!(error = %error, "touch favorite failed");
                            }
                        })
                        .drop_on_shutdown()
                });
            }
            QuickTarget::Tab(id) => self.select_workspace_tab(id),
            QuickTarget::Relation { schema, name } => sender.input(AppMsg::SelectTable {
                schema,
                name,
                open_mode: super::OpenMode::SwitchOrAppend,
            }),
            QuickTarget::Command(action) => {
                let _ = gtk::prelude::WidgetExt::activate_action(&self.window, &format!("win.{action}"), None);
            }
            QuickTarget::Connection(id) => {
                let Some(saved) = self
                    .saved_connections
                    .iter()
                    .find(|connection| connection.id == id)
                    .cloned()
                else {
                    return;
                };
                sender.input(AppMsg::OpenSaved(saved));
            }
        }
    }

    fn selected_editor_query(&self) -> Option<String> {
        let page = self.workspace_tab_view.as_ref()?.selected_page()?;
        let id = read_workspace_tab_id(&page)?;
        let tabs = self.workspace_tabs.borrow();
        match tabs.get(&id)? {
            WorkspaceTab::Editor(slot) => Some(slot.query.clone()),
            _ => None,
        }
    }

    fn open_tab_items(&self) -> Vec<QuickItem> {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            return Vec::new();
        };
        let pages = tab_view.pages();
        let tabs = self.workspace_tabs.borrow();
        let mut items = Vec::new();
        for position in 0..pages.n_items() {
            let Some(page) = pages.item(position).and_downcast::<adw::TabPage>() else {
                continue;
            };
            let Some(id) = read_workspace_tab_id(&page) else {
                continue;
            };
            if !tabs.contains_key(&id) {
                continue;
            }
            items.push(QuickItem {
                target: QuickTarget::Tab(id),
                title: page.title().to_string(),
                subtitle: crate::tr!("Open tab"),
            });
        }
        items
    }

    fn connection_items(&self) -> Vec<QuickItem> {
        self.saved_connections
            .iter()
            .map(|connection| QuickItem {
                target: QuickTarget::Connection(connection.id),
                title: connection.name.clone(),
                subtitle: crate::tr!("Saved connection"),
            })
            .collect()
    }

    fn select_workspace_tab(&self, id: Uuid) {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            return;
        };
        let pages = tab_view.pages();
        for position in 0..pages.n_items() {
            let Some(page) = pages.item(position).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) == Some(id) {
                tab_view.set_selected_page(&page);
                return;
            }
        }
    }
}
