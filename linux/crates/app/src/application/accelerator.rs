use super::{AcceleratorScope, ShortcutListing};

#[derive(Debug, Clone, Copy)]
pub struct Accelerator {
    pub action: &'static str,
    pub triggers: &'static [&'static str],
    pub scope: AcceleratorScope,
    pub listing: ShortcutListing,
}
