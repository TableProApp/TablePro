//! One window's session: its connection link, the operation chokepoint,
//! the health monitor, the schema catalog, and an ordered shutdown.

mod editor_session_shutdown;
mod object_list_snapshot;
mod schema_catalog;
#[expect(
    clippy::module_inception,
    reason = "the Session type is the module's subject, as the plan names its file"
)]
mod session;
mod session_deps;

pub use editor_session_shutdown::close_editor_sessions;
pub use object_list_snapshot::ObjectListSnapshot;
pub use schema_catalog::SchemaCatalog;
pub use session::Session;
pub use session_deps::SessionDeps;
