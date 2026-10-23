use libadwaita as adw;
use tablepro_core::browse::RowReference;
use tablepro_core::meta::{ObjectInfo, ObjectScope};
use uuid::Uuid;

use super::tab_spec::{TabSpec, TablePage};
use super::{WorkspaceInput, WorkspaceModel, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::ui::browse_tab::TableFilter;

impl WorkspaceModel {
    /// A tab already on the table under the same filter is shown again.
    /// Otherwise the table is looked for in its schema first, so a key
    /// whose table is gone says so rather than opening an error page.
    pub(super) fn on_follow_reference(&mut self, source: Uuid, reference: RowReference) {
        if let Some(page) = self.tab_showing(&reference) {
            self.tab_view.set_selected_page(&page);
            return;
        }
        let Some(session) = self.context.active.get() else {
            return;
        };
        let scope = match &reference.table.schema {
            Some(schema) => ObjectScope::Schema(schema.clone()),
            None => ObjectScope::DefaultSchema,
        };
        let input = self.input.clone();
        let name = reference.table.name.clone();
        let work = async move {
            let lists = |objects: &[ObjectInfo]| {
                objects
                    .iter()
                    .any(|object| object.name == name && object.kind.is_browsable())
            };
            // The catalog's copy can be older than the key, so a table
            // it does not list is looked for once more on the server.
            match session.objects(scope.clone()).await {
                Ok(objects) if lists(&objects) => Ok(true),
                _ => session.refresh_objects(scope).await.map(|objects| lists(&objects)),
            }
        };
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |listed| {
            let found = match listed {
                Ok(Ok(found)) => Some(found),
                Ok(Err(error)) => {
                    tracing::debug!(category = ?error.category(), "the objects of a key's schema could not be read");
                    None
                }
                Err(failure) => {
                    tracing::debug!(%failure, "the read of a key's schema did not finish");
                    None
                }
            };
            input.deliver(WorkspaceInput::ReferenceChecked {
                tab: source,
                reference: Box::new(reference),
                found,
            });
        });
    }

    /// A list that could not be read leaves the answer to the tab, whose
    /// own read says what went wrong.
    pub(super) fn on_reference_checked(&mut self, source: Uuid, reference: RowReference, found: Option<bool>) {
        if found == Some(false) {
            let table = match &reference.table.schema {
                Some(schema) => format!("{schema}.{}", reference.table.name),
                None => reference.table.name.clone(),
            };
            self.show_toast(&crate::i18n::gettext_f(
                "Can't find the table {table}",
                &[("table", &table)],
            ));
            return;
        }
        if let Some(page) = self.tab_showing(&reference) {
            self.tab_view.set_selected_page(&page);
            return;
        }
        let spec = TabSpec::Table {
            table: reference.table,
            page: TablePage::first(u64::from(self.settings.default_page_size())),
            filter: TableFilter::Followed(reference.filter),
        };
        let source_page = self.workspace_tabs.borrow().get(&source).map(|tab| tab.page().clone());
        let page = match source_page {
            Some(parent) => self.factory.create_beside(spec, &parent),
            None => self.factory.create(spec),
        };
        if let Some(page) = page {
            self.tab_view.set_selected_page(&page);
        }
    }

    /// The table tab on the reference's table whose rows were read under
    /// exactly its filter.
    fn tab_showing(&self, reference: &RowReference) -> Option<adw::TabPage> {
        self.workspace_tabs.borrow().values().find_map(|tab| match tab {
            WorkspaceTab::Table(slot)
                if slot.schema == reference.table.schema
                    && slot.table == reference.table.name
                    && slot.browse.applied_filter() == reference.filter =>
            {
                Some(slot.page.clone())
            }
            _ => None,
        })
    }
}
