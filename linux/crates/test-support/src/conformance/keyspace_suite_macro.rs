/// Emit the keyspace conformance cases for one key-value engine adapter.
///
/// Every case starts its own server, so every case is
/// `#[ignore = "requires docker"]`, except
/// `keyspace_suite_matches_driver_capabilities`, which fails when the
/// driver's data model is not `KeyValue`.
#[macro_export]
macro_rules! keyspace_conformance_suite {
    (engine: $engine:ty $(,)?) => {
        $crate::__keyspace_cases! {
            $engine,
            keys_are_listed_with_their_kinds,
            a_pattern_is_matched_on_the_server,
            a_listing_stops_at_its_limit_and_says_so,
            every_kind_reads_in_windows_to_its_end,
            a_missing_key_reads_as_none,
            a_stopped_command_ends_and_the_session_runs_again,
            a_dropped_editor_run_stops_the_command,
            a_timed_out_command_is_stopped_by_the_server,
            a_read_only_connection_refuses_writes_before_sending,
            stream_read_streams_every_row,
            a_probe_answers_while_a_command_blocks,
            keyspace_close_is_idempotent,
            a_lost_transport_reports_connection_lost_to_a_listing,
        }

        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn keyspace_suite_matches_driver_capabilities()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::cases::keyspace::keyspace_suite_matches_driver_capabilities::<$engine>()
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __keyspace_cases {
    ($engine:ty, $($name:ident),+ $(,)?) => {
        $(
            $crate::__conformance_case! {
                true,
                $engine as KeyspaceEngine,
                $name,
                $crate::conformance::cases::keyspace::$name::<$engine>
            }
        )+
    };
}
