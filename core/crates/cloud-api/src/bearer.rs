use std::time::Duration;

use progenitor_client::{ClientHooks, Error, OperationInfo};
use reqwest::header::{AUTHORIZATION, HeaderValue};
use secrecy::{ExposeSecret, SecretString};

use crate::v2;

// What each request of a client carries: the access token, none for a public call such as reading a shared link,
// and a timeout of its own: longer than the client's for an upload, shorter for a small answer.
#[derive(Clone, Debug)]
pub struct Bearer {
    token: Option<SecretString>,
    timeout: Option<Duration>,
}

impl Bearer {
    pub fn token(token: SecretString) -> Self {
        Self {
            token: Some(token),
            timeout: None,
        }
    }

    pub fn public() -> Self {
        Self {
            token: None,
            timeout: None,
        }
    }

    pub fn lasting(self, timeout: Duration) -> Self {
        Self {
            timeout: Some(timeout),
            ..self
        }
    }
}

impl ClientHooks<Bearer> for v2::Client {
    async fn pre<E>(&self, request: &mut reqwest::Request, _: &OperationInfo) -> Result<(), Error<E>> {
        use progenitor_client::ClientInfo as _;
        if let Some(timeout) = self.inner().timeout {
            *request.timeout_mut() = Some(timeout);
        }
        let Some(token) = &self.inner().token else {
            return Ok(());
        };
        let mut value = HeaderValue::from_str(&format!("Bearer {}", token.expose_secret()))
            .map_err(|_| Error::InvalidRequest("the access token is not a header value".to_owned()))?;
        value.set_sensitive(true);
        request.headers_mut().insert(AUTHORIZATION, value);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_request_s_own_timeout_overrides_the_client_s() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}/v2", listener.local_addr().expect("its address"));
        // Takes the request and never answers it.
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::sleep(Duration::from_secs(3));
                drop(stream);
            }
        });
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("a client");
        let api = v2::Client::new_with_client(&base, http, Bearer::public().lasting(Duration::from_millis(200)));
        let started = std::time::Instant::now();

        let sent = api
            .get_shared("Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK", None)
            .await;

        assert!(
            matches!(&sent, Err(Error::CommunicationError(error)) if error.is_timeout()),
            "{sent:?}"
        );
        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    }
}
