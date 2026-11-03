// The host's side of the driver ABI (core/docs/decisions/0004-driver-plugin-abi.md): loading a driver library,
// calling it, checking who signed it, and the drivers installed in the app's data folder.

mod error;
mod handle;
mod library;
pub mod registry;
mod store;
pub mod trust;

pub use error::PluginError;
pub use handle::{DriverHandle, PendingCall, Reply};
pub use library::{DriverIdentity, DriverLibrary, HOST_ABI_MINOR, check_descriptor, host_api, open_static};
pub use store::{DriverState, DriverStore, Expected, INDEX_FILE, InstalledDriver, library_file_name};
pub use trust::{PlatformTrust, Purpose, Signer, Trust, open_for_load};
