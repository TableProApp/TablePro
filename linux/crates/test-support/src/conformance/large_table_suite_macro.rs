/// Emit the large-table case for one engine adapter, which implements
/// `LargeTableEngine`. It fills a table of its own, so it runs within
/// `LARGE_TABLE_CASE_LIMIT` rather than `CASE_LIMIT`, and only under
/// Docker: its memory bound reads the whole process's resident peak,
/// which tests running beside it in the unit suite's one process would
/// raise too.
#[macro_export]
macro_rules! large_table_conformance_suite {
    (engine: $engine:ty $(,)?) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        #[ignore = "requires docker"]
        async fn a_million_row_table_pages_to_its_end_and_exports()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::run_case_within(
                "a_million_row_table_pages_to_its_end_and_exports",
                $crate::conformance::cases::large_table::LARGE_TABLE_CASE_LIMIT,
                <$engine as $crate::conformance::ConformanceEngine>::start(),
                $crate::conformance::cases::large_table::a_million_row_table_pages_to_its_end_and_exports::<$engine>,
            )
            .await
        }
    };
}
