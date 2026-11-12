use async_trait::async_trait;
use url::Url;

// The crate has no GUI: the app opens the page, with GTK's UriLauncher.
#[async_trait]
pub trait BrowserLauncher: Send + Sync {
    async fn open(&self, url: &Url) -> Result<(), String>;
}
