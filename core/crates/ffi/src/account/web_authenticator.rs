use std::sync::Arc;

use async_trait::async_trait;
use tablepro_account::{Url, WebAuthenticationError, WebAuthenticator};
use tablepro_session::runtime::Tasks;

use super::host_browser::HostBrowserError;

// The Mac shows the sign-in page in ASWebAuthenticationSession and returns the URL the server redirected to with
// `callback_scheme`; a person who closes the sheet ends it with `Cancelled`. The core calls it on a thread it lets
// block, for as long as the page is open.
#[uniffi::export(callback_interface)]
pub trait HostWebAuthenticator: Send + Sync {
    fn authenticate(&self, url: String, callback_scheme: String) -> Result<String, HostBrowserError>;
}

pub(crate) struct HostWebAuthenticatorBridge {
    host: Arc<dyn HostWebAuthenticator>,
    tasks: Tasks,
}

impl HostWebAuthenticatorBridge {
    pub(crate) fn new(host: Box<dyn HostWebAuthenticator>, tasks: Tasks) -> Self {
        Self {
            host: Arc::from(host),
            tasks,
        }
    }
}

impl std::fmt::Debug for HostWebAuthenticatorBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostWebAuthenticatorBridge").finish_non_exhaustive()
    }
}

#[async_trait]
impl WebAuthenticator for HostWebAuthenticatorBridge {
    async fn authenticate(&self, url: &Url, callback_scheme: &str) -> Result<Url, WebAuthenticationError> {
        let host = self.host.clone();
        let (url, scheme) = (url.to_string(), callback_scheme.to_owned());
        let answered = self
            .tasks
            .spawn_blocking_task(move || host.authenticate(url, scheme))
            .await
            .map_err(|failure| WebAuthenticationError::Failed(failure.to_string()))?;
        match answered {
            Ok(callback) => Url::parse(&callback)
                .map_err(|_| WebAuthenticationError::Failed("the callback is not a URL".to_owned())),
            Err(HostBrowserError::Cancelled) => Err(WebAuthenticationError::Canceled),
            Err(error @ HostBrowserError::Failed { .. }) => Err(WebAuthenticationError::Failed(error.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::runtime;

    // Each page and scheme the host was given.
    type Asked = Arc<Mutex<Vec<(String, String)>>>;

    struct Answering(Result<String, HostBrowserError>, Asked);

    impl HostWebAuthenticator for Answering {
        fn authenticate(&self, url: String, callback_scheme: String) -> Result<String, HostBrowserError> {
            self.1.lock().unwrap().push((url, callback_scheme));
            self.0.clone()
        }
    }

    fn bridge(answer: Result<String, HostBrowserError>) -> (HostWebAuthenticatorBridge, Asked) {
        let asked = Arc::default();
        let bridge = HostWebAuthenticatorBridge::new(
            Box::new(Answering(answer, Arc::clone(&asked))),
            runtime::tasks().unwrap(),
        );
        (bridge, asked)
    }

    #[tokio::test]
    async fn the_host_is_given_the_page_and_scheme_and_its_answer_comes_back_as_the_account_reads_it() {
        let page = Url::parse("https://account.tablepro.app/oauth/authorize?state=s").unwrap();
        let (approved, asked) = bridge(Ok("app.tablepro:/oauth/callback?code=c&state=s".to_owned()));

        let callback = approved.authenticate(&page, "app.tablepro").await.unwrap();
        let cancelled = bridge(Err(HostBrowserError::Cancelled))
            .0
            .authenticate(&page, "app.tablepro")
            .await;
        let failed = bridge(Err(HostBrowserError::Failed {
            detail: "no window".to_owned(),
        }))
        .0
        .authenticate(&page, "app.tablepro")
        .await;
        let garbled = bridge(Ok("not a url".to_owned()))
            .0
            .authenticate(&page, "app.tablepro")
            .await;

        assert_eq!(callback.as_str(), "app.tablepro:/oauth/callback?code=c&state=s");
        assert_eq!(*asked.lock().unwrap(), [(page.to_string(), "app.tablepro".to_owned())]);
        assert_eq!(cancelled, Err(WebAuthenticationError::Canceled));
        assert!(matches!(failed, Err(WebAuthenticationError::Failed(detail)) if detail.contains("no window")));
        assert!(matches!(garbled, Err(WebAuthenticationError::Failed(_))));
    }
}
