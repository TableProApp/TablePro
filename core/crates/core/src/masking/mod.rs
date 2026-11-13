// Masking a shared result's columns before they leave the machine: the macOS styles, byte for byte, the detectors that
// suggest which columns to mask, and the plan a share sends by. The decision: core/docs/decisions/0028-data-masking.md.

pub mod detect;
mod mask_value;
mod share;
mod style;

pub use mask_value::{BULLETS, mask_text, mask_value, stable_hash};
pub use share::{ShareChoice, SharePlan, ShareSummary};
pub use style::MaskingStyle;
