use super::DdlCapabilities;

/// How one engine spells structure changes.
///
/// Reached through `SqlDialect::ddl`, which is `None` for an engine
/// whose structure the app does not edit. The planning methods land
/// with the per-engine DDL plans; the capabilities are here first so
/// the UI can gate on them through the same accessor.
pub trait DdlDialect: Send + Sync + std::fmt::Debug {
    fn capabilities(&self) -> &DdlCapabilities;
}
