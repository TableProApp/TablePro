use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

/// Whether the workspace's link to the server is still there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinkState {
    Live,
    Lost,
}

/// A link's liveness, shared by everything that runs on it.
///
/// A lost link is not an event each caller discovers on its own: the
/// first call to notice tells the rest, so a window full of tabs shows
/// one disconnection rather than one per tab as each times out.
#[derive(Debug, Clone, Default)]
pub struct LinkWatch {
    lost: CancellationToken,
}

impl LinkWatch {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn mark_lost(&self) {
        self.lost.cancel();
    }

    pub fn state(&self) -> LinkState {
        if self.lost.is_cancelled() {
            LinkState::Lost
        } else {
            LinkState::Live
        }
    }

    /// Resolves once the link is gone. The future owns its share of
    /// the watch, so a monitor can hold it without borrowing the
    /// connection.
    pub fn lost(&self) -> WaitForCancellationFutureOwned {
        self.lost.clone().cancelled_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn everything_sharing_a_link_learns_it_is_gone() {
        let watch = LinkWatch::new();
        let elsewhere = watch.clone();
        assert_eq!(elsewhere.state(), LinkState::Live);

        watch.mark_lost();

        assert_eq!(elsewhere.state(), LinkState::Lost);
        elsewhere.lost().await;
    }

    #[tokio::test]
    async fn mark_lost_resolves_lost_future() {
        let watch = LinkWatch::new();
        let lost = watch.lost();
        let waiter = tokio::spawn(lost);

        watch.mark_lost();
        drop(watch);

        assert!(waiter.await.is_ok(), "the lost future did not resolve");
    }

    #[test]
    fn marking_a_lost_link_again_changes_nothing() {
        let watch = LinkWatch::new();
        watch.mark_lost();
        watch.mark_lost();

        assert_eq!(watch.state(), LinkState::Lost);
    }
}
