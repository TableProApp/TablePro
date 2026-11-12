use std::sync::Arc;
use std::time::SystemTime;

use rmcp::model::Implementation;
use tokio::sync::watch;

// Only a client holding the token gets this far, but its name is shown
// to the user, so the list and each text stay small.
const MAX_CLIENTS: usize = 32;
const MAX_TEXT_CHARS: usize = 120;

// A client as it named itself, in `initialize` or in a request's
// `_meta`. The server is stateless, so this is the last time it started
// a session, not a live connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeenClient {
    pub name: String,
    pub title: Option<String>,
    pub version: String,
    pub seen_at: SystemTime,
}

#[derive(Clone)]
pub(crate) struct SeenClients(Arc<watch::Sender<Vec<SeenClient>>>);

impl SeenClients {
    pub(crate) fn new() -> Self {
        Self(Arc::new(watch::channel(Vec::new()).0))
    }

    pub(crate) fn subscribe(&self) -> watch::Receiver<Vec<SeenClient>> {
        self.0.subscribe()
    }

    // A handshake: the latest one moves a client to the end of the list.
    pub(crate) fn record(&self, client: &Implementation, at: SystemTime) {
        let Some(seen) = sighting(client, at) else {
            return;
        };
        self.0.send_modify(|clients| {
            clients.retain(|known| known.name != seen.name);
            push(clients, seen);
        });
    }

    // A client that names itself on every request, as one on the
    // 2026-07-28 protocol does: only its first request counts, so a
    // listener hears of it once rather than per call.
    pub(crate) fn record_new(&self, client: &Implementation, at: SystemTime) {
        let Some(seen) = sighting(client, at) else {
            return;
        };
        self.0.send_if_modified(|clients| {
            if clients.iter().any(|known| known.name == seen.name) {
                return false;
            }
            push(clients, seen);
            true
        });
    }
}

fn sighting(client: &Implementation, at: SystemTime) -> Option<SeenClient> {
    let name = clip(&client.name);
    if name.is_empty() {
        return None;
    }
    Some(SeenClient {
        title: client.title.as_deref().map(clip).filter(|title| !title.is_empty()),
        version: clip(&client.version),
        seen_at: at,
        name,
    })
}

fn push(clients: &mut Vec<SeenClient>, seen: SeenClient) {
    if clients.len() >= MAX_CLIENTS {
        clients.remove(0);
    }
    clients.push(seen);
}

fn clip(text: &str) -> String {
    text.trim()
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_TEXT_CHARS)
        .collect()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn a_client_seen_again_keeps_one_entry_at_the_end() {
        let seen = SeenClients::new();
        let receiver = seen.subscribe();
        let start = SystemTime::UNIX_EPOCH;

        seen.record(&Implementation::new("claude-code", "2.1"), start);
        seen.record(&Implementation::new("Zed", "1.27").with_title("Zed"), start);
        seen.record(
            &Implementation::new("claude-code", "2.2"),
            start + Duration::from_secs(5),
        );

        let clients = receiver.borrow().clone();
        let names: Vec<&str> = clients.iter().map(|client| client.name.as_str()).collect();
        assert_eq!(names, ["Zed", "claude-code"]);
        assert_eq!(clients[1].version, "2.2");
        assert_eq!(clients[1].seen_at, start + Duration::from_secs(5));
        assert_eq!(clients[0].title.as_deref(), Some("Zed"));
    }

    #[test]
    fn a_nameless_client_is_ignored_and_the_list_is_bounded() {
        let seen = SeenClients::new();

        seen.record(&Implementation::new("  ", "1"), SystemTime::UNIX_EPOCH);
        for index in 0..MAX_CLIENTS + 5 {
            seen.record(&Implementation::new(format!("c{index}"), "1"), SystemTime::UNIX_EPOCH);
        }

        let clients = seen.subscribe().borrow().clone();
        assert_eq!(clients.len(), MAX_CLIENTS);
        assert_eq!(clients[0].name, "c5");
    }

    #[test]
    fn a_client_named_on_every_request_is_recorded_once() {
        let seen = SeenClients::new();
        let mut receiver = seen.subscribe();
        let start = SystemTime::UNIX_EPOCH;

        seen.record_new(&Implementation::new("claude-code", "3.0"), start);
        assert!(receiver.has_changed().expect("a sender"));
        receiver.borrow_and_update();
        seen.record_new(
            &Implementation::new("claude-code", "3.0"),
            start + Duration::from_secs(5),
        );

        assert!(
            !receiver.has_changed().expect("a sender"),
            "a second call was announced"
        );
        let clients = receiver.borrow().clone();
        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0].seen_at, start);
    }

    #[test]
    fn names_lose_control_characters_and_excess_length() {
        let seen = SeenClients::new();

        seen.record(
            &Implementation::new(format!("a\u{1b}[31m{}", "x".repeat(500)), "1"),
            SystemTime::UNIX_EPOCH,
        );

        let name = seen.subscribe().borrow()[0].name.clone();
        assert!(name.starts_with("a[31m"));
        assert_eq!(name.chars().count(), MAX_TEXT_CHARS);
    }
}
