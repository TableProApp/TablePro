use crate::persistence::{ColumnLayoutStore, TableStateKey};
use crate::services::grid::ColumnLayout;

#[derive(Debug, Clone)]
pub struct LayoutBinding {
    pub store: ColumnLayoutStore,
    pub state_key: TableStateKey,
    pub schema: Option<String>,
    pub table: String,
}

impl LayoutBinding {
    pub fn load(&self) -> ColumnLayout {
        self.store.layout(&self.state_key, self.schema.as_deref(), &self.table)
    }

    pub fn save(&self, layout: &ColumnLayout) {
        self.store
            .save(&self.state_key, self.schema.as_deref(), &self.table, layout);
    }
}
