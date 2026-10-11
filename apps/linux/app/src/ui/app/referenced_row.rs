use relm4::ComponentSender;

use crate::ui::browse_tab::BrowseTabInput;

use super::{App, WorkspaceTab};

impl App {
    pub(super) fn on_open_referenced_row(
        &mut self,
        schema: Option<String>,
        table: String,
        filter: tablepro_core::FilterSet,
        sender: ComponentSender<Self>,
    ) {
        let existing = self.workspace_tabs.borrow().iter().find_map(|(id, tab)| match tab {
            WorkspaceTab::Table(slot) if slot.schema == schema && slot.table == table => Some((*id, slot.page.clone())),
            _ => None,
        });
        if let Some((tab_id, page)) = existing {
            if let Some(tab_view) = self.workspace_tab_view.as_ref() {
                tab_view.set_selected_page(&page);
            }
            self.dispatch_to_tab(tab_id, BrowseTabInput::FilterApplied(filter));
            return;
        }
        if let (Some(connection_id), Some(store)) = (self.connection_id, &self.persistence.filter_settings)
            && let Err(error) = store.save(connection_id, schema.as_deref(), &table, filter)
        {
            self.show_toast(&error);
            return;
        }
        self.append_table_tab(schema, table, 0, self.default_page_size, None, sender);
    }
}
