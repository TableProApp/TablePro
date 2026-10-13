/// The schema is part of it, so `public.users` and `audit.users` keep
/// their own widths.
#[derive(Clone)]
pub struct ColumnWidthBinding {
    pub store: crate::persistence::ColumnWidthStore,
    pub connection_id: uuid::Uuid,
    pub schema: Option<String>,
    pub table: String,
}

impl std::fmt::Debug for ColumnWidthBinding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ColumnWidthBinding")
            .field("connection_id", &self.connection_id)
            .field("schema", &self.schema)
            .field("table", &self.table)
            .finish()
    }
}

impl ColumnWidthBinding {
    pub(super) fn width(&self, column: &str) -> Option<i32> {
        self.store
            .width(self.connection_id, self.schema.as_deref(), &self.table, column)
    }

    pub(super) fn record(&self, column: &str, width: i32) {
        self.store
            .record(self.connection_id, self.schema.as_deref(), &self.table, column, width);
    }
}
