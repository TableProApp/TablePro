use async_trait::async_trait;
use url::Url;

// The crate has no GUI: the app opens the page, with GTK's UriLauncher.
#[async_trait]
pub trait BrowserLauncher: Send + Sync {
    async fn open(&self, url: &Url) -> Result<(), String>;
}

// For a client whose redirect is a custom scheme, the app shows the page in its platform's web authentication session
// (ASWebAuthenticationSession on the Mac) and returns the URL the server redirected to.
#[async_trait]
pub trait WebAuthenticator: Send + Sync {
    async fn authenticate(&self, url: &Url, callback_scheme: &str) -> Result<Url, WebAuthenticationError>;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WebAuthenticationError {
    #[error("the sign-in was canceled")]
    Canceled,
    #[error("the sign-in page did not open: {0}")]
    Failed(String),
}
