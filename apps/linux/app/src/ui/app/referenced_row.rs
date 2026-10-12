use relm4::ComponentSender;
use relm4::adw;
use relm4::adw::prelude::*;

use crate::ui::browse_tab::BrowseTabInput;

use super::{App, WorkspaceTab};

pub(super) fn choose_referenced_row(
    parent: &adw::ApplicationWindow,
    targets: Vec<crate::ui::browse_tab::reference::ReferencedRowTarget>,
    sender: ComponentSender<App>,
) {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("Choose a referenced table")),
        Some(&crate::tr!("This column belongs to more than one foreign key.")),
    );
    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.set_close_response("cancel");
    for (index, target) in targets.iter().enumerate() {
        let response = format!("foreign-key-{index}");
        let schema = target
            .schema
            .as_deref()
            .map(|value| format!("{value}."))
            .unwrap_or_default();
        let label = format!("{} → {}{}", target.foreign_key, schema, target.table);
        dialog.add_response(&response, &label);
    }
    dialog.connect_response(None, move |dialog, response| {
        dialog.close();
        let Some(index) = response
            .strip_prefix("foreign-key-")
            .and_then(|value| value.parse::<usize>().ok())
        else {
            return;
        };
        let Some(target) = targets.get(index) else {
            return;
        };
        sender.input(super::AppMsg::OpenReferencedRow {
            schema: target.schema.clone(),
            table: target.table.clone(),
            filter: target.filter.clone(),
        });
    });
    dialog.present(Some(parent));
}

impl App {
    pub(super) fn on_choose_referenced_row(
        &self,
        targets: Vec<crate::ui::browse_tab::reference::ReferencedRowTarget>,
        sender: ComponentSender<Self>,
    ) {
        choose_referenced_row(&self.window, targets, sender);
    }

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
