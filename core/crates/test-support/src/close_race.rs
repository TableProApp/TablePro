use std::sync::{Arc, Barrier};
use std::thread;

use futures::FutureExt;
use futures::future::BoxFuture;

/// Enough rounds that two closes land inside each other's check at
/// least once when the check is not atomic.
pub(crate) const ROUNDS: usize = 2_000;

/// Per round, how many of two closes started on two threads at the
/// same moment were still pending after one poll. Under a hanging close
/// behaviour, only a close that ran the behaviour stays pending.
pub(crate) fn pending_closes<T>(
    rounds: usize,
    make: impl Fn() -> T,
    close: for<'a> fn(&'a T) -> BoxFuture<'a, ()>,
) -> Vec<usize>
where
    T: Send + Sync + 'static,
{
    let targets: Arc<Vec<T>> = Arc::new((0..rounds).map(|_| make()).collect());
    let barrier = Arc::new(Barrier::new(2));
    let racers: Vec<_> = (0..2)
        .map(|_| {
            let targets = targets.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                targets
                    .iter()
                    .map(|target| {
                        barrier.wait();
                        close(target).now_or_never().is_none()
                    })
                    .collect::<Vec<bool>>()
            })
        })
        .collect();
    let pending: Vec<Vec<bool>> = racers
        .into_iter()
        .map(|racer| racer.join().unwrap_or_default())
        .collect();
    (0..rounds)
        .map(|round| pending.iter().filter(|racer| racer.get(round) == Some(&true)).count())
        .collect()
}
