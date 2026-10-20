use relm4::ComponentSender;
use relm4::gtk::gio;
use uuid::Uuid;

use super::{App, OpenMode, WorkspaceTab};
use tablepro_app_services::workspace::{TableOpenPlan, TableOpenRequest};

impl App {
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        let request = TableOpenRequest {
            schema: schema.as_deref(),
            table: &name,
            selected: self.selected_workspace_tab_id(),
            mode: open_mode,
            preview_enabled: self.preferences.load().open_tables_in_preview_tab,
        };
        let plan = self.workspace_tabs.borrow().plan_table_open(request, |id| {
            crate::services::change_tracker::with_tab_ref(id, |tracker| tracker.has_pending()).unwrap_or(false)
                || crate::services::structure_tracker::with_tab_ref(id, |tracker| tracker.has_pending())
                    .unwrap_or(false)
        });
        let TableOpenPlan::Append {
            preview: is_preview,
            replace,
            promote,
        } = plan
        else {
            if let TableOpenPlan::Select(id) = plan {
                self.select_table_tab(id);
            }
            return;
        };
        if let Some(id) = replace
            && let Some(view) = self.workspace_tab_view.clone()
        {
            self.finish_close_workspace_tab_now(id, &view);
        }
        if let Some(id) = promote {
            self.keep_table_tab(id);
        }
        self.append_table_tab(schema, name, 0, self.default_page_size, None, is_preview, sender);
    }

    fn select_table_tab(&self, id: Uuid) {
        let page = self.workspace_tabs.borrow().get(&id).and_then(|tab| match tab {
            WorkspaceTab::Table(slot) => Some(slot.page.clone()),
            _ => None,
        });
        if let Some(page) = page
            && let Some(view) = self.workspace_tab_view.as_ref()
        {
            view.set_selected_page(&page);
        }
    }

    fn keep_table_tab(&self, id: Uuid) {
        let page = {
            let mut tabs = self.workspace_tabs.borrow_mut();
            tabs.keep(&id);
            tabs.get(&id).and_then(|tab| match tab {
                WorkspaceTab::Table(slot) => Some(slot.page.clone()),
                _ => None,
            })
        };
        if let Some(page) = page {
            page.set_indicator_icon(None::<&gio::Icon>);
        }
    }

    pub(super) fn refresh_browse_tab_dirty(&self, tab_id: Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let data =
            crate::services::change_tracker::with_tab_ref(tab_id, |tracker| tracker.has_pending()).unwrap_or(false);
        let structure =
            crate::services::structure_tracker::with_tab_ref(tab_id, |tracker| tracker.has_pending()).unwrap_or(false);
        let combined_dirty = data || structure || dirty;
        if combined_dirty {
            self.keep_table_tab(tab_id);
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
