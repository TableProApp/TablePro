use std::time::Duration;

use crate::api_error::{ApiError, http_text};

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

// The one client every call to a TablePro server goes through. Redirects stay off so a token never follows one to
// another host. Reads the system's certificates, so it belongs off the UI thread.
pub fn http_client(app_version: &str, system: &str) -> Result<reqwest::Client, ApiError> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(format!("TablePro/{app_version} ({system})"))
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|error| ApiError::Protocol(http_text(error)))
}

// A body past the limit is refused before it is all read.
pub async fn read_capped(mut response: reqwest::Response, limit: usize) -> Result<Vec<u8>, ApiError> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(ApiError::unreachable)? {
        if body.len() + chunk.len() > limit {
            return Err(ApiError::Protocol(format!("the answer is larger than {limit} bytes")));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}
