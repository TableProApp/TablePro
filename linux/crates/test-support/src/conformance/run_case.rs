use std::future::Future;
use std::time::Duration;

use crate::conformance::ConformanceFailure;
use crate::conformance::support::unexpected;

/// How long a case may run once its engine is up. Against a healthy
/// server every case takes seconds; the limit only ends a case whose
/// driver ignores a deadline or a cancel, well before the `ci` nextest
/// profile kills the test without saying why.
pub const CASE_LIMIT: Duration = Duration::from_secs(120);

/// Starting the engine is outside `CASE_LIMIT`: pulling and booting a
/// server image can take minutes and says nothing about the driver.
pub async fn run_case<E, C, F>(
    name: &'static str,
    start: impl Future<Output = Result<E, ConformanceFailure>>,
    case: C,
) -> Result<(), ConformanceFailure>
where
    C: FnOnce(E) -> F,
    F: Future<Output = Result<(), ConformanceFailure>>,
{
    let engine = start.await?;
    tokio::time::timeout(CASE_LIMIT, case(engine))
        .await
        .map_err(|_| unexpected(name, format!("did not finish within {CASE_LIMIT:?}")))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conformance::ConformanceEngine;
    use crate::conformance::cases::deadlines::query_bound_times_out_within_deadline_plus_cancel_grace;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    const CASE: &str = "query_bound_times_out_within_deadline_plus_cancel_grace";

    struct NeverAnswers;

    impl FakeScenario for NeverAnswers {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script.query_bound.always(FakeReply::Hang);
            script
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_case_whose_driver_never_answers_fails_with_its_name() {
        let outcome = run_case(
            CASE,
            FakeEngine::<NeverAnswers>::start(),
            query_bound_times_out_within_deadline_plus_cancel_grace,
        )
        .await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("did not finish")),
            "{outcome:?}"
        );
    }
}
