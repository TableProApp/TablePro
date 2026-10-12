use std::sync::Arc;
use std::time::Duration;

use tablepro_core::EditorSession;

use crate::link::CloseReport;
use crate::runtime::{TaskResult, Tasks};

/// Close every editor tab's session at once, each under `close_timeout`.
///
/// Editor sessions are never closed by a link replacement: each holds
/// its own connection and transport, so the tab that owns it closes it
/// here, on disconnect or window close.
pub fn close_editor_sessions(
    sessions: Vec<Arc<dyn EditorSession>>,
    close_timeout: Duration,
    tasks: &Tasks,
) -> TaskResult<Vec<CloseReport>> {
    tasks.spawn_task(async move {
        let closes = sessions.into_iter().map(|session| async move {
            match tokio::time::timeout(close_timeout, session.close()).await {
                Ok(()) => CloseReport::Closed,
                Err(_) => CloseReport::Abandoned,
            }
        });
        futures::future::join_all(closes).await
    })
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::{CloseBehaviour, FakeEditorSession, Replies};

    use super::*;
    use crate::test_support::paused_tasks;

    #[tokio::test(start_paused = true)]
    async fn closes_each_session_once() {
        let first = Arc::new(FakeEditorSession::new(Replies::default()));
        let second = Arc::new(FakeEditorSession::with_close(
            Replies::default(),
            CloseBehaviour::Delay(Duration::from_millis(100)),
        ));
        let sessions: Vec<Arc<dyn EditorSession>> = vec![first.clone(), second.clone()];

        let reports = close_editor_sessions(sessions, Duration::from_secs(10), &paused_tasks())
            .await
            .unwrap();

        assert_eq!(reports, [CloseReport::Closed, CloseReport::Closed]);
        assert_eq!(first.close_count(), 1);
        assert_eq!(second.close_count(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn hanging_editor_close_abandoned_at_close_timeout() {
        let hanging = Arc::new(FakeEditorSession::with_close(Replies::default(), CloseBehaviour::Hang));
        let quick = Arc::new(FakeEditorSession::new(Replies::default()));
        let started = tokio::time::Instant::now();

        let reports = close_editor_sessions(
            vec![hanging.clone(), quick.clone()],
            Duration::from_secs(10),
            &paused_tasks(),
        )
        .await
        .unwrap();

        assert_eq!(reports, [CloseReport::Abandoned, CloseReport::Closed]);
        assert_eq!(started.elapsed(), Duration::from_secs(10));
        assert_eq!(quick.close_count(), 1);
    }
}
