use super::column_widths::ColumnWidthStore;
use super::csv_import_mappings::CsvMappingStore;
use super::filter_settings::FilterSettingsStore;
use super::named_filter_presets::NamedFilterPresetsStore;

#[derive(Clone)]
pub struct PersistenceStores {
    pub column_widths: Option<ColumnWidthStore>,
    pub filter_settings: Option<FilterSettingsStore>,
    pub csv_import_mappings: Option<CsvMappingStore>,
    pub named_filter_presets: Option<NamedFilterPresetsStore>,
}

impl PersistenceStores {
    pub fn open() -> Self {
        Self {
            column_widths: ColumnWidthStore::open(),
            filter_settings: FilterSettingsStore::open(),
            csv_import_mappings: CsvMappingStore::open(),
            named_filter_presets: NamedFilterPresetsStore::open(),
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
        if let Some(store) = &self.csv_import_mappings
            && let Err(error) = store.flush()
        {
            tracing::warn!(%error, "CSV import mapping flush failed");
        }
        if let Some(store) = &self.named_filter_presets
            && let Err(error) = store.flush()
        {
            tracing::warn!(%error, "named filter presets flush failed");
        }
    }
}
