/// Emit the large-table case for one engine adapter, which implements
/// `LargeTableEngine`. It fills a table of its own, so it runs within
/// `LARGE_TABLE_CASE_LIMIT` rather than `CASE_LIMIT`. `docker: true`
/// marks it `#[ignore = "requires docker"]`.
///
/// Its memory bound reads the whole process's resident peak, so the case
/// needs a process to itself. nextest gives every test one. `cargo test`
/// runs the tests of one target in one process, so with `docker: false`
/// the case goes in a test target that holds nothing else.
#[macro_export]
macro_rules! large_table_conformance_suite {
    (engine: $engine:ty, docker: true $(,)?) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        #[ignore = "requires docker"]
        async fn a_million_row_table_pages_to_its_end_and_exports()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::__large_table_case!($engine)
        }
    };
    (engine: $engine:ty, docker: false $(,)?) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn a_million_row_table_pages_to_its_end_and_exports()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::__large_table_case!($engine)
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __large_table_case {
    ($engine:ty) => {
        $crate::conformance::run_case_within(
            "a_million_row_table_pages_to_its_end_and_exports",
            $crate::conformance::cases::large_table::LARGE_TABLE_CASE_LIMIT,
            <$engine as $crate::conformance::ConformanceEngine>::start(),
            $crate::conformance::cases::large_table::a_million_row_table_pages_to_its_end_and_exports::<$engine>,
        )
        .await
    };
}
