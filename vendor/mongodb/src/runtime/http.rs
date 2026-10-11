// Suppress noisy warnings when a method is not used under a certain feature flag.
#![allow(unused)]

use reqwest::{IntoUrl, Method, Response};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

use crate::error::{Error, Result};

#[derive(Clone, Debug, Default)]
pub(crate) struct HttpClient {
    inner: reqwest::Client,
}

pub(crate) struct HttpRequest {
    inner: reqwest::RequestBuilder,
}

impl From<reqwest::RequestBuilder> for HttpRequest {
    fn from(value: reqwest::RequestBuilder) -> Self {
        Self { inner: value }
    }
}

impl HttpRequest {
    /// Sets the headers for the request.
    pub(crate) fn headers<'a>(
        self,
        headers: impl IntoIterator<Item = &'a (&'a str, &'a str)>,
    ) -> Self {
        headers
            .into_iter()
            .fold(self.inner, |request, (k, v)| request.header(*k, *v))
            .into()
    }

    /// Sets the query for the request. The query can be any value with key-value pairs that
    /// implements Serialize.
    pub(crate) fn query(self, query: impl Serialize) -> Self {
        self.inner.query(&query).into()
    }

    /// Sends the request via the HttpClient it was created from and returns the result as the given
    /// type T.
    pub(crate) async fn send<T: DeserializeOwned>(self) -> reqwest::Result<T> {
        self.inner.send().await?.json().await
    }

    /// Sends the request via the HttpClient it was created from and returns the result as a string.
    pub(crate) async fn send_and_get_string(self) -> reqwest::Result<String> {
        self.inner.send().await?.text().await
    }
}

impl HttpClient {
    pub(crate) fn with_timeout(timeout: std::time::Duration) -> Result<Self> {
        let inner = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .map_err(|e| Error::internal(format!("error initializing http client: {e}")))?;
        Ok(Self { inner })
    }

    /// Creates an HTTP get request. One of the send methods defined on HttpRequest must be called
    /// for the request to be executed.
    pub(crate) fn get(&self, uri: impl IntoUrl) -> HttpRequest {
        self.inner.request(Method::GET, uri).into()
    }

    /// Creates an HTTP put request. One of the send methods defined on HttpRequest must be called
    /// for the request to be executed.
    pub(crate) fn put(&self, uri: impl IntoUrl) -> HttpRequest {
        self.inner.request(Method::PUT, uri).into()
    }
}
