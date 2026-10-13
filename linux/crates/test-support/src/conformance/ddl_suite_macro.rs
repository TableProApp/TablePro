/// Emit the DDL conformance cases for one engine adapter, which
/// implements `ConformanceDdlEngine`. `docker: true` marks every case
/// `#[ignore = "requires docker"]`.
///
/// Each case plans through the connection's own `DdlDialect` and runs
/// the plan with `write_batch`, so what it checks is the SQL the
/// structure tab would send.
#[macro_export]
macro_rules! ddl_conformance_suite {
    (engine: $engine:ty, docker: $docker:tt $(,)?) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            ddl_plans_apply_and_read_back,
            $crate::conformance::cases::ddl::ddl_plans_apply_and_read_back::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            failed_ddl_batch_outcome_matches_ddl_atomicity,
            $crate::conformance::cases::ddl::failed_ddl_batch_outcome_matches_ddl_atomicity::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            create_table_script_recreates_the_table,
            $crate::conformance::cases::ddl::create_table_script_recreates_the_table::<$engine>
        }
    };
}
