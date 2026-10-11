use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_TRACKED_KEYS: usize = 4096;
const WINDOW: Duration = Duration::from_secs(60);

pub struct RateLimiter {
    max_per_minute: u32,
    windows: Mutex<HashMap<String, Vec<Instant>>>,
}

impl RateLimiter {
    pub fn new(max_per_minute: u32) -> Self {
        Self {
            max_per_minute,
            windows: Mutex::new(HashMap::new()),
        }
    }

    pub fn tracked_keys(&self) -> usize {
        self.windows.lock().map_or(0, |map| map.len())
    }

    pub fn check(&self, key: &str) -> Result<(), String> {
        let mut map = self.windows.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = Instant::now();
        map.retain(|tracked, entries| {
            entries.retain(|seen| now.duration_since(*seen) < WINDOW);
            !entries.is_empty() || tracked == key
        });
        if !map.contains_key(key) && map.len() >= MAX_TRACKED_KEYS {
            return Err("rate limiter is tracking too many callers".into());
        }
        let entries = map.entry(key.to_string()).or_default();
        if entries.len() as u32 >= self.max_per_minute {
            return Err(format!(
                "rate limit exceeded: {} requests / minute",
                self.max_per_minute
            ));
        }
        entries.push(now);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_under_limit() {
        let lim = RateLimiter::new(2);
        assert!(lim.check("a").is_ok());
        assert!(lim.check("a").is_ok());
        assert!(lim.check("a").is_err());
    }

    #[test]
    fn a_key_with_no_recent_requests_is_forgotten() {
        let lim = RateLimiter::new(2);
        assert!(lim.check("a").is_ok());
        assert_eq!(lim.tracked_keys(), 1);
        lim.windows
            .lock()
            .expect("rate limiter lock")
            .insert("a".into(), vec![Instant::now() - Duration::from_secs(120)]);
        assert!(lim.check("b").is_ok());
        assert_eq!(lim.tracked_keys(), 1);
    }

    #[test]
    fn a_full_table_refuses_an_unknown_caller_instead_of_growing() {
        let lim = RateLimiter::new(2);
        for index in 0..MAX_TRACKED_KEYS {
            assert!(lim.check(&format!("token-{index}")).is_ok());
        }
        assert_eq!(lim.tracked_keys(), MAX_TRACKED_KEYS);
        assert!(lim.check("one-too-many").is_err());
        assert_eq!(lim.tracked_keys(), MAX_TRACKED_KEYS);
        assert!(lim.check("token-0").is_ok());
    }
}
