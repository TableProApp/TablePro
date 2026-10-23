use super::tab_spec::TabSpec;
use super::{WorkspaceModel, WorkspaceTab};
use crate::workspace::DiagramPlace;

impl WorkspaceModel {
    /// Bring the schema's diagram to the front, or open one with `places`,
    /// where a reopened tab's tables were put: two tabs of one schema would
    /// read every table twice.
    pub(super) fn show_diagram(&mut self, schema: Option<String>, places: Vec<DiagramPlace>) {
        let existing = self.workspace_tabs.borrow().values().find_map(|tab| match tab {
            WorkspaceTab::Diagram(slot) if slot.schema == schema => Some(slot.page.clone()),
            _ => None,
        });
        match existing {
            Some(page) => self.tab_view.set_selected_page(&page),
            None => {
                self.open_tab(TabSpec::Diagram { schema, places });
            }
        }
    }

    /// A table changed. Each diagram it may be in says it may be out of
    /// date: those of its schema, or every one when the change cannot
    /// say which tables it touched.
    pub(super) fn diagrams_out_of_date(&self, schema: Option<&str>, named: bool) {
        let diagrams: Vec<_> = self
            .workspace_tabs
            .borrow()
            .values()
            .filter_map(|tab| match tab {
                WorkspaceTab::Diagram(slot) if !named || slot.schema.as_deref() == schema => Some(slot.diagram.clone()),
                _ => None,
            })
            .collect();
        for diagram in diagrams {
            diagram.schema_changed();
        }
    }
}
