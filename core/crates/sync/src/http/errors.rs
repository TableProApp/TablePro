// A refused call as 0051's whole-request refusals name it, from the answer's status, headers and problem.

use reqwest::StatusCode;
use reqwest::header::{HeaderMap, RETRY_AFTER};

use crate::api::transport::{StepUpChallenge, TransportError};

// 0051, Step-up: the app steps up with `max_age=300`, so a challenge that names no age asks for that one.
const STEP_UP_MAX_AGE_SECS: u64 = 300;
// A server cannot hold sync off past a day, whatever its `Retry-After` says.
const LONGEST_RETRY_AFTER_MS: u64 = 24 * 60 * 60 * 1_000;

pub(super) fn step_up(challenge: tablepro_cloud_api::StepUpChallenge) -> TransportError {
    TransportError::StepUpRequired(StepUpChallenge {
        acr_values: challenge.acr_values,
        max_age_secs: challenge.max_age_secs.unwrap_or(STEP_UP_MAX_AGE_SECS),
    })
}

pub(super) fn retry_after_ms(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(|seconds| seconds.saturating_mul(1_000).min(LONGEST_RETRY_AFTER_MS))
}

pub(super) fn malformed(status: StatusCode) -> TransportError {
    TransportError::Server {
        status: status.as_u16(),
        code: "malformed_answer".to_owned(),
        retry_after_ms: None,
    }
}

// Only the code decides the error, so a problem that leaves out another member still names it.
#[derive(serde::Deserialize)]
struct ProblemCode {
    code: String,
}

// Every status but a 401, which the call's own retries settle first.
pub(super) fn refusal(status: StatusCode, headers: &HeaderMap, body: &[u8]) -> TransportError {
    let retry_after_ms = retry_after_ms(headers);
    let code = serde_json::from_slice::<ProblemCode>(body)
        .ok()
        .map(|problem| problem.code);
    if status == StatusCode::TOO_MANY_REQUESTS {
        return TransportError::RateLimited { retry_after_ms };
    }
    match code.as_deref() {
        Some("feature_required") => TransportError::FeatureRequired,
        Some("seat_required") => TransportError::SeatRequired,
        Some("license_expired") => TransportError::LicenseExpired,
        Some("device_removed" | "device_revoked") => TransportError::DeviceRemoved,
        Some("device_not_approved") => TransportError::DeviceNotApproved,
        Some("interactive_sign_in_required") => TransportError::InteractiveSignInRequired,
        Some("not_found") => TransportError::NotFound,
        Some("idempotency_in_progress") => TransportError::IdempotencyInProgress,
        Some("validation_failed") => TransportError::ValidationFailed,
        Some("cursor_expired") => TransportError::CursorExpired,
        Some("epoch_changed") => TransportError::EpochChanged,
        Some("idempotency_mismatch") => TransportError::IdempotencyMismatch,
        Some("restore_check_unavailable") => TransportError::RestoreCheckUnavailable { retry_after_ms },
        Some(code) => TransportError::Server {
            status: status.as_u16(),
            code: code.to_owned(),
            retry_after_ms,
        },
        // A proxy's answer, which carries no problem of the server's.
        None => TransportError::Server {
            status: status.as_u16(),
            code: format!("http_{}", status.as_u16()),
            retry_after_ms,
        },
    }
}

#[cfg(test)]
mod tests {
    use reqwest::header::HeaderValue;

    use super::*;

    fn problem(status: u16, code: &str) -> Vec<u8> {
        format!(r#"{{"type":"about:blank","title":"Refused","status":{status},"code":"{code}"}}"#).into_bytes()
    }

    #[test]
    fn each_whole_request_refusal_reads_as_its_own_error() {
        let none = HeaderMap::new();
        let mut later = HeaderMap::new();
        later.insert(RETRY_AFTER, HeaderValue::from_static("30"));

        let cases = [
            (403, "device_removed", TransportError::DeviceRemoved),
            (403, "seat_required", TransportError::SeatRequired),
            (403, "device_not_approved", TransportError::DeviceNotApproved),
            (404, "not_found", TransportError::NotFound),
            (409, "idempotency_in_progress", TransportError::IdempotencyInProgress),
            (422, "cursor_expired", TransportError::CursorExpired),
            (422, "epoch_changed", TransportError::EpochChanged),
            (422, "idempotency_mismatch", TransportError::IdempotencyMismatch),
        ];
        for (status, code, expected) in cases {
            let status = StatusCode::from_u16(status).unwrap();
            assert_eq!(
                refusal(status, &none, &problem(status.as_u16(), code)),
                expected,
                "{code}"
            );
        }
        assert_eq!(
            refusal(StatusCode::TOO_MANY_REQUESTS, &later, &problem(429, "rate_limited")),
            TransportError::RateLimited {
                retry_after_ms: Some(30_000)
            }
        );
        assert_eq!(
            refusal(
                StatusCode::SERVICE_UNAVAILABLE,
                &later,
                &problem(503, "restore_check_unavailable")
            ),
            TransportError::RestoreCheckUnavailable {
                retry_after_ms: Some(30_000)
            }
        );
        assert_eq!(
            refusal(StatusCode::BAD_GATEWAY, &none, b"<html>"),
            TransportError::Server {
                status: 502,
                code: "http_502".to_owned(),
                retry_after_ms: None
            }
        );
    }
}
