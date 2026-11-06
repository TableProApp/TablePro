/// Emit the dump round trip for one engine adapter, which implements
/// `DumpEngine`. `docker: true` marks it `#[ignore = "requires docker"]`.
///
/// The case fills a database with the adapter's sample, dumps it, loads
/// the file into an empty database through the SQL file import, and
/// dumps that one: the two files must be the same, rows, counters and
/// all. A second case loads the file the engine's own dump tool wrote,
/// where the adapter has one.
#[macro_export]
macro_rules! dump_suite {
    (engine: $engine:ty, docker: $docker:tt $(,)?) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            dump_loads_back_into_an_empty_database,
            $crate::conformance::cases::dump::dump_loads_back_into_an_empty_database::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            native_dump_loads_through_the_import,
            $crate::conformance::cases::dump::native_dump_loads_through_the_import::<$engine>
        }
    };
}
