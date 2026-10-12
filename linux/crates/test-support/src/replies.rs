use std::collections::VecDeque;
use std::fmt;

/// The scripted answers to one kind of call.
///
/// Calls that run concurrently arrive in no fixed order, so an answer
/// can also be tied to the SQL it is for rather than to its turn.
#[derive(Clone)]
pub struct Replies<R> {
    matching: Vec<(String, R)>,
    queue: VecDeque<R>,
    otherwise: Option<R>,
}

impl<R: Clone> Replies<R> {
    /// Answer the next call with `reply`, once, after the answers
    /// already queued.
    pub fn once(&mut self, reply: R) -> &mut Self {
        self.queue.push_back(reply);
        self
    }

    /// Answer every call with `reply` once the queue is empty.
    pub fn always(&mut self, reply: R) -> &mut Self {
        self.otherwise = Some(reply);
        self
    }

    /// Answer every call whose SQL contains `fragment` with `reply`,
    /// before the queue is consulted. The first matching rule wins.
    pub fn when_sql_contains(&mut self, fragment: impl Into<String>, reply: R) -> &mut Self {
        self.matching.push((fragment.into(), reply));
        self
    }

    pub(crate) fn next(&mut self, sql: Option<&str>) -> Option<R> {
        let matched = sql.and_then(|sql| {
            self.matching
                .iter()
                .find(|(fragment, _)| sql.contains(fragment.as_str()))
                .map(|(_, reply)| reply.clone())
        });
        matched
            .or_else(|| self.queue.pop_front())
            .or_else(|| self.otherwise.clone())
    }
}

impl<R> Default for Replies<R> {
    fn default() -> Self {
        Self {
            matching: Vec::new(),
            queue: VecDeque::new(),
            otherwise: None,
        }
    }
}

impl<R> fmt::Debug for Replies<R> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Replies")
            .field(
                "matching",
                &self.matching.iter().map(|(fragment, _)| fragment).collect::<Vec<_>>(),
            )
            .field("queued", &self.queue.len())
            .field("otherwise", &self.otherwise.is_some())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_rules_win_then_the_queue_then_the_fallback() {
        let mut replies = Replies::default();
        replies.once(1).once(2).always(9).when_sql_contains("SLEEP", 7);

        assert_eq!(replies.next(Some("SELECT SLEEP(3)")), Some(7));
        assert_eq!(replies.next(Some("SELECT 1")), Some(1));
        assert_eq!(replies.next(None), Some(2));
        assert_eq!(replies.next(None), Some(9));
        assert_eq!(replies.next(Some("SELECT SLEEP(3)")), Some(7), "a rule is not used up");
    }

    #[test]
    fn an_unscripted_call_has_no_answer() {
        let mut replies = Replies::<u8>::default();

        assert_eq!(replies.next(Some("SELECT 1")), None);
    }
}
