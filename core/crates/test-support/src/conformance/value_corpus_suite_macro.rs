/// Emit the value corpus case for one engine adapter, which implements
/// `ValueCorpusEngine`. `docker: true` marks it
/// `#[ignore = "requires docker"]`.
///
/// The case writes each corpus value as SQL, reads it back through a
/// browse page, a table export and an editor run, and checks the text
/// the grid shows for it on each path.
#[macro_export]
macro_rules! value_corpus_suite {
    (engine: $engine:ty, docker: $docker:tt $(,)?) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            value_corpus_reads_as_the_grid_shows,
            $crate::conformance::cases::value_corpus::value_corpus_reads_as_the_grid_shows::<$engine>
        }
    };
}
