/// Emit the TLS conformance cases for one engine adapter.
///
/// Every case starts a TLS-only server, so every case is
/// `#[ignore = "requires docker"]`. `client_identity: true` adds the
/// client-certificate case and needs `ClientIdentityEngine`; `false`
/// emits no such case. `tls_suite_flags_match_driver_capabilities` is
/// never ignored and fails when the flag disagrees with the driver's
/// TLS capabilities.
///
/// ```no_run,test_harness
/// # use std::path::{Path, PathBuf};
/// # use std::sync::Arc;
/// # use async_trait::async_trait;
/// # use tablepro_core::{
/// #     ClientIdentity, ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, ErrorCategory,
/// #     FileEndpoint, TlsConfig, WorkspaceSettings,
/// # };
/// # use tablepro_test_support::conformance::{
/// #     ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
/// # };
/// # use tablepro_test_support::{ConnectionScript, FakeDriver};
/// # struct ExampleTlsEngine;
/// # #[async_trait]
/// # impl TlsConformanceEngine for ExampleTlsEngine {
/// #     fn driver() -> Arc<dyn DatabaseDriver> {
/// #         Arc::new(FakeDriver::connecting(&FakeDriver::NETWORK_CAPABILITIES, ConnectionScript::default()))
/// #     }
/// #     async fn start() -> Result<Self, ConformanceFailure> {
/// #         Ok(Self)
/// #     }
/// #     fn connect_options(&self, _tls: TlsConfig) -> ConnectOptions {
/// #         let file = FileEndpoint::open_existing(PathBuf::from("/example.db")).unwrap();
/// #         ConnectOptions {
/// #             target: ConnectTarget::File(file),
/// #             workspace_settings: WorkspaceSettings::workspace(false),
/// #             liveness: test_liveness(),
/// #             environment: ConnectEnvironment::new("example"),
/// #         }
/// #     }
/// #     fn ca_file(&self) -> &Path {
/// #         Path::new("/tls/ca.pem")
/// #     }
/// #     fn unrelated_ca_file(&self) -> &Path {
/// #         Path::new("/tls/unrelated-ca.pem")
/// #     }
/// #     fn served_name(&self) -> &str {
/// #         "db.tablepro.test"
/// #     }
/// #     fn plaintext_rejection_category(&self) -> ErrorCategory {
/// #         ErrorCategory::Tls
/// #     }
/// # }
/// # impl ClientIdentityEngine for ExampleTlsEngine {
/// #     fn client_identity(&self) -> ClientIdentity {
/// #         ClientIdentity {
/// #             certificate: PathBuf::from("/tls/client.pem"),
/// #             key: PathBuf::from("/tls/client.key"),
/// #         }
/// #     }
/// #     fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
/// #         self.connect_options(tls)
/// #     }
/// # }
/// mod with_client_identity {
///     use super::ExampleTlsEngine;
///
///     tablepro_test_support::tls_conformance_suite! {
///         engine: ExampleTlsEngine,
///         client_identity: true,
///     }
/// }
///
/// mod without_client_identity {
///     use super::ExampleTlsEngine;
///
///     tablepro_test_support::tls_conformance_suite! {
///         engine: ExampleTlsEngine,
///         client_identity: false,
///     }
/// }
/// ```
#[macro_export]
macro_rules! tls_conformance_suite {
    (engine: $engine:ty, client_identity: $identity:tt $(,)?) => {
        $crate::__conformance_case! {
            true,
            verify_full_with_issuing_ca_connects,
            $crate::conformance::cases::tls::verify_full_with_issuing_ca_connects::<$engine>
        }
        $crate::__conformance_case! {
            true,
            verify_full_with_unrelated_ca_reports_unknown_issuer,
            $crate::conformance::cases::tls::verify_full_with_unrelated_ca_reports_unknown_issuer::<$engine>
        }
        $crate::__conformance_case! {
            true,
            verify_full_with_wrong_server_name_reports_name_mismatch,
            $crate::conformance::cases::tls::verify_full_with_wrong_server_name_reports_name_mismatch::<$engine>
        }
        $crate::__conformance_case! {
            true,
            require_connects_without_ca,
            $crate::conformance::cases::tls::require_connects_without_ca::<$engine>
        }
        $crate::__conformance_case! {
            true,
            disable_against_tls_only_server_is_refused,
            $crate::conformance::cases::tls::disable_against_tls_only_server_is_refused::<$engine>
        }
        $crate::__tls_identity_case! { $identity, $engine }

        #[::tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn tls_suite_flags_match_driver_capabilities()
        -> ::core::result::Result<(), $crate::conformance::ConformanceFailure> {
            $crate::conformance::cases::tls::tls_suite_flags_match_driver_capabilities::<$engine>(
                $crate::__conformance_flag!($identity),
            )
        }
    };
}

#[doc(hidden)]
#[macro_export]
macro_rules! __tls_identity_case {
    (true, $engine:ty) => {
        $crate::__conformance_case! {
            true,
            client_identity_is_required_by_the_server,
            $crate::conformance::cases::tls::client_identity_is_required_by_the_server::<$engine>
        }
    };
    (false, $engine:ty) => {};
}
