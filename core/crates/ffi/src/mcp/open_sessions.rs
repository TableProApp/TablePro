use std::sync::{Arc, Mutex, PoisonError, Weak};

use tablepro_session::Session;
use uuid::Uuid;

// The saved connections' sessions the app opened through `connect_saved`, each a workspace's. A closed one drops out.
#[derive(Default)]
pub(crate) struct OpenSessions(Mutex<Vec<Opened>>);

struct Opened {
    id: Uuid,
    // Another of the server's databases the app opened the connection in, None for its own.
    database: Option<String>,
    session: Weak<Session>,
}

impl OpenSessions {
    pub(crate) fn add(&self, id: Uuid, database: Option<String>, session: &Arc<Session>) {
        let mut opened = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        opened.retain(|entry| live(entry).is_some());
        opened.push(Opened {
            id,
            database,
            session: Arc::downgrade(session),
        });
    }

    // The newest, as a reconnect replaces a session before the old one has closed.
    pub(crate) fn get(&self, id: Uuid, database: Option<&str>) -> Option<Arc<Session>> {
        let opened = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        opened
            .iter()
            .rev()
            .filter(|entry| entry.id == id && entry.database.as_deref() == database)
            .find_map(live)
    }

    // Another database of an open connection is no other connection.
    pub(crate) fn ids(&self) -> Vec<Uuid> {
        let opened = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        let mut ids: Vec<Uuid> = Vec::new();
        for entry in opened.iter().filter(|entry| entry.database.is_none()) {
            if live(entry).is_some() && !ids.contains(&entry.id) {
                ids.push(entry.id);
            }
        }
        ids
    }
}

fn live(entry: &Opened) -> Option<Arc<Session>> {
    entry.session.upgrade().filter(|session| !session.is_shut_down())
}

impl std::fmt::Debug for OpenSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let opened = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        f.debug_struct("OpenSessions").field("entries", &opened.len()).finish()
    }
}
