use uuid::Uuid;

use crate::persistence::ColumnLayoutStore;
use crate::services::grid::ColumnLayout;

/// Where a table's column layout is kept. The schema is part of it, so
/// `public.users` and `audit.users` keep their own.
#[derive(Debug, Clone)]
pub struct LayoutBinding {
    pub store: ColumnLayoutStore,
    pub connection_id: Uuid,
    pub schema: Option<String>,
    pub table: String,
}

impl LayoutBinding {
    pub fn load(&self) -> ColumnLayout {
        self.store
            .layout(self.connection_id, self.schema.as_deref(), &self.table)
    }

    pub fn save(&self, layout: &ColumnLayout) {
        self.store
            .save(self.connection_id, self.schema.as_deref(), &self.table, layout);
    }
}
