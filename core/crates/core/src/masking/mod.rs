// Masking hides a column's values on screen and on every path out of the app, by a connection's rules. The macOS
// engine (apple/TablePro/Core/Services/Masking) is the reference; this one gives the same output for the same text.
// The decision: core/docs/decisions/0028-data-masking.md.

mod column_masks;
pub mod detect;
mod glob;
mod mask_value;
mod masking_sink;
mod policy;
mod rule;
mod share;
mod style;
mod withheld;

pub use column_masks::ColumnMasks;
pub use glob::glob_matches;
pub use mask_value::{BULLETS, mask_text, mask_value, stable_hash};
pub use masking_sink::{MaskingScope, MaskingSink};
pub use policy::{MaskingPolicy, SharedMaskingPolicy, WeakMaskingPolicy, base_type_name, table_name};
pub use rule::{MaskingRule, decode_rules, decode_rules_value, deserialize_rules, encode_rules};
pub use share::{ShareChoice, SharePlan, ShareSummary};
pub use style::{MaskingStyle, MaskingTarget};
pub use withheld::{may_repeat_a_value, server_code};
