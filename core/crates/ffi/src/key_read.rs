use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyTtl, KeyWindow};
use tablepro_core::meta::KeyKind;
use tablepro_core::{Truncation, Value};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationKind, Session};

use crate::cancel_token::{CancelToken, token};
use crate::error::CoreError;
use crate::results::{ResultSet, ResultStore};
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyKindTag {
    String,
    Hash,
    List,
    Set,
    SortedSet,
    Stream,
    // A module's type, such as a JSON document, which the engine names but the reader does not read.
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyTtlTag {
    Persistent,
    ExpiresIn { seconds: u64 },
    // The login may read the key but not ask when it expires.
    Unknown,
}

// What the key is after the window just read, and what the reader holds of its value.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyWindowInfo {
    pub kind: KeyKindTag,
    // The engine's own name for the type, what a tab shows for a type it does not read.
    pub type_name: String,
    pub ttl: KeyTtlTag,
    // Entries, or a string's bytes.
    pub length: Option<u64>,
    // Rows held after this window, an entry a scan returned again left out.
    pub rows: u64,
    pub has_more: bool,
    // A string longer than the window's bytes: the row holds its start.
    pub truncated: bool,
    // The key changed type since the last window, so the rows started again in a new set.
    pub restarted: bool,
}

// One key's value read a window at a time into one set, which the grid shows while Load More adds to it.
#[derive(uniffi::Object)]
pub struct KeyReader {
    session: Arc<Session>,
    tasks: Tasks,
    key: String,
    state: Arc<Mutex<ReadState>>,
}

#[derive(Default)]
struct ReadState {
    kind: Option<KeyKind>,
    // None once the last window was read.
    next: Option<KeyCursor>,
    set: Option<Arc<ResultSet>>,
    store: Option<Arc<ResultStore>>,
    // A scan can return an entry an earlier step already did.
    seen: HashSet<Vec<u8>>,
    last: Option<KeyWindowInfo>,
}

impl KeyReader {
    pub(crate) fn new(session: Arc<Session>, tasks: Tasks, key: String) -> Self {
        Self {
            session,
            tasks,
            key,
            state: Arc::new(Mutex::new(ReadState {
                next: Some(KeyCursor::start()),
                ..ReadState::default()
            })),
        }
    }
}

#[uniffi::export]
impl KeyReader {
    pub fn key(&self) -> String {
        self.key.clone()
    }

    // The rows read so far, from the first window on; None before it.
    pub fn rows(&self) -> Option<Arc<ResultSet>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).set.clone()
    }

    // The next window. None when the key does not exist. Past the last window it reads nothing and says so again.
    pub async fn read_more(&self, cancel: Option<Arc<CancelToken>>) -> Result<Option<KeyWindowInfo>, CoreError> {
        let session = self.session.clone();
        let key = self.key.clone();
        let state = self.state.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let cursor = {
                let held = state.lock().unwrap_or_else(PoisonError::into_inner);
                match &held.next {
                    Some(cursor) => cursor.clone(),
                    None => return Ok(held.last.clone()),
                }
            };
            let window = KeyWindow::after(cursor);
            let page = session
                .run_cancellable(OperationKind::Page, &cancel, |lease, options| {
                    let key = key.clone();
                    let window = window.clone();
                    async move { Ok(lease.read_key(&key, &window, options).await?) }
                })
                .await?;
            let Some(page) = page else {
                return Ok(None);
            };
            let mut held = state.lock().unwrap_or_else(PoisonError::into_inner);
            Ok(Some(held.take(page)))
        })
        .await
    }
}

impl ReadState {
    fn take(&mut self, page: KeyPage) -> KeyWindowInfo {
        let restarted = self.kind.is_some_and(|kind| kind != page.kind);
        if restarted || self.store.is_none() {
            let store = Arc::new(ResultStore::new(page.rows.columns.clone()));
            self.set = Some(Arc::new(ResultSet::new(0, store.clone())));
            self.store = Some(store);
            self.seen.clear();
        }
        self.kind = Some(page.kind);
        let scanned = matches!(page.kind, KeyKind::Hash | KeyKind::Set);
        let rows: Vec<Vec<Value>> = page
            .rows
            .rows
            .into_iter()
            .filter(|row| !scanned || entry_name(row.first()).is_none_or(|name| self.seen.insert(name)))
            .collect();
        let has_more = page.next.is_some();
        let held = self.store.as_ref().map_or(0, |store| {
            store.append(&rows);
            let truncation = if has_more || page.rows.truncated {
                Truncation::ReadPastLimit
            } else {
                Truncation::Complete
            };
            store.finish_as(None, truncation);
            store.row_count()
        });
        self.next = page.next;
        let info = KeyWindowInfo {
            kind: page.kind.into(),
            type_name: page.type_name,
            ttl: page.ttl.into(),
            length: page.length,
            rows: held,
            has_more,
            truncated: page.rows.truncated,
            restarted,
        };
        self.last = Some(KeyWindowInfo {
            restarted: false,
            ..info.clone()
        });
        info
    }
}

// A hash's field or a set's member, the part a scan can repeat.
fn entry_name(value: Option<&Value>) -> Option<Vec<u8>> {
    match value? {
        Value::Text(text) => Some(text.as_bytes().to_vec()),
        Value::Bytes(bytes) => Some(bytes.clone()),
        Value::Null => None,
        other => Some(format!("{other:?}").into_bytes()),
    }
}

impl From<KeyKind> for KeyKindTag {
    fn from(kind: KeyKind) -> Self {
        match kind {
            KeyKind::String => Self::String,
            KeyKind::Hash => Self::Hash,
            KeyKind::List => Self::List,
            KeyKind::Set => Self::Set,
            KeyKind::SortedSet => Self::SortedSet,
            KeyKind::Stream => Self::Stream,
            KeyKind::Other => Self::Other,
        }
    }
}

impl From<KeyTtl> for KeyTtlTag {
    fn from(ttl: KeyTtl) -> Self {
        match ttl {
            KeyTtl::Persistent => Self::Persistent,
            KeyTtl::ExpiresIn(left) => Self::ExpiresIn {
                seconds: left.as_secs(),
            },
            KeyTtl::Unknown => Self::Unknown,
        }
    }
}

impl std::fmt::Debug for KeyReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyReader").finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::QueryResult;
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::session::DatabaseSession;
    use crate::test_session::started;

    fn page(kind: KeyKind, names: &[&str], next: Option<&str>) -> KeyPage {
        let columns = vec![ResultColumn::new("member", ColumnType::unknown())];
        let rows = names.iter().map(|name| vec![Value::Text((*name).to_owned())]).collect();
        KeyPage {
            kind,
            type_name: "set".to_owned(),
            ttl: KeyTtl::ExpiresIn(Duration::from_secs(90)),
            length: Some(4),
            rows: QueryResult::new(columns, rows),
            next: next.map(KeyCursor::new),
        }
    }

    #[tokio::test]
    async fn load_more_adds_the_next_window_to_one_set_without_a_scan_s_repeats() {
        let mut script = ConnectionScript::default();
        script
            .read_key
            .once(FakeReply::ok(Some(page(KeyKind::Set, &["a", "b"], Some("7")))))
            .once(FakeReply::ok(Some(page(KeyKind::Set, &["b", "c", "d"], None))));
        let (session, tasks) = started(script);
        let reader = DatabaseSession::new(session, tasks).open_key("tags".to_owned());

        let first = reader.read_more(None).await.unwrap().unwrap();
        let set = reader.rows().unwrap();
        let second = reader.read_more(None).await.unwrap().unwrap();
        let again = reader.read_more(None).await.unwrap().unwrap();

        assert_eq!(first.kind, KeyKindTag::Set);
        assert_eq!(first.ttl, KeyTtlTag::ExpiresIn { seconds: 90 });
        assert_eq!((first.rows, first.has_more, first.length), (2, true, Some(4)));
        assert_eq!((second.rows, second.has_more, second.restarted), (4, false, false));
        assert_eq!(set.row_count(), 4, "the second window joined the set the grid holds");
        assert_eq!(again, second, "past the end nothing more is read");
        let members: Vec<_> = (0..4).map(|row| set.cell_text(row, 0).unwrap().unwrap()).collect();
        assert_eq!(members, ["a", "b", "c", "d"]);
    }

    #[tokio::test]
    async fn a_key_that_is_gone_reads_as_none() {
        let mut script = ConnectionScript::default();
        script.read_key.always(FakeReply::ok(None));
        let (session, tasks) = started(script);
        let reader = DatabaseSession::new(session, tasks).open_key("gone".to_owned());

        assert_eq!(reader.read_more(None).await.unwrap(), None);
        assert!(reader.rows().is_none());
    }

    #[tokio::test]
    async fn a_key_of_another_type_starts_its_rows_again() {
        let mut script = ConnectionScript::default();
        script
            .read_key
            .once(FakeReply::ok(Some(page(KeyKind::Set, &["a"], Some("3")))))
            .once(FakeReply::ok(Some(page(KeyKind::List, &["x"], None))));
        let (session, tasks) = started(script);
        let reader = DatabaseSession::new(session, tasks).open_key("k".to_owned());

        reader.read_more(None).await.unwrap();
        let before = reader.rows().unwrap();
        let after = reader.read_more(None).await.unwrap().unwrap();

        assert!(after.restarted);
        assert_eq!(after.kind, KeyKindTag::List);
        assert_eq!(after.rows, 1);
        assert!(!Arc::ptr_eq(&before, &reader.rows().unwrap()));
    }
}
