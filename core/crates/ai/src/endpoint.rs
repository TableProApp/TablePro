use std::net::IpAddr;

use http::Uri;
use secrecy::{ExposeSecret, SecretString};

use tablepro_core::AiProvider;

use crate::AiError;

/// Where a request goes, with what model and key.
#[derive(Clone)]
pub struct Endpoint {
    kind: AiProvider,
    base: String,
    host: String,
    model: String,
    key: Option<SecretString>,
}

impl Endpoint {
    /// `base_url` carries the version path, such as `.../v1`. An empty
    /// key counts as none.
    pub fn new(kind: AiProvider, base_url: &str, model: &str, key: Option<SecretString>) -> Result<Self, AiError> {
        let key = key.filter(|key| !key.expose_secret().trim().is_empty());
        if kind.requires_key() && key.is_none() {
            return Err(AiError::MissingKey(kind));
        }
        let base = base_url.trim().trim_end_matches('/');
        let uri: Uri = base.parse().map_err(|_| AiError::InvalidAddress)?;
        let secure = match uri.scheme_str() {
            Some("https") => true,
            Some("http") => false,
            _ => return Err(AiError::InvalidAddress),
        };
        let host = uri
            .host()
            .filter(|host| !host.is_empty())
            .ok_or(AiError::InvalidAddress)?
            .to_owned();
        if uri.query().is_some() {
            return Err(AiError::InvalidAddress);
        }
        if !secure && key.is_some() && !is_loopback(&host) {
            return Err(AiError::KeyOverPlainHttp);
        }
        Ok(Self {
            kind,
            base: base.to_owned(),
            host,
            model: model.trim().to_owned(),
            key,
        })
    }

    /// The host a base URL names, for saying where requests go before
    /// one is made.
    pub fn host_of(base_url: &str) -> Option<String> {
        let uri: Uri = base_url.trim().parse().ok()?;
        uri.host().filter(|host| !host.is_empty()).map(str::to_owned)
    }

    /// The address with its version path, as requests are joined to it.
    pub fn base_url(&self) -> &str {
        &self.base
    }

    pub fn kind(&self) -> AiProvider {
        self.kind
    }

    /// The name the requests go to, for the user to see where their data
    /// goes.
    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    pub(crate) fn key(&self) -> Option<&SecretString> {
        self.key.as_ref()
    }

    pub(crate) fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }
}

impl std::fmt::Debug for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Endpoint")
            .field("kind", &self.kind)
            .field("base", &self.base)
            .field("model", &self.model)
            .field("key", &self.key.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

fn is_loopback(host: &str) -> bool {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(address) = bare.parse::<IpAddr>() {
        return address.is_loopback();
    }
    let name = bare.trim_end_matches('.').to_ascii_lowercase();
    name == "localhost" || name.ends_with(".localhost")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Option<SecretString> {
        Some(SecretString::from("sk-test"))
    }

    #[test]
    fn a_hosted_provider_needs_a_key() {
        let error = Endpoint::new(AiProvider::Anthropic, "https://api.anthropic.com/v1", "m", None).unwrap_err();
        let blank = Endpoint::new(
            AiProvider::OpenAi,
            "https://api.openai.com/v1",
            "m",
            Some(SecretString::from("  ")),
        )
        .unwrap_err();

        assert_eq!(error, AiError::MissingKey(AiProvider::Anthropic));
        assert_eq!(blank, AiError::MissingKey(AiProvider::OpenAi));
    }

    #[test]
    fn a_key_never_goes_to_another_computer_in_the_clear() {
        let remote = Endpoint::new(AiProvider::OpenAiCompatible, "http://gpu-box:11434/v1", "m", key());
        let local = Endpoint::new(AiProvider::OpenAiCompatible, "http://localhost:11434/v1", "m", key());
        let loopback = Endpoint::new(AiProvider::OpenAiCompatible, "http://[::1]:11434/v1", "m", key());
        let keyless = Endpoint::new(AiProvider::OpenAiCompatible, "http://gpu-box:11434/v1", "m", None);

        assert_eq!(remote.unwrap_err(), AiError::KeyOverPlainHttp);
        assert!(local.is_ok());
        assert!(loopback.is_ok());
        assert!(keyless.is_ok());
    }

    #[test]
    fn only_http_and_https_addresses_are_taken() {
        for address in [
            "ftp://host/v1",
            "localhost:11434/v1",
            "",
            "http://host/v1?x=1",
            "http:///v1",
        ] {
            assert_eq!(
                Endpoint::new(AiProvider::OpenAiCompatible, address, "m", None).unwrap_err(),
                AiError::InvalidAddress,
                "{address}"
            );
        }
    }

    #[test]
    fn paths_are_joined_onto_the_address_without_a_double_slash() {
        let endpoint = Endpoint::new(
            AiProvider::OpenAiCompatible,
            " http://127.0.0.1:1234/v1/ ",
            " llama3 ",
            None,
        )
        .unwrap();

        assert_eq!(
            endpoint.url("/chat/completions"),
            "http://127.0.0.1:1234/v1/chat/completions"
        );
        assert_eq!(endpoint.host(), "127.0.0.1");
        assert_eq!(endpoint.model(), "llama3");
    }

    #[test]
    fn the_host_of_an_address_is_read_without_a_key() {
        assert_eq!(
            Endpoint::host_of("https://api.anthropic.com/v1").as_deref(),
            Some("api.anthropic.com")
        );
        assert_eq!(Endpoint::host_of("not a url"), None);
    }

    #[test]
    fn the_key_stays_out_of_debug_output() {
        let endpoint = Endpoint::new(AiProvider::Anthropic, "https://api.anthropic.com/v1", "m", key()).unwrap();

        assert!(!format!("{endpoint:?}").contains("sk-test"));
    }
}
