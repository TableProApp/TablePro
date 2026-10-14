use std::time::Duration;

use tablepro_core::DriverError;
use tablepro_session::OperationError;

/// Why a count gave no total. A count stopped at its deadline names the
/// deadline it ran into, which the policy sets, not the driver.
pub(crate) fn count_failure_text(error: &OperationError, count_deadline: Option<Duration>) -> String {
    match (error, count_deadline) {
        (OperationError::Driver(DriverError::Timeout { .. }), Some(deadline)) => {
            let seconds = deadline.as_secs();
            crate::i18n::ngettext_f(
                "Counting took longer than {seconds} second and was stopped.",
                "Counting took longer than {seconds} seconds and was stopped.",
                u32::try_from(seconds).unwrap_or(u32::MAX),
                &[("seconds", &seconds.to_string())],
            )
        }
        _ => crate::ui::error_text::operation_error_message(error),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{LossPhase, TimeoutPhase};

    use super::*;

    fn timed_out() -> OperationError {
        OperationError::Driver(DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        })
    }

    #[test]
    fn count_failure_text_uses_policy_deadline() {
        assert_eq!(
            count_failure_text(&timed_out(), Some(Duration::from_secs(45))),
            "Counting took longer than 45 seconds and was stopped."
        );
        assert_eq!(
            count_failure_text(&timed_out(), Some(Duration::from_secs(1))),
            "Counting took longer than 1 second and was stopped."
        );
    }

    #[test]
    fn other_count_failures_say_what_kind_of_problem_it_was() {
        let lost = OperationError::Driver(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        });

        assert_eq!(
            count_failure_text(&lost, Some(Duration::from_secs(45))),
            "The connection was closed. Try reconnecting."
        );
        assert_eq!(
            count_failure_text(&timed_out(), None),
            "The statement ran past its time limit, so the server stopped it."
        );
    }
}
