use std::collections::HashSet;
use std::time::Duration;

use redis::Value as Reply;
use tablepro_core::keyspace::{KeyListing, KeyScan};
use tablepro_core::meta::{KeyKind, ObjectInfo, ObjectKind};
use tablepro_core::{DriverError, StopRequest};
use tokio::time::Instant;

use crate::errors::server_error;
use crate::key_name::key_text;
use crate::link::{Link, stoppable};

/// What one `SCAN` asks the server to look at. It is a hint the server
/// keeps roughly, and each step holds the server only that long.
const SCAN_COUNT: &str = "1000";

/// How many `TYPE`s go out in one round trip.
const TYPE_BATCH: usize = 500;

/// How long a listing walks the keyspace. A pattern few keys match makes
/// every step come back nearly empty, and a database of millions of keys
/// takes thousands of steps to walk.
const WALK_BUDGET: Duration = Duration::from_secs(5);

/// The keys `scan` asks for, each with its type, read with `SCAN` and
/// never `KEYS`, which would hold the server for the whole keyspace.
pub(crate) async fn scan_keys(link: &Link, scan: &KeyScan, stop: &StopRequest) -> Result<KeyListing, DriverError> {
    let (names, complete) = walk(link, scan, stop).await?;
    let mut keys = Vec::with_capacity(names.len());
    for batch in names.chunks(TYPE_BATCH) {
        let mut pipeline = redis::pipe();
        for name in batch {
            pipeline.cmd("TYPE").arg(name.as_slice());
        }
        let replies = stoppable(stop, link.send_all(&pipeline)).await?;
        for (name, reply) in batch.iter().zip(replies) {
            // Gone since the scan saw it.
            let Some(kind) = key_kind(&reply) else {
                continue;
            };
            keys.push(ObjectInfo {
                schema: None,
                name: key_text(name),
                kind: ObjectKind::Key(kind),
            });
        }
    }
    Ok(KeyListing { keys, complete })
}

/// Every name the walk found, at most the scan's limit, and whether it
/// reached the end of the keyspace. `SCAN` can return a key twice, so
/// each is kept at its first sighting.
async fn walk(link: &Link, scan: &KeyScan, stop: &StopRequest) -> Result<(Vec<Vec<u8>>, bool), DriverError> {
    let limit = scan.limit.get();
    let started = Instant::now();
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    let mut names = Vec::new();
    let mut cursor = b"0".to_vec();
    loop {
        let mut step = redis::cmd("SCAN");
        step.arg(cursor.as_slice());
        if let Some(pattern) = &scan.pattern {
            step.arg("MATCH").arg(pattern.as_bytes());
        }
        step.arg("COUNT").arg(SCAN_COUNT);
        let reply = stoppable(stop, link.ask(&step)).await?;
        let (next, found) = scan_reply(reply)?;
        for name in found {
            if seen.insert(name.clone()) {
                names.push(name);
            }
        }
        if next == b"0" {
            let complete = names.len() <= limit;
            names.truncate(limit);
            return Ok((names, complete));
        }
        if names.len() >= limit || started.elapsed() >= WALK_BUDGET {
            names.truncate(limit);
            return Ok((names, false));
        }
        cursor = next;
    }
}

/// A `SCAN`-family reply: the next cursor and the elements of this step.
pub(crate) fn scan_reply(reply: Reply) -> Result<(Vec<u8>, Vec<Vec<u8>>), DriverError> {
    let Reply::Array(mut parts) = reply else {
        return Err(unexpected(&reply));
    };
    let (Some(elements), Some(cursor)) = (parts.pop(), parts.pop()) else {
        return Err(DriverError::Protocol("a scan reply without its two parts".to_owned()));
    };
    let cursor = match cursor {
        Reply::BulkString(cursor) => cursor,
        Reply::SimpleString(cursor) => cursor.into_bytes(),
        Reply::Int(cursor) => cursor.to_string().into_bytes(),
        other => return Err(unexpected(&other)),
    };
    let Reply::Array(elements) = elements else {
        return Err(unexpected(&elements));
    };
    let elements = elements
        .into_iter()
        .map(|element| match element {
            Reply::BulkString(bytes) => Ok(bytes),
            Reply::SimpleString(text) => Ok(text.into_bytes()),
            other => Err(unexpected(&other)),
        })
        .collect::<Result<_, _>>()?;
    Ok((cursor, elements))
}

/// What `TYPE` said, or `None` for a key that is gone. A login whose ACL
/// may list a key but not read it is told no for `TYPE` too, and the key
/// is still listed, as one the tab cannot read.
pub(crate) fn key_kind(reply: &Reply) -> Option<KeyKind> {
    match status(reply).as_deref() {
        Some("none") => None,
        Some(name) => Some(kind_named(name)),
        None => Some(KeyKind::Other),
    }
}

pub(crate) fn kind_named(name: &str) -> KeyKind {
    match name {
        "string" => KeyKind::String,
        "hash" => KeyKind::Hash,
        "list" => KeyKind::List,
        "set" => KeyKind::Set,
        "zset" => KeyKind::SortedSet,
        "stream" => KeyKind::Stream,
        _ => KeyKind::Other,
    }
}

/// A status reply's text, such as `TYPE`'s.
pub(crate) fn status(reply: &Reply) -> Option<String> {
    match reply {
        Reply::SimpleString(text) => Some(text.clone()),
        Reply::BulkString(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        Reply::Okay => Some("OK".to_owned()),
        _ => None,
    }
}

pub(crate) fn unexpected(reply: &Reply) -> DriverError {
    match reply {
        Reply::ServerError(error) => server_error(error),
        other => DriverError::Protocol(format!("an unexpected reply: {other:?}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk(text: &str) -> Reply {
        Reply::BulkString(text.as_bytes().to_vec())
    }

    #[test]
    fn a_scan_reply_is_a_cursor_and_its_elements() {
        let reply = Reply::Array(vec![bulk("17"), Reply::Array(vec![bulk("a"), bulk("b")])]);

        assert_eq!(
            scan_reply(reply).unwrap(),
            (b"17".to_vec(), vec![b"a".to_vec(), b"b".to_vec()])
        );
    }

    #[test]
    fn a_reply_of_another_shape_is_refused() {
        assert!(scan_reply(Reply::Int(1)).is_err());
        assert!(scan_reply(Reply::Array(vec![bulk("0")])).is_err());
    }

    #[test]
    fn each_type_name_has_its_kind() {
        let kinds: Vec<Option<KeyKind>> = ["string", "hash", "list", "set", "zset", "stream", "ReJSON-RL", "none"]
            .into_iter()
            .map(|name| key_kind(&Reply::SimpleString(name.to_owned())))
            .collect();

        assert_eq!(
            kinds,
            [
                Some(KeyKind::String),
                Some(KeyKind::Hash),
                Some(KeyKind::List),
                Some(KeyKind::Set),
                Some(KeyKind::SortedSet),
                Some(KeyKind::Stream),
                Some(KeyKind::Other),
                None
            ]
        );
    }
}
