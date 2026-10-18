use relm4::ComponentSender;
use relm4::gtk::gio;
use uuid::Uuid;

use super::types::{PreviewReplacement, opens_as_preview, preview_replacement, read_workspace_tab_id};
use super::{App, OpenMode, WorkspaceTab};

impl App {
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        let switch_or_append = matches!(open_mode, OpenMode::SwitchOrAppend);
        let is_preview = opens_as_preview(switch_or_append, self.preferences.load().open_tables_in_preview_tab);
        if switch_or_append {
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
                let matches_slot = |tab: &WorkspaceTab| match tab {
                    WorkspaceTab::Table(slot) if slot.schema.as_deref() == schema.as_deref() && slot.table == name => {
                        Some(slot.page.clone())
                    }
                    _ => None,
                };
                let selected_match = selected_page.and_then(|page| {
                    let id = read_workspace_tab_id(&page)?;
                    matches_slot(tabs.get(&id)?)
                });
                selected_match.or_else(|| tabs.values().find_map(matches_slot))
            };
            if let Some(page) = existing
                && let Some(tab_view) = self.workspace_tab_view.as_ref()
            {
                tab_view.set_selected_page(&page);
                return;
            }
        }
        if is_preview {
            let preview = self.workspace_tabs.borrow().values().find_map(|tab| match tab {
                WorkspaceTab::Table(slot) if slot.preview => Some((slot.id, slot.page.clone())),
                _ => None,
            });
            if let Some((id, page)) = preview {
                let has_pending = crate::services::change_tracker::with_tab_ref(id, |tracker| tracker.has_pending())
                    .unwrap_or(false)
                    || crate::services::structure_tracker::with_tab_ref(id, |tracker| tracker.has_pending())
                        .unwrap_or(false);
                match preview_replacement(true, has_pending) {
                    PreviewReplacement::Replace => {
                        if let Some(tab_view) = self.workspace_tab_view.clone() {
                            self.finish_close_workspace_tab_now(id, &tab_view);
                        }
                    }
                    PreviewReplacement::Promote => {
                        if let Some(WorkspaceTab::Table(slot)) = self.workspace_tabs.borrow_mut().get_mut(&id) {
                            slot.preview = false;
                        }
                        page.set_indicator_icon(None::<&gio::Icon>);
                    }
                    PreviewReplacement::None => {}
                }
            }
        }
        self.append_table_tab(schema, name, 0, self.default_page_size, None, is_preview, sender);
    }

    pub(super) fn refresh_browse_tab_dirty(&self, tab_id: Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let data =
            crate::services::change_tracker::with_tab_ref(tab_id, |tracker| tracker.has_pending()).unwrap_or(false);
        let structure =
            crate::services::structure_tracker::with_tab_ref(tab_id, |tracker| tracker.has_pending()).unwrap_or(false);
        let combined_dirty = data || structure || dirty;
        if combined_dirty {
            let mut tabs = self.workspace_tabs.borrow_mut();
            if let Some(WorkspaceTab::Table(slot)) = tabs.get_mut(&tab_id) {
                slot.preview = false;
                slot.page.set_indicator_icon(None::<&gio::Icon>);
            }
        }
        let (page, title) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(WorkspaceTab::Table(slot)) = tabs.get(&tab_id) else {
                return;
            };
            let label =
                super::workspace_tabs::qualified_browse_tab_label(schemas_count, slot.schema.as_deref(), &slot.table);
            let title = if combined_dirty { format!("• {label}") } else { label };
            (slot.page.clone(), title)
        };
        page.set_title(&title);
        let is_selected = self
            .workspace_tab_view
            .as_ref()
            .and_then(|view| view.selected_page())
            .map(|selected| selected == page)
            .unwrap_or(false);
        page.set_needs_attention(combined_dirty && !is_selected);
        self.refresh_window_title();
        if combined_dirty {
            self.persist_workspace_state();
        }
    }
}
