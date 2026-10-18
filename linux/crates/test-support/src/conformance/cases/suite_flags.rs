use tablepro_core::{EndpointKind, WriteAtomicity};

use crate::conformance::support::expect;
use crate::conformance::{ConformanceEngine, ConformanceFailure, ConnectionSuiteFlags, SuiteEndpoint};

const CASE: &str = "suite_flags_match_driver_capabilities";

/// The suite's flags agree with the driver's capability table, so a
/// suite cannot skip a case by declaring less than the driver claims.
pub fn suite_flags_match_driver_capabilities<E: ConformanceEngine>(
    flags: ConnectionSuiteFlags,
) -> Result<(), ConformanceFailure> {
    let capabilities = E::driver().capabilities();
    let endpoint = match capabilities.endpoint {
        EndpointKind::Network { .. } => SuiteEndpoint::Network,
        EndpointKind::File => SuiteEndpoint::File,
    };
    expect(CASE, flags.endpoint == endpoint, || {
        format!(
            "the suite says endpoint {:?}, the driver says {:?}",
            flags.endpoint, capabilities.endpoint
        )
    })?;
    let transactional = capabilities.dml_writes == WriteAtomicity::Transactional;
    expect(CASE, flags.editor_transactions == transactional, || {
        format!(
            "the suite says editor_transactions {}, the driver's row writes are {:?}",
            flags.editor_transactions, capabilities.dml_writes
        )
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverCapabilities;

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeDriver};

    struct FileDriver;

    impl FakeScenario for FileDriver {
        fn capabilities() -> &'static DriverCapabilities {
            &FakeDriver::FILE_CAPABILITIES
        }

        fn script() -> ConnectionScript {
            FakeEngine::<Self>::base_script()
        }
    }

    #[test]
    fn suite_flags_test_fails_on_mismatched_endpoint() {
        let flags = ConnectionSuiteFlags {
            endpoint: SuiteEndpoint::Network,
            editor_transactions: true,
        };

        let outcome = suite_flags_match_driver_capabilities::<FakeEngine<FileDriver>>(flags);

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("endpoint")),
            "{outcome:?}"
        );
    }

    #[test]
    fn suite_flags_test_passes_when_the_flags_match() {
        let flags = ConnectionSuiteFlags {
            endpoint: SuiteEndpoint::File,
            editor_transactions: true,
        };

        suite_flags_match_driver_capabilities::<FakeEngine<FileDriver>>(flags).unwrap();
    }
}
