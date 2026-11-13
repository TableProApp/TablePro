use std::sync::Arc;

use async_trait::async_trait;
use tablepro_account::{BrowserLauncher, Url};
use tablepro_session::runtime::Tasks;

// The app opens the sign-in page in the user's browser. The core calls it on a thread it lets block. Not `open`:
// UniFFI's Swift generator escapes that name in the C header too, which then does not compile.
#[uniffi::export(callback_interface)]
pub trait HostBrowser: Send + Sync {
    fn open_url(&self, url: String) -> Result<(), HostBrowserError>;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum HostBrowserError {
    #[error("the browser did not open: {detail}")]
    Failed { detail: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for HostBrowserError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { detail: error.reason }
    }
}

pub(crate) struct HostBrowserBridge {
    host: Arc<dyn HostBrowser>,
    tasks: Tasks,
}

impl HostBrowserBridge {
    pub(crate) fn new(host: Box<dyn HostBrowser>, tasks: Tasks) -> Self {
        Self {
            host: Arc::from(host),
            tasks,
        }
    }
}

impl std::fmt::Debug for HostBrowserBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostBrowserBridge").finish_non_exhaustive()
    }
}

#[async_trait]
impl BrowserLauncher for HostBrowserBridge {
    async fn open(&self, url: &Url) -> Result<(), String> {
        let host = self.host.clone();
        let url = url.to_string();
        match self.tasks.spawn_blocking_task(move || host.open_url(url)).await {
            Ok(opened) => opened.map_err(|error| error.to_string()),
            Err(failure) => Err(failure.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::runtime;

    #[derive(Default)]
    struct Recording(Arc<Mutex<Vec<String>>>);

    impl HostBrowser for Recording {
        fn open_url(&self, url: String) -> Result<(), HostBrowserError> {
            self.0.lock().unwrap().push(url);
            Ok(())
        }
    }

    struct Refusing;

    impl HostBrowser for Refusing {
        fn open_url(&self, _: String) -> Result<(), HostBrowserError> {
            Err(HostBrowserError::Failed {
                detail: "no default browser".to_owned(),
            })
        }
    }

    struct Throwing;

    impl HostBrowser for Throwing {
        fn open_url(&self, _: String) -> Result<(), HostBrowserError> {
            panic!("the app's callback threw");
        }
    }

    fn bridge(host: impl HostBrowser + 'static) -> HostBrowserBridge {
        HostBrowserBridge::new(Box::new(host), runtime::tasks().unwrap())
    }

    #[tokio::test]
    async fn the_app_is_given_the_whole_url() {
        let opened = Arc::new(Mutex::new(Vec::new()));
        let url = Url::parse("https://account.tablepro.app/oauth/authorize?state=a%20b&client_id=x").unwrap();

        bridge(Recording(opened.clone())).open(&url).await.unwrap();

        assert_eq!(*opened.lock().unwrap(), [url.to_string()]);
    }

    #[tokio::test]
    async fn a_refusal_or_a_throw_reaches_the_account_as_its_text() {
        let url = Url::parse("https://account.tablepro.app/").unwrap();

        let refused = bridge(Refusing).open(&url).await.unwrap_err();
        let thrown = bridge(Throwing).open(&url).await;

        assert!(refused.contains("no default browser"), "{refused}");
        assert!(thrown.is_err());
    }
}
