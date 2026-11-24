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

    // The core stopped waiting, on a cancel or the sign-in's timeout: the host closes the session it opened, so
    // `authenticate` returns and its thread is freed.
    fn cancel(&self);
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

// Tells the host to close its session when the wait is dropped before the session answered.
struct Waiting {
    host: Arc<dyn HostWebAuthenticator>,
    tasks: Tasks,
    answered: bool,
}

impl Drop for Waiting {
    fn drop(&mut self) {
        if !self.answered {
            let host = self.host.clone();
            drop(self.tasks.spawn_blocking_task(move || host.cancel()));
        }
    }
}

#[async_trait]
impl WebAuthenticator for HostWebAuthenticatorBridge {
    async fn authenticate(&self, url: &Url, callback_scheme: &str) -> Result<Url, WebAuthenticationError> {
        let host = self.host.clone();
        let (url, scheme) = (url.to_string(), callback_scheme.to_owned());
        let mut waiting = Waiting {
            host: self.host.clone(),
            tasks: self.tasks.clone(),
            answered: false,
        };
        let answered = self
            .tasks
            .spawn_blocking_task(move || host.authenticate(url, scheme))
            .await;
        waiting.answered = true;
        let answered = answered.map_err(|failure| WebAuthenticationError::Failed(failure.to_string()))?;
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

        fn cancel(&self) {}
    }

    // Holds its session open until the core cancels it, as ASWebAuthenticationSession does.
    struct OpenUntilCancelled(
        std::sync::mpsc::Sender<()>,
        Mutex<std::sync::mpsc::Receiver<()>>,
        Arc<Mutex<bool>>,
    );

    impl HostWebAuthenticator for OpenUntilCancelled {
        fn authenticate(&self, _: String, _: String) -> Result<String, HostBrowserError> {
            let _ = self.1.lock().unwrap().recv();
            Err(HostBrowserError::Cancelled)
        }

        fn cancel(&self) {
            *self.2.lock().unwrap() = true;
            let _ = self.0.send(());
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_wait_the_core_drops_closes_the_host_s_session() {
        let (sender, receiver) = std::sync::mpsc::channel();
        let cancelled = Arc::new(Mutex::new(false));
        let bridge = HostWebAuthenticatorBridge::new(
            Box::new(OpenUntilCancelled(sender, Mutex::new(receiver), cancelled.clone())),
            runtime::tasks().unwrap(),
        );
        let page = Url::parse("https://account.tablepro.app/oauth/authorize?state=s").unwrap();

        let waited = tokio::time::timeout(
            std::time::Duration::from_millis(100),
            bridge.authenticate(&page, "app.tablepro"),
        )
        .await;
        for _ in 0..100 {
            if *cancelled.lock().unwrap() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        assert!(waited.is_err());
        assert!(*cancelled.lock().unwrap());
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
