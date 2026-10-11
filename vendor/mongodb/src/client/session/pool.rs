use std::{collections::VecDeque, time::Duration};

use tokio::sync::Mutex;

use super::ServerSession;
use crate::bson::Document;

#[derive(Debug)]
pub(crate) struct ServerSessionPool {
    pool: Mutex<VecDeque<ServerSession>>,
}

impl ServerSessionPool {
    pub(crate) fn new() -> Self {
        Self {
            pool: Default::default(),
        }
    }

    /// Checks out a server session from the pool. Before doing so, it first clears out all the
    /// expired sessions. If there are no sessions left in the pool after clearing expired ones
    /// out, a new session will be created.
    pub(crate) async fn check_out(
        &self,
        logical_session_timeout: Option<Duration>,
    ) -> ServerSession {
        let mut pool = self.pool.lock().await;
        while let Some(session) = pool.pop_front() {
            // If a session is about to expire within the next minute, remove it from pool.
            if session.is_about_to_expire(logical_session_timeout) {
                continue;
            }
            return session;
        }
        ServerSession::new()
    }

    /// Checks in a server session to the pool. If it is about to expire or is dirty, it will be
    /// discarded.
    ///
    /// This method will also clear out any expired session from the pool before checking in.
    pub(crate) async fn check_in(
        &self,
        session: ServerSession,
        logical_session_timeout: Option<Duration>,
    ) {
        let mut pool = self.pool.lock().await;
        while let Some(pooled_session) = pool.pop_back() {
            if session.is_about_to_expire(logical_session_timeout) {
                continue;
            }
            pool.push_back(pooled_session);
            break;
        }

        if !session.dirty && !session.is_about_to_expire(logical_session_timeout) {
            pool.push_front(session);
        }
    }

    #[cfg(test)]
    pub(crate) async fn clear(&self) {
        self.pool.lock().await.clear();
    }

    #[cfg(test)]
    pub(crate) async fn contains(&self, id: &Document) -> bool {
        self.pool.lock().await.iter().any(|s| &s.id == id)
    }

    /// Returns a list of the IDs of the sessions contained in the pool.
    pub(crate) async fn get_session_ids(&self) -> Vec<Document> {
        let sessions = self.pool.lock().await;
        sessions.iter().map(|session| session.id.clone()).collect()
    }
}
