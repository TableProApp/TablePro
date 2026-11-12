use std::sync::Mutex;
use std::time::Duration;

use tokio::sync::Notify;
use tokio::time::Instant;

use crate::lock;

// The handshake timeout, stopped while the user answers a prompt, as the OpenSSH transport's is.
#[derive(Debug)]
pub(crate) struct PromptClock {
    state: Mutex<State>,
    changed: Notify,
}

#[derive(Debug)]
struct State {
    remaining: Duration,
    running_since: Option<Instant>,
    prompts_open: usize,
}

impl PromptClock {
    pub fn new(timeout: Duration) -> Self {
        Self {
            state: Mutex::new(State {
                remaining: timeout,
                running_since: Some(Instant::now()),
                prompts_open: 0,
            }),
            changed: Notify::new(),
        }
    }

    pub fn pause(&self) -> Paused<'_> {
        {
            let mut state = lock(&self.state);
            state.prompts_open += 1;
            if let Some(since) = state.running_since.take() {
                state.remaining = state.remaining.saturating_sub(since.elapsed());
            }
        }
        self.changed.notify_waiters();
        Paused { clock: self }
    }

    fn resume(&self) {
        {
            let mut state = lock(&self.state);
            state.prompts_open = state.prompts_open.saturating_sub(1);
            if state.prompts_open == 0 && state.running_since.is_none() {
                state.running_since = Some(Instant::now());
            }
        }
        self.changed.notify_waiters();
    }

    fn deadline(&self) -> Option<Instant> {
        let state = lock(&self.state);
        state.running_since.map(|since| since + state.remaining)
    }

    // Resolves once the time runs out while no prompt is open.
    pub async fn expired(&self) {
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            match self.deadline() {
                None => changed.await,
                Some(deadline) => {
                    tokio::select! {
                        () = tokio::time::sleep_until(deadline) => {
                            if self.deadline().is_some_and(|now_due| now_due <= Instant::now()) {
                                return;
                            }
                        }
                        () = changed => {}
                    }
                }
            }
        }
    }
}

pub(crate) struct Paused<'a> {
    clock: &'a PromptClock,
}

impl Drop for Paused<'_> {
    fn drop(&mut self) {
        self.clock.resume();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn the_time_spent_on_a_prompt_does_not_count() {
        let clock = Arc::new(PromptClock::new(Duration::from_secs(20)));
        let watching = tokio::spawn({
            let clock = clock.clone();
            async move { clock.expired().await }
        });

        tokio::time::advance(Duration::from_secs(5)).await;
        let paused = clock.pause();
        tokio::time::advance(Duration::from_secs(60)).await;
        assert!(!watching.is_finished(), "the clock ran while a prompt was open");
        drop(paused);
        tokio::time::advance(Duration::from_secs(14)).await;
        tokio::task::yield_now().await;
        assert!(!watching.is_finished(), "the clock lost the time it had left");
        tokio::time::advance(Duration::from_secs(2)).await;

        watching.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn two_prompts_at_once_keep_it_stopped_until_both_close() {
        let clock = PromptClock::new(Duration::from_secs(1));
        let first = clock.pause();
        let second = clock.pause();
        drop(first);

        assert_eq!(clock.deadline(), None);
        drop(second);
        assert!(clock.deadline().is_some());
    }
}
