use crate::conformance::{ConformanceEngine, UnsupportedTypeCase};

/// An engine with types the driver reads without a decoder of its own.
pub trait TypedConformanceEngine: ConformanceEngine {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase>;
}
