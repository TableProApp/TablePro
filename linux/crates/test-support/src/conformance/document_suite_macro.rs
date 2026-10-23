/// Emit the document conformance cases for one document engine adapter.
///
/// Every case starts its own server, so every case is
/// `#[ignore = "requires docker"]`, except
/// `document_suite_matches_driver_capabilities`, which fails when the
/// driver's data model is not `Document`.
#[macro_export]
macro_rules! document_conformance_suite {
    (engine: $engine:ty $(,)?) => {
        $crate::__document_cases! {
            $engine,
            collections_are_listed_in_their_database,
            fields_become_columns_with_the_id_first,
            pages_read_every_document_in_order,
            a_filter_and_a_sort_are_read_on_the_server,
            a_field_edit_saves_and_reads_back,
            a_save_on_a_document_that_is_gone_changes_nothing,
            an_insert_and_a_delete_land,
            a_read_only_connection_refuses_writes_before_sending,
            a_stopped_statement_ends_and_the_session_runs_again,
            a_dropped_editor_run_stops_the_statement,
            a_timed_out_statement_is_stopped_by_the_server,
            an_editor_result_keeps_the_row_limit,
            stream_read_streams_every_document,
            a_probe_answers_while_a_statement_runs,
            document_close_is_idempotent,
            a_lost_transport_reports_connection_lost_to_a_read,
        }

        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn document_suite_matches_driver_capabilities()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::cases::document::document_suite_matches_driver_capabilities::<$engine>()
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __document_cases {
    ($engine:ty, $($name:ident),+ $(,)?) => {
        $(
            $crate::__conformance_case! {
                true,
                $engine as DocumentEngine,
                $name,
                $crate::conformance::cases::document::$name::<$engine>
            }
        )+
    };
}
