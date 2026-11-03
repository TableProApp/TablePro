// The driver ABI of core/docs/decisions/0004-driver-plugin-abi.md: the C table (`ffi`, include/tablepro_driver.h),
// the messages (`proto`), the driver's side of the table (`export`) and any core driver behind it (`serve`).

pub mod export;
pub mod ffi;
pub mod proto;
pub mod rows;
pub mod serve;

pub use serve::CoreDriver;
