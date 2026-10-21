/// Emit the export round-trip cases for one engine adapter, which
/// implements `ValueCorpusEngine` and `LargeTableEngine`. `docker: true`
/// marks them `#[ignore = "requires docker"]`.
///
/// The value corpus goes out as CSV and comes back through the import,
/// and goes out as SQL INSERT and comes back through an editor run, each
/// into an empty copy of its table. `near_limit: true` adds a case that
/// exports a table whose CSV lands just under the import's size limit
/// and imports it back. It describes how fast the engine takes an
/// import, so no capability stands behind it.
#[macro_export]
macro_rules! round_trip_suite {
    (engine: $engine:ty, docker: $docker:tt, near_limit: $near_limit:tt $(,)?) => {
        $crate::__round_trip_case! { $docker, $engine, csv_export_imports_back_as_the_same_rows }
        $crate::__round_trip_case! { $docker, $engine, sql_insert_export_runs_back_as_the_same_rows }
        $crate::__near_limit_case! { $near_limit, $docker, $engine }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __near_limit_case {
    (true, $docker:tt, $engine:ty) => {
        $crate::__round_trip_case! { $docker, $engine, csv_export_near_the_import_limit_imports_back }
    };
    (false, $docker:tt, $engine:ty) => {};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __round_trip_case {
    (true, $engine:ty, $name:ident) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        #[ignore = "requires docker"]
        async fn $name() -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::__round_trip_case!(run $engine, $name)
        }
    };
    (false, $engine:ty, $name:ident) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn $name() -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::__round_trip_case!(run $engine, $name)
        }
    };
    (run $engine:ty, $name:ident) => {
        $crate::conformance::run_case_within(
            ::core::stringify!($name),
            $crate::conformance::cases::round_trip::ROUND_TRIP_CASE_LIMIT,
            <$engine as $crate::conformance::ConformanceEngine>::start(),
            $crate::conformance::cases::round_trip::$name::<$engine>,
        )
        .await
    };
}
