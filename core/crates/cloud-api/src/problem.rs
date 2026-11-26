use std::time::Duration;

use progenitor_client::Error;
use reqwest::StatusCode;
use reqwest::header::{HeaderMap, RETRY_AFTER};

use crate::api_error::{ApiError, http_text};
use crate::challenge::{StepUpChallenge, dpop_nonce_challenge};
use crate::http::read_capped;
use crate::v2;

pub async fn answer_error(error: Error<v2::types::Problem>) -> ApiError {
    if let Some(challenged) = challenged(&error) {
        return challenged;
    }
    match error {
        Error::ErrorResponse(answer) if answer.status() == StatusCode::TOO_MANY_REQUESTS => {
            rate_limited(answer.headers())
        }
        Error::UnexpectedResponse(response) if response.status() == StatusCode::TOO_MANY_REQUESTS => {
            rate_limited(response.headers())
        }
        Error::ErrorResponse(answer) if answer.status() == StatusCode::PAYLOAD_TOO_LARGE => ApiError::TooLarge,
        Error::UnexpectedResponse(response) if response.status() == StatusCode::PAYLOAD_TOO_LARGE => ApiError::TooLarge,
        Error::ErrorResponse(answer) => problem_error(answer.status().as_u16(), answer.into_inner()),
        // A status the document does not list, such as a proxy's.
        Error::UnexpectedResponse(response) => {
            let status = response.status().as_u16();
            let body = match read_capped(response, PROBLEM_LIMIT).await {
                Ok(body) => body,
                Err(error) => return error,
            };
            match serde_json::from_slice::<v2::types::Problem>(&body) {
                Ok(problem) => problem_error(status, problem),
                Err(_) => ApiError::Protocol(format!("HTTP {status} without a problem")),
            }
        }
        Error::CommunicationError(error) | Error::ResponseBodyError(error) => ApiError::unreachable(error),
        Error::InvalidUpgrade(error) => ApiError::Protocol(http_text(error)),
        // Its text carries the whole answer, an entitlement or the account's details among them.
        Error::InvalidResponsePayload(_, error) => ApiError::Protocol(schema_mismatch(&error)),
        other => ApiError::Protocol(other.to_string()),
    }
}

// A 401 whose challenge asks for something the caller can give, whatever problem code the body names: a step-up
// (RFC 9470 section 3) or a DPoP proof with the server's nonce (RFC 9449 section 9).
fn challenged(error: &Error<v2::types::Problem>) -> Option<ApiError> {
    let (status, headers) = match error {
        Error::ErrorResponse(answer) => (answer.status(), answer.headers()),
        Error::UnexpectedResponse(response) => (response.status(), response.headers()),
        _ => return None,
    };
    if status != StatusCode::UNAUTHORIZED {
        return None;
    }
    StepUpChallenge::from_headers(headers)
        .map(ApiError::StepUpRequired)
        .or_else(|| dpop_nonce_challenge(headers).map(|nonce| ApiError::UseDpopNonce { nonce }))
}

const LONGEST_RETRY_AFTER: Duration = Duration::from_secs(24 * 60 * 60);
// A problem is a few hundred bytes; a proxy's page is cut off rather than read whole.
const PROBLEM_LIMIT: usize = 64 * 1024;

// Where the answer stopped matching, without any of its values.
pub fn schema_mismatch(error: &serde_json::Error) -> String {
    format!(
        "the answer does not match the /v2 document ({:?} at line {}, column {})",
        error.classify(),
        error.line(),
        error.column()
    )
}

// api.md, Conventions: every 429 carries Retry-After in seconds. A wait past a day is read as a day, so no server can
// push a deadline past what the clocks hold.
pub fn rate_limited(headers: &HeaderMap) -> ApiError {
    let retry_after = headers
        .get(RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(|seconds| Duration::from_secs(seconds).min(LONGEST_RETRY_AFTER));
    ApiError::RateLimited { retry_after }
}

// A refusal read by hand, for a call the generated client does not make.
pub fn refusal(status: u16, body: &[u8]) -> ApiError {
    match serde_json::from_slice::<v2::types::Problem>(body) {
        Ok(problem) => problem_error(status, problem),
        Err(_) => ApiError::Protocol(format!("HTTP {status} without a problem")),
    }
}

fn problem_error(status: u16, problem: v2::types::Problem) -> ApiError {
    match problem.code.as_str() {
        "device_revoked" => ApiError::DeviceRevoked,
        "device_limit_reached" => ApiError::DeviceLimitReached {
            devices: problem.devices,
        },
        _ => ApiError::Refused {
            status,
            code: problem.code,
            detail: problem.detail.unwrap_or(problem.title),
        },
    }
}

#[cfg(test)]
mod tests {
    use reqwest::header::HeaderValue;

    use super::*;

    fn problem(json: &str) -> v2::types::Problem {
        serde_json::from_str(json).expect("a problem")
    }

    #[test]
    fn the_device_limit_names_the_devices_that_hold_the_license() {
        let refused = problem_error(
            409,
            problem(
                r#"{"type":"https://tablepro.app/problems/device_limit_reached","title":"Device limit reached",
                "status":409,"code":"device_limit_reached","devices":[{"id":"dev_01","machine_id":"0000000000000000000000000000000000000000000000000000000000000000",
                "platform":"windows","name":"Lab","app_version":"2.0.0","os_version":"11","created_at":"2026-10-01T08:00:00Z",
                "last_seen_at":"2026-10-28T08:00:00Z","licensed_at":"2026-10-01T08:00:00Z"},
                {"id":"dev_02","machine_id":"1111111111111111111111111111111111111111111111111111111111111111",
                "platform":"linux","name":"Kiosk","app_version":"0.1.0","os_version":"Ubuntu 26.04","created_at":"2026-10-02T08:00:00Z",
                "last_seen_at":"2026-10-02T08:00:00Z","licensed_at":"2026-10-02T08:00:00Z","offline_until":"2027-10-02T09:00:00Z"}]}"#,
            ),
        );

        let ApiError::DeviceLimitReached { devices } = refused else {
            panic!("not the device limit: {refused:?}");
        };
        assert_eq!(devices.len(), 2);
        assert_eq!(
            (devices[0].name.as_str(), devices[0].platform.as_str()),
            ("Lab", "windows")
        );
        assert_eq!(devices[0].licensed_at.to_rfc3339(), "2026-10-01T08:00:00+00:00");
        assert_eq!(devices[0].offline_until, None);
        assert_eq!(
            devices[1].offline_until.map(|until| until.to_rfc3339()).as_deref(),
            Some("2027-10-02T09:00:00+00:00")
        );
    }

    #[test]
    fn a_removed_device_and_any_other_code_read_from_the_problem() {
        let revoked = problem_error(
            403,
            problem(r#"{"type":"about:blank","title":"Device revoked","status":403,"code":"device_revoked"}"#),
        );
        let other = problem_error(
            403,
            problem(
                r#"{"type":"about:blank","title":"Account locked","status":403,"code":"account_locked","extra":1}"#,
            ),
        );

        assert!(matches!(revoked, ApiError::DeviceRevoked), "{revoked:?}");
        assert!(
            matches!(&other, ApiError::Refused { status: 403, code, detail } if code == "account_locked" && detail == "Account locked"),
            "{other:?}"
        );
    }

    #[tokio::test]
    async fn an_answer_that_does_not_match_says_where_and_none_of_its_values() {
        let body = br#"{"token":"secret-entitlement-token","account":{"email":"ada@example.com"},"expires_at":5}"#;
        let error = serde_json::from_slice::<v2::types::Entitlement>(body).expect_err("a mismatch");

        let mismatch = answer_error(Error::InvalidResponsePayload(bytes::Bytes::from_static(body), error)).await;

        let text = mismatch.to_string();
        assert!(matches!(mismatch, ApiError::Protocol(_)), "{mismatch:?}");
        assert!(
            !text.contains("secret-entitlement-token") && !text.contains("ada@example.com"),
            "{text}"
        );
    }

    async fn answered_401(challenge: Option<&'static str>, code: &str) -> ApiError {
        let mut page = http::Response::builder().status(401);
        if let Some(challenge) = challenge {
            page = page.header(reqwest::header::WWW_AUTHENTICATE, challenge);
        }
        let body = format!(r#"{{"type":"about:blank","title":"Unauthorized","status":401,"code":"{code}"}}"#);
        let response = reqwest::Response::from(page.body(body).expect("an answer"));
        let answer = v2::ResponseValue::<v2::types::Problem>::from_response::<()>(response)
            .await
            .expect("a problem");
        answer_error(Error::ErrorResponse(answer)).await
    }

    #[tokio::test]
    async fn a_401_with_rfc_9470_s_challenge_is_a_step_up_and_any_other_401_a_refusal() {
        let step_up = answered_401(
            Some(r#"Bearer error="insufficient_user_authentication", acr_values="urn:tablepro:acr:passkey", max_age=300"#),
            "step_up_required",
        )
        .await;
        let expired = answered_401(Some(r#"Bearer error="invalid_token""#), "unauthorized").await;
        let bare = answered_401(None, "step_up_required").await;

        assert!(
            matches!(&step_up, ApiError::StepUpRequired(challenge)
                if challenge.acr_values == ["urn:tablepro:acr:passkey"] && challenge.max_age_secs == Some(300)),
            "{step_up:?}"
        );
        assert!(
            matches!(&expired, ApiError::Refused { status: 401, code, .. } if code == "unauthorized"),
            "{expired:?}"
        );
        assert!(
            matches!(&bare, ApiError::Refused { status: 401, code, .. } if code == "step_up_required"),
            "{bare:?}"
        );
    }

    #[tokio::test]
    async fn a_401_asking_for_the_dpop_nonce_keeps_the_nonce_for_the_retry() {
        let page = http::Response::builder()
            .status(401)
            .header(reqwest::header::WWW_AUTHENTICATE, r#"DPoP error="use_dpop_nonce""#)
            .header("dpop-nonce", "n-2")
            .body(r#"{"type":"about:blank","title":"Use dpop nonce","status":401,"code":"use_dpop_nonce"}"#)
            .expect("an answer");
        let response = reqwest::Response::from(page);
        let answer = v2::ResponseValue::<v2::types::Problem>::from_response::<()>(response)
            .await
            .expect("a problem");

        let answered = answer_error(Error::ErrorResponse(answer)).await;

        assert!(
            matches!(&answered, ApiError::UseDpopNonce { nonce } if nonce == "n-2"),
            "{answered:?}"
        );
    }

    #[tokio::test]
    async fn a_challenge_on_another_status_is_not_a_step_up() {
        let page = http::Response::builder()
            .status(403)
            .header(
                reqwest::header::WWW_AUTHENTICATE,
                r#"Bearer error="insufficient_user_authentication", max_age=5"#,
            )
            .body(r#"{"type":"about:blank","title":"Forbidden","status":403,"code":"forbidden"}"#)
            .expect("an answer");

        let answered = answer_error(Error::UnexpectedResponse(reqwest::Response::from(page))).await;

        assert!(
            matches!(&answered, ApiError::Refused { status: 403, code, .. } if code == "forbidden"),
            "{answered:?}"
        );
    }

    #[tokio::test]
    async fn a_413_with_no_problem_of_the_server_s_is_too_large() {
        let page = http::Response::builder()
            .status(413)
            .body("<html>Request Entity Too Large</html>")
            .expect("an answer");

        let answered = answer_error(Error::UnexpectedResponse(reqwest::Response::from(page))).await;

        assert!(matches!(answered, ApiError::TooLarge), "{answered:?}");
    }

    #[test]
    fn a_retry_after_past_a_day_is_read_as_a_day() {
        let mut headers = HeaderMap::new();
        headers.insert(RETRY_AFTER, HeaderValue::from_static("18446744073709551615"));

        let limited = rate_limited(&headers);

        assert!(
            matches!(limited, ApiError::RateLimited { retry_after: Some(wait) } if wait == LONGEST_RETRY_AFTER),
            "{limited:?}"
        );
    }

    #[test]
    fn a_429_keeps_its_retry_after_in_seconds() {
        let answer = |value: &str| {
            let mut headers = HeaderMap::new();
            headers.insert(RETRY_AFTER, HeaderValue::from_str(value).expect("a header value"));
            rate_limited(&headers)
        };

        assert!(
            matches!(answer("42"), ApiError::RateLimited { retry_after: Some(wait) } if wait == Duration::from_secs(42)),
            "{:?}",
            answer("42")
        );
        assert!(matches!(
            answer("Wed, 21 Oct 2026 07:28:00 GMT"),
            ApiError::RateLimited { retry_after: None }
        ));
        assert!(matches!(
            rate_limited(&HeaderMap::new()),
            ApiError::RateLimited { retry_after: None }
        ));
    }
}
