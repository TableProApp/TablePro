/// Emit the connection conformance cases for one engine adapter.
///
/// Every flag is matched by literal arms, so a misspelt flag does not
/// compile. A flag that is off emits no test at all rather than a test
/// that passes without checking anything, and a flag that is on requires
/// the matching engine trait:
///
/// - `endpoint: network` adds the dropped-caller, dropped-editor-run and
///   lost-transport cases and needs `NetworkConformanceEngine`; `file`
///   adds a dropped-editor-run case that checks the session instead.
/// - `pool: pooled` adds the busy-pool probe and needs
///   `PooledConformanceEngine`; `unbounded` is an engine with no slot
///   limit.
/// - `editor_transactions`, `unsupported_types` and `bounded_ddl` add
///   their case and need `EditorTransactionEngine`,
///   `TypedConformanceEngine` and `BoundedDdlEngine`.
/// - `docker: true` marks every case `#[ignore = "requires docker"]`.
///
/// `suite_flags_match_driver_capabilities` is always emitted and never
/// ignored: it fails when `endpoint` or `editor_transactions` disagrees
/// with the driver's capabilities. `pool`, `unsupported_types` and
/// `bounded_ddl` have no capability to check against.
///
/// A case that has not finished `CASE_LIMIT` after its engine started
/// fails with its name, so a driver that ignores a deadline or a cancel
/// cannot hold the test run.
///
/// The example compiles every case against the test-support fakes; a
/// driver's integration target supplies its own engine instead.
///
/// ```no_run,test_harness
/// # use std::path::PathBuf;
/// # use std::sync::Arc;
/// # use std::time::Duration;
/// # use async_trait::async_trait;
/// # use tablepro_core::{
/// #     ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, FileEndpoint, LivenessPolicy,
/// #     NetworkEndpoint, TableRef, WorkspaceSettings,
/// # };
/// # use tablepro_test_support::conformance::{
/// #     BoundedDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine,
/// #     NetworkConformanceEngine, PooledConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
/// # };
/// # use tablepro_test_support::{ConnectionScript, FakeDriver, FaultTransport};
/// # struct ExampleEngine;
/// # #[async_trait]
/// # impl ConformanceEngine for ExampleEngine {
/// #     fn driver() -> Arc<dyn DatabaseDriver> {
/// #         Arc::new(FakeDriver::connecting(&FakeDriver::NETWORK_CAPABILITIES, ConnectionScript::default()))
/// #     }
/// #     async fn start() -> Result<Self, ConformanceFailure> {
/// #         Ok(Self)
/// #     }
/// #     fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
/// #         let file = FileEndpoint::open_existing(PathBuf::from("/example.db")).unwrap();
/// #         ConnectOptions {
/// #             target: ConnectTarget::File(file),
/// #             workspace_settings: settings,
/// #             liveness,
/// #             environment: ConnectEnvironment::new("example"),
/// #         }
/// #     }
/// #     fn scratch_table(&self, name: &str) -> TableRef {
/// #         TableRef::unqualified(name)
/// #     }
/// #     fn create_scratch_table_sql(&self, table: &TableRef) -> String {
/// #         format!("CREATE TABLE {} (id integer primary key, label text not null)", table.name)
/// #     }
/// #     fn unbounded_statement_sql(&self, marker: &str) -> String {
/// #         format!("SELECT pg_sleep(3600), '{marker}'")
/// #     }
/// #     async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
/// #         Ok(format!("SELECT pg_sleep({}), '{marker}'", hold.as_secs()))
/// #     }
/// #     fn row_source_sql(&self, rows: u64) -> String {
/// #         format!("SELECT generate_series(1, {rows})")
/// #     }
/// # }
/// # #[async_trait]
/// # impl NetworkConformanceEngine for ExampleEngine {
/// #     async fn faulty_connect_options(
/// #         &self,
/// #         settings: WorkspaceSettings,
/// #         liveness: LivenessPolicy,
/// #     ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
/// #         let endpoint = NetworkEndpoint::new("127.0.0.1", 5432).map_err(ConformanceFailure::setup)?;
/// #         let fault = FaultTransport::direct(endpoint, &liveness).map_err(ConformanceFailure::setup)?;
/// #         Ok((self.connect_options(settings, liveness), Arc::new(fault)))
/// #     }
/// #     fn running_statement_count_sql(&self, marker: &str) -> String {
/// #         format!("SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%{marker}%'")
/// #     }
/// # }
/// # impl PooledConformanceEngine for ExampleEngine {
/// #     const WORKSPACE_POOL_MAX_SIZE: usize = 4;
/// # }
/// # impl EditorTransactionEngine for ExampleEngine {
/// #     fn begin_sql(&self) -> String {
/// #         "BEGIN".to_owned()
/// #     }
/// #     fn commit_sql(&self) -> String {
/// #         "COMMIT".to_owned()
/// #     }
/// # }
/// # impl TypedConformanceEngine for ExampleEngine {
/// #     fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
/// #         Vec::new()
/// #     }
/// # }
/// # impl BoundedDdlEngine for ExampleEngine {
/// #     fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String {
/// #         format!("CREATE TABLE {} AS SELECT 1 AS id FROM pg_sleep({})", table.name, duration.as_secs())
/// #     }
/// # }
/// mod network_engine {
///     use super::ExampleEngine;
///
///     tablepro_test_support::connection_conformance_suite! {
///         engine: ExampleEngine,
///         docker: true,
///         endpoint: network,
///         pool: pooled,
///         editor_transactions: true,
///         unsupported_types: true,
///         bounded_ddl: true,
///     }
/// }
///
/// mod file_engine {
///     use super::ExampleEngine;
///
///     tablepro_test_support::connection_conformance_suite! {
///         engine: ExampleEngine,
///         docker: false,
///         endpoint: file,
///         pool: unbounded,
///         editor_transactions: false,
///         unsupported_types: false,
///         bounded_ddl: false,
///     }
/// }
/// ```
#[macro_export]
macro_rules! connection_conformance_suite {
    (
        engine: $engine:ty,
        docker: $docker:tt,
        endpoint: $endpoint:tt,
        pool: $pool:tt,
        editor_transactions: $editor:tt,
        unsupported_types: $types:tt,
        bounded_ddl: $ddl:tt $(,)?
    ) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            lists_created_table_with_primary_key_and_unique_identity,
            $crate::conformance::cases::metadata::lists_created_table_with_primary_key_and_unique_identity::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            calls_share_one_call_options,
            $crate::conformance::cases::metadata::calls_share_one_call_options::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            query_bound_times_out_within_deadline_plus_cancel_grace,
            $crate::conformance::cases::deadlines::query_bound_times_out_within_deadline_plus_cancel_grace::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            editor_cancel_reports_cancelled_and_session_stays_ready,
            $crate::conformance::cases::cancellation::editor_cancel_reports_cancelled_and_session_stays_ready::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            read_only_connection_refuses_writes,
            $crate::conformance::cases::read_only::read_only_connection_refuses_writes::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            write_batch_commits_every_step,
            $crate::conformance::cases::writes::write_batch_commits_every_step::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            failed_write_batch_outcome_matches_dml_atomicity,
            $crate::conformance::cases::writes::failed_write_batch_outcome_matches_dml_atomicity::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            row_guard_mismatch_applies_nothing,
            $crate::conformance::cases::row_guards::row_guard_mismatch_applies_nothing::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            close_is_idempotent,
            $crate::conformance::cases::close::close_is_idempotent::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            stream_read_streams_every_row_in_bounded_batches,
            $crate::conformance::cases::streaming::stream_read_streams_every_row_in_bounded_batches::<$engine>
        }
        $crate::__conformance_endpoint_cases! { $endpoint, $docker, $engine }
        $crate::__conformance_pool_case! { $pool, $endpoint, $docker, $engine }
        $crate::__conformance_editor_case! { $editor, $docker, $engine }
        $crate::__conformance_types_case! { $types, $docker, $engine }
        $crate::__conformance_ddl_case! { $ddl, $docker, $engine }

        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn suite_flags_match_driver_capabilities()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::cases::suite_flags::suite_flags_match_driver_capabilities::<$engine>(
                $crate::conformance::ConnectionSuiteFlags {
                    endpoint: $crate::__conformance_endpoint!($endpoint),
                    editor_transactions: $crate::__conformance_flag!($editor),
                },
            )
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_case {
    (true, $engine:ty as $kind:ident, $name:ident, $case:expr) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        #[ignore = "requires docker"]
        async fn $name() -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::run_case(
                ::core::stringify!($name),
                <$engine as $crate::conformance::$kind>::start(),
                $case,
            )
            .await
        }
    };
    (false, $engine:ty as $kind:ident, $name:ident, $case:expr) => {
        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn $name() -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::run_case(
                ::core::stringify!($name),
                <$engine as $crate::conformance::$kind>::start(),
                $case,
            )
            .await
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_flag {
    (true) => {
        true
    };
    (false) => {
        false
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_endpoint {
    (network) => {
        $crate::conformance::SuiteEndpoint::Network
    };
    (file) => {
        $crate::conformance::SuiteEndpoint::File
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_endpoint_cases {
    (network, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            dropped_caller_stops_server_statement,
            $crate::conformance::cases::cancellation::dropped_caller_stops_server_statement::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            dropped_editor_run_stops_server_statement,
            $crate::conformance::cases::cancellation::dropped_editor_run_stops_server_statement::<$engine>
        }
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            lost_transport_reports_connection_lost,
            $crate::conformance::cases::liveness::lost_transport_reports_connection_lost::<$engine>
        }
    };
    (file, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            dropped_editor_run_frees_the_session,
            $crate::conformance::cases::cancellation::dropped_editor_run_frees_the_session::<$engine>
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_pool_case {
    (pooled, network, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            probe_succeeds_while_every_pool_slot_is_busy,
            $crate::conformance::cases::pool::probe_succeeds_while_every_network_pool_slot_is_busy::<$engine>
        }
    };
    (pooled, file, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            probe_succeeds_while_every_pool_slot_is_busy,
            $crate::conformance::cases::pool::probe_succeeds_while_every_pool_slot_is_busy::<$engine>
        }
    };
    (unbounded, network, $docker:tt, $engine:ty) => {};
    (unbounded, file, $docker:tt, $engine:ty) => {};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_editor_case {
    (true, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            row_limit_keeps_transaction_and_later_statements,
            $crate::conformance::cases::row_limit::row_limit_keeps_transaction_and_later_statements::<$engine>
        }
    };
    (false, $docker:tt, $engine:ty) => {};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_types_case {
    (true, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            unsupported_types_never_decode_as_null,
            $crate::conformance::cases::type_fallback::unsupported_types_never_decode_as_null::<$engine>
        }
    };
    (false, $docker:tt, $engine:ty) => {};
}

#[doc(hidden)]
#[macro_export]
macro_rules! __conformance_ddl_case {
    (true, $docker:tt, $engine:ty) => {
        $crate::__conformance_case! {
            $docker,
            $engine as ConformanceEngine,
            schema_changes_batch_is_not_bounded_by_statement_timeout,
            $crate::conformance::cases::statement_timeout::schema_changes_batch_is_not_bounded_by_statement_timeout::<$engine>
        }
    };
    (false, $docker:tt, $engine:ty) => {};
}
