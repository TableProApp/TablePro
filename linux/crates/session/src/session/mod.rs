//! One window's session: its connection link, the operation chokepoint,
//! the health monitor, and an ordered shutdown.

mod catalog_snapshot;
mod editor_session_shutdown;
#[expect(
    clippy::module_inception,
    reason = "the Session type is the module's subject, as the plan names its file"
)]
mod session;
mod session_deps;

pub use catalog_snapshot::CatalogSnapshot;
pub use editor_session_shutdown::close_editor_sessions;
pub use session::Session;
pub use session_deps::SessionDeps;
