use std::time::Duration;

use progenitor_client::{ClientHooks, Error, OperationInfo};
use reqwest::StatusCode;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue, RETRY_AFTER};
use secrecy::{ExposeSecret, SecretString};

use crate::account_error::AccountError;

#[expect(
    clippy::unwrap_used,
    reason = "progenitor's client unwraps its own reqwest builder and the document's fixed patterns"
)]
pub mod v2 {
    include!(concat!(env!("OUT_DIR"), "/v2.rs"));
}

#[derive(Clone, Debug)]
pub struct Bearer(pub(crate) SecretString);

impl ClientHooks<Bearer> for v2::Client {
    async fn pre<E>(&self, request: &mut reqwest::Request, _: &OperationInfo) -> Result<(), Error<E>> {
        use progenitor_client::ClientInfo as _;
        let mut value = HeaderValue::from_str(&format!("Bearer {}", self.inner().0.expose_secret()))
            .map_err(|_| Error::InvalidRequest("the access token is not a header value".to_owned()))?;
        value.set_sensitive(true);
        request.headers_mut().insert(AUTHORIZATION, value);
        Ok(())
    }
}

pub(crate) async fn answer_error(error: Error<v2::types::Problem>) -> AccountError {
    match error {
        Error::ErrorResponse(answer) if answer.status() == StatusCode::TOO_MANY_REQUESTS => {
            rate_limited(answer.headers())
        }
        Error::UnexpectedResponse(response) if response.status() == StatusCode::TOO_MANY_REQUESTS => {
            rate_limited(response.headers())
        }
        Error::ErrorResponse(answer) => problem_error(answer.status().as_u16(), answer.into_inner()),
        // A status the document does not list, such as a proxy's.
        Error::UnexpectedResponse(response) => {
            let status = response.status().as_u16();
            let body = match response.bytes().await {
                Ok(body) => body,
                Err(error) => return AccountError::unreachable(&error),
            };
            match serde_json::from_slice::<v2::types::Problem>(&body) {
                Ok(problem) => problem_error(status, problem),
                Err(_) => AccountError::Protocol(format!("HTTP {status} without a problem")),
            }
        }
        Error::CommunicationError(error) => AccountError::unreachable(&error),
        // Its text carries the whole answer, an entitlement or the account's details among them.
        Error::InvalidResponsePayload(_, error) => AccountError::Protocol(schema_mismatch(&error)),
        other => AccountError::Protocol(other.to_string()),
    }
}

// Where the answer stopped matching, without any of its values.
pub(crate) fn schema_mismatch(error: &serde_json::Error) -> String {
    format!(
        "the answer does not match the /v2 document ({:?} at line {}, column {})",
        error.classify(),
        error.line(),
        error.column()
    )
}

// api.md, Conventions: every 429 carries Retry-After in seconds.
pub(crate) fn rate_limited(headers: &HeaderMap) -> AccountError {
    let retry_after = headers
        .get(RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_secs);
    AccountError::RateLimited { retry_after }
}

fn problem_error(status: u16, problem: v2::types::Problem) -> AccountError {
    match problem.code.as_str() {
        "device_revoked" => AccountError::DeviceRevoked,
        "device_limit_reached" => AccountError::DeviceLimitReached {
            devices: problem.devices.into_iter().map(Into::into).collect(),
        },
        _ => AccountError::Refused {
            status,
            code: problem.code,
            detail: problem.detail.unwrap_or(problem.title),
        },
    }
}

#[cfg(test)]
mod tests {
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

        let AccountError::DeviceLimitReached { devices } = refused else {
            panic!("not the device limit: {refused:?}");
        };
        assert_eq!(devices.len(), 2);
        assert_eq!(
            (devices[0].name.as_str(), devices[0].platform.as_str()),
            ("Lab", "windows")
        );
        assert!(devices[0].licensed_at.is_some());
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

        assert!(matches!(revoked, AccountError::DeviceRevoked), "{revoked:?}");
        assert!(
            matches!(&other, AccountError::Refused { status: 403, code, detail } if code == "account_locked" && detail == "Account locked"),
            "{other:?}"
        );
    }

    #[tokio::test]
    async fn an_answer_that_does_not_match_says_where_and_none_of_its_values() {
        let body = br#"{"token":"secret-entitlement-token","account":{"email":"ada@example.com"},"expires_at":5}"#;
        let error = serde_json::from_slice::<v2::types::Entitlement>(body).expect_err("a mismatch");

        let mismatch = answer_error(Error::InvalidResponsePayload(bytes::Bytes::from_static(body), error)).await;

        let text = mismatch.to_string();
        assert!(matches!(mismatch, AccountError::Protocol(_)), "{mismatch:?}");
        assert!(
            !text.contains("secret-entitlement-token") && !text.contains("ada@example.com"),
            "{text}"
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
            matches!(answer("42"), AccountError::RateLimited { retry_after: Some(wait) } if wait == Duration::from_secs(42)),
            "{:?}",
            answer("42")
        );
        assert!(matches!(
            answer("Wed, 21 Oct 2026 07:28:00 GMT"),
            AccountError::RateLimited { retry_after: None }
        ));
        assert!(matches!(
            rate_limited(&HeaderMap::new()),
            AccountError::RateLimited { retry_after: None }
        ));
    }
}
