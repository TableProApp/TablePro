//! Which window owns which session, so the same database opens once.

mod claim_error;
mod file_identity;
mod registry_event;
mod registry_subscription;
mod session_claim;
mod session_key;
mod session_registry;

pub use claim_error::ClaimError;
pub use file_identity::FileIdentity;
pub use registry_event::RegistryEvent;
pub use registry_subscription::RegistrySubscription;
pub use session_claim::SessionClaim;
pub use session_key::SessionKey;
pub use session_registry::SessionRegistry;
