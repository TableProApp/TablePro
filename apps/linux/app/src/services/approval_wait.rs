use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

tokio::task_local! {
    static WAITED_MICROS: AtomicU64;
}

pub async fn track<F: Future>(work: F) -> F::Output {
    WAITED_MICROS.scope(AtomicU64::new(0), work).await
}

pub fn waited() -> Duration {
    WAITED_MICROS
        .try_with(|micros| Duration::from_micros(micros.load(Ordering::Relaxed)))
        .unwrap_or_default()
}

pub async fn measure<F: Future>(approval: F) -> F::Output {
    let started = Instant::now();
    let outcome = approval.await;
    let spent = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
    let _ = WAITED_MICROS.try_with(|micros| micros.fetch_add(spent, Ordering::Relaxed));
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn time_spent_in_approval_is_reported_inside_a_tracked_run() {
        let waited_inside = track(async {
            measure(tokio::time::sleep(Duration::from_millis(30))).await;
            measure(tokio::time::sleep(Duration::from_millis(30))).await;
            waited()
        })
        .await;
        assert!(waited_inside >= Duration::from_millis(60), "{waited_inside:?}");
    }

    #[tokio::test]
    async fn an_untracked_run_reports_no_wait_and_still_returns_the_outcome() {
        let value = measure(async { 7 }).await;
        assert_eq!(value, 7);
        assert_eq!(waited(), Duration::ZERO);
    }

    #[tokio::test]
    async fn separate_tracked_runs_do_not_share_a_total() {
        let first = track(async {
            measure(tokio::time::sleep(Duration::from_millis(20))).await;
            waited()
        });
        let second = track(async { waited() });
        let (first, second) = tokio::join!(first, second);
        assert!(first >= Duration::from_millis(20));
        assert_eq!(second, Duration::ZERO);
    }
}
