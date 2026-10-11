use super::column_widths::ColumnWidthStore;
use super::filter_settings::FilterSettingsStore;

#[derive(Clone)]
pub struct PersistenceStores {
    pub column_widths: Option<ColumnWidthStore>,
    pub filter_settings: Option<FilterSettingsStore>,
}

impl PersistenceStores {
    pub fn open() -> Self {
        Self {
            column_widths: ColumnWidthStore::open(),
            filter_settings: FilterSettingsStore::open(),
        }
    }

    pub fn flush(&self) {
        if let Some(store) = &self.column_widths
            && let Err(error) = store.flush()
        {
            tracing::warn!(%error, "column width flush failed");
        }
        if let Some(store) = &self.filter_settings
            && let Err(error) = store.flush()
        {
            tracing::warn!(%error, "filter settings flush failed");
        }
    }
}
