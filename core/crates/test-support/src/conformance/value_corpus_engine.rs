use crate::conformance::{ConformanceEngine, ValueCorpus};

pub trait ValueCorpusEngine: ConformanceEngine {
    fn value_corpus(&self) -> ValueCorpus;
}
