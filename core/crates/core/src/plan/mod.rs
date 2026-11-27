//! Parsed EXPLAIN query plans: the engine-agnostic model, the per-engine EXPLAIN
//! options a driver offers, and the parsers that turn an engine's EXPLAIN output
//! into the model. The app words and draws it; the core parses it (ROADMAP S-17).

mod model;
mod variant;

pub use model::{QueryPlan, QueryPlanMissingIndex, QueryPlanNode};
pub use variant::{ExplainPlanFormat, ExplainStep, ExplainVariant};
