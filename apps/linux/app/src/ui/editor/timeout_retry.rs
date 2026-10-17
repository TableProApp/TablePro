use crate::services::operation_control::longer_timeout_secs;

struct Offer {
    secs: u32,
    sql: String,
}

#[derive(Default)]
pub(super) struct TimeoutRetry {
    offer: Option<Offer>,
    override_secs: Option<u32>,
}

impl TimeoutRetry {
    pub(super) fn offer(&mut self, exceeded_secs: u32, sql: String) -> Option<u32> {
        let secs = longer_timeout_secs(exceeded_secs)?;
        self.offer = Some(Offer { secs, sql });
        Some(secs)
    }

    pub(super) fn accept(&mut self) -> Option<String> {
        let Offer { secs, sql } = self.offer.take()?;
        self.override_secs = Some(secs);
        Some(sql)
    }

    pub(super) fn clear_override(&mut self) {
        self.override_secs = None;
    }

    pub(super) fn resolve(&mut self, configured_secs: impl FnOnce() -> u32) -> u32 {
        self.offer = None;
        self.override_secs.take().unwrap_or_else(configured_secs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepting_an_offer_returns_the_same_sql_and_applies_the_longer_timeout_once() {
        let mut retry = TimeoutRetry::default();
        assert_eq!(retry.offer(60, "SELECT slow()".into()), Some(240));

        assert_eq!(retry.accept().as_deref(), Some("SELECT slow()"));
        assert_eq!(retry.resolve(|| 60), 240, "the retry runs with the longer timeout");
        assert_eq!(retry.resolve(|| 60), 60, "and only that run does");
    }

    #[test]
    fn an_offer_is_made_once_and_gone_after_the_next_run_starts() {
        let mut retry = TimeoutRetry::default();
        retry.offer(30, "SELECT 1".into());

        assert_eq!(retry.resolve(|| 30), 30, "starting any run uses the configured timeout");
        assert!(retry.accept().is_none(), "the offer did not survive the new run");
    }

    #[test]
    fn a_pending_override_never_reaches_an_ordinary_run() {
        let mut retry = TimeoutRetry::default();
        retry.offer(30, "SELECT 1".into());
        retry.accept();

        retry.clear_override();

        assert_eq!(
            retry.resolve(|| 30),
            30,
            "a cancelled parameter dialog leaves nothing behind"
        );
    }

    #[test]
    fn no_offer_is_made_when_nothing_longer_exists() {
        let mut retry = TimeoutRetry::default();
        assert_eq!(retry.offer(0, "SELECT 1".into()), None);
        assert_eq!(retry.offer(u32::MAX, "SELECT 1".into()), None);
        assert!(retry.accept().is_none());
    }

    #[test]
    fn a_new_timeout_replaces_the_previous_offer() {
        let mut retry = TimeoutRetry::default();
        retry.offer(30, "SELECT 1".into());
        retry.offer(240, "SELECT 2".into());

        assert_eq!(retry.accept().as_deref(), Some("SELECT 2"));
        assert_eq!(retry.resolve(|| 30), 960);
    }
}
