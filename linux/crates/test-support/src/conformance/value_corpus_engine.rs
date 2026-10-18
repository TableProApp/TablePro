use crate::conformance::{ConformanceEngine, CorpusColumn};

/// An engine with a corpus of real values for the value corpus case.
pub trait ValueCorpusEngine: ConformanceEngine {
    fn value_corpus(&self) -> Vec<CorpusColumn>;
}
