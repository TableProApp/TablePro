use std::sync::Arc;
use std::time::Duration;

use redis::Value as Reply;
use tablepro_core::column::ResultColumn;
use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyTtl, KeyWindow};
use tablepro_core::meta::KeyKind;
use tablepro_core::value::{JsonText, Value};
use tablepro_core::{DriverError, QueryResult, StopRequest};

use crate::key_name::{key_bytes, quoted_argument};
use crate::key_scan::{kind_named, scan_reply, status, unexpected};
use crate::link::{Link, stoppable};
use crate::reply_rows::{bytes_cell, float_column, integer_column, text_column};

/// How much of a string one window reads. A value can be 512 MB.
pub(crate) const STRING_WINDOW_BYTES: usize = 1024 * 1024;

/// One window of the key `name` lists as, by its type, or `None` when
/// there is no such key. Every read is bounded: a range or a scan step of
/// the window's size, or a string's first megabyte.
pub(crate) async fn read_key(
    link: &Link,
    name: &str,
    window: &KeyWindow,
    stop: &StopRequest,
) -> Result<Option<KeyPage>, DriverError> {
    let Some(key) = key_bytes(name) else {
        return Ok(None);
    };
    let mut first = redis::pipe();
    first.cmd("TYPE").arg(key.as_slice());
    first.cmd("PTTL").arg(key.as_slice());
    let replies = stoppable(stop, link.send_all(&first)).await?;
    let (type_name, ttl) = match replies.as_slice() {
        [type_reply, ttl_reply] => (
            status(type_reply).ok_or_else(|| unexpected(type_reply))?,
            ttl_reply.clone(),
        ),
        _ => return Err(DriverError::Protocol("TYPE and PTTL gave no two replies".to_owned())),
    };
    if type_name == "none" {
        return Ok(None);
    }
    let ttl = match ttl {
        Reply::Int(-2) => return Ok(None),
        Reply::Int(-1) => KeyTtl::Persistent,
        Reply::Int(millis) if millis >= 0 => KeyTtl::ExpiresIn(Duration::from_millis(millis.unsigned_abs())),
        // An ACL that denies PTTL answers with an error in its place.
        _ => KeyTtl::Unknown,
    };
    let kind = kind_named(&type_name);
    let Some(plan) = WindowPlan::new(kind, &key, window) else {
        return Ok(Some(KeyPage {
            kind,
            type_name,
            ttl,
            length: None,
            rows: QueryResult::empty(),
            next: None,
        }));
    };
    let mut second = redis::pipe();
    second.add_command(plan.length.clone());
    second.add_command(plan.read.clone());
    let mut replies = stoppable(stop, link.send_all(&second)).await?.into_iter();
    let (Some(length), Some(read)) = (replies.next(), replies.next()) else {
        return Err(DriverError::Protocol("a key read gave no two replies".to_owned()));
    };
    let length = match length {
        Reply::Int(length) => u64::try_from(length).ok(),
        other => return Err(unexpected(&other)),
    };
    let (rows, next) = plan.rows(read, length)?;
    Ok(Some(KeyPage {
        kind,
        type_name,
        ttl,
        length,
        rows,
        next,
    }))
}

/// The two commands that read one window of a key: its length, and the
/// window itself.
struct WindowPlan {
    kind: KeyKind,
    length: redis::Cmd,
    read: redis::Cmd,
    /// Where the window starts: an index for a list or a sorted set.
    start: u64,
    limit: u64,
}

impl WindowPlan {
    fn new(kind: KeyKind, key: &[u8], window: &KeyWindow) -> Option<Self> {
        let limit = u64::from(window.limit.get());
        let cursor = window.cursor.as_str();
        let start: u64 = cursor.parse().unwrap_or(0);
        let last = start.saturating_add(limit - 1);
        let scan_cursor = if window.cursor.is_start() { "0" } else { cursor };
        let on_key = |name: &str| {
            let mut command = redis::cmd(name);
            command.arg(key);
            command
        };
        let mut read = on_key(match kind {
            KeyKind::String => "GETRANGE",
            KeyKind::Hash => "HSCAN",
            KeyKind::List => "LRANGE",
            KeyKind::Set => "SSCAN",
            KeyKind::SortedSet => "ZRANGE",
            KeyKind::Stream => "XRANGE",
            KeyKind::Other => return None,
        });
        let length = on_key(match kind {
            KeyKind::String => "STRLEN",
            KeyKind::Hash => "HLEN",
            KeyKind::List => "LLEN",
            KeyKind::Set => "SCARD",
            KeyKind::SortedSet => "ZCARD",
            KeyKind::Stream | KeyKind::Other => "XLEN",
        });
        match kind {
            KeyKind::String => read.arg(0).arg(STRING_WINDOW_BYTES - 1),
            KeyKind::Hash | KeyKind::Set => read.arg(scan_cursor).arg("COUNT").arg(limit),
            KeyKind::List => read.arg(start).arg(last),
            KeyKind::SortedSet => read.arg(start).arg(last).arg("WITHSCORES"),
            KeyKind::Stream | KeyKind::Other => {
                let from = if window.cursor.is_start() { "-" } else { cursor };
                read.arg(from).arg("+").arg("COUNT").arg(limit)
            }
        };
        Some(Self {
            kind,
            length,
            read,
            start,
            limit,
        })
    }

    fn rows(&self, read: Reply, length: Option<u64>) -> Result<(QueryResult, Option<KeyCursor>), DriverError> {
        match self.kind {
            KeyKind::String => {
                let bytes = match read {
                    Reply::BulkString(bytes) => bytes,
                    other => return Err(unexpected(&other)),
                };
                let cut = length.is_some_and(|length| length > bytes.len() as u64);
                let result = table(&[text_column("value")], vec![vec![string_cell(bytes, cut)]]);
                Ok((result.truncated(cut), None))
            }
            KeyKind::Hash => {
                let (next, elements) = scan_reply(read)?;
                let rows = pairs(elements)
                    .map(|(field, value)| vec![bytes_cell(field), bytes_cell(value)])
                    .collect();
                Ok((
                    table(&[text_column("field"), text_column("value")], rows),
                    scan_next(next),
                ))
            }
            KeyKind::Set => {
                let (next, elements) = scan_reply(read)?;
                let rows = elements.into_iter().map(|member| vec![bytes_cell(member)]).collect();
                Ok((table(&[text_column("member")], rows), scan_next(next)))
            }
            KeyKind::List => {
                let elements = elements(read)?;
                let read = elements.len() as u64;
                let rows = elements
                    .into_iter()
                    .zip(self.start..)
                    .map(|(element, index)| vec![Value::Int(i64::try_from(index).unwrap_or(i64::MAX)), element])
                    .collect();
                let result = table(&[integer_column("index"), text_column("element")], rows);
                Ok((result, self.index_next(read, length)))
            }
            KeyKind::SortedSet => {
                let flat = elements(read)?;
                let read = (flat.len() / 2) as u64;
                let mut rows = Vec::with_capacity(flat.len() / 2);
                let mut flat = flat.into_iter();
                while let (Some(member), Some(score)) = (flat.next(), flat.next()) {
                    rows.push(vec![member, score_cell(score)]);
                }
                let result = table(&[text_column("member"), float_column("score")], rows);
                Ok((result, self.index_next(read, length)))
            }
            KeyKind::Stream => stream_rows(read, self.limit),
            KeyKind::Other => Ok((QueryResult::empty(), None)),
        }
    }

    /// The next index of a range read, unless the range reached the end.
    fn index_next(&self, read: u64, length: Option<u64>) -> Option<KeyCursor> {
        let next = self.start + read;
        (read == self.limit && length.is_none_or(|length| next < length)).then(|| KeyCursor::new(next.to_string()))
    }
}

fn table(columns: &[ResultColumn], rows: Vec<Vec<Value>>) -> QueryResult {
    QueryResult::new(Arc::<[ResultColumn]>::from(columns.to_vec()), rows)
}

fn scan_next(cursor: Vec<u8>) -> Option<KeyCursor> {
    (cursor != b"0").then(|| KeyCursor::new(String::from_utf8_lossy(&cursor).into_owned()))
}

fn pairs(elements: Vec<Vec<u8>>) -> impl Iterator<Item = (Vec<u8>, Vec<u8>)> {
    let mut elements = elements.into_iter();
    std::iter::from_fn(move || Some((elements.next()?, elements.next()?)))
}

fn elements(read: Reply) -> Result<Vec<Value>, DriverError> {
    match read {
        Reply::Array(items) => items
            .into_iter()
            .map(|item| match item {
                Reply::BulkString(bytes) => Ok(bytes_cell(bytes)),
                Reply::Double(score) => Ok(Value::Float64(score)),
                other => Err(unexpected(&other)),
            })
            .collect(),
        other => Err(unexpected(&other)),
    }
}

/// A sorted set's score as Redis spells it, `inf` and `-inf` included.
fn score_cell(score: Value) -> Value {
    match score {
        Value::Text(text) => match text.parse::<f64>() {
            Ok(score) => Value::Float64(score),
            Err(_) => Value::Text(text),
        },
        other => other,
    }
}

/// A string cut at the window, with a character the cut split dropped,
/// so a long text value still reads as text.
fn string_cell(mut bytes: Vec<u8>, cut: bool) -> Value {
    if cut
        && let Err(error) = std::str::from_utf8(&bytes)
        && error.error_len().is_none()
    {
        bytes.truncate(error.valid_up_to());
    }
    bytes_cell(bytes)
}

/// A stream's entries: the id and the fields as a JSON object. The next
/// window starts just past the last id read, which an id one sequence
/// number on gives on every Redis version.
fn stream_rows(read: Reply, limit: u64) -> Result<(QueryResult, Option<KeyCursor>), DriverError> {
    let Reply::Array(entries) = read else {
        return Err(unexpected(&read));
    };
    let mut rows = Vec::with_capacity(entries.len());
    let mut last = None;
    for entry in entries {
        let Reply::Array(mut parts) = entry else {
            return Err(unexpected(&entry));
        };
        let (Some(fields), Some(id)) = (parts.pop(), parts.pop()) else {
            return Err(DriverError::Protocol(
                "a stream entry without its id and fields".to_owned(),
            ));
        };
        let id = match id {
            Reply::BulkString(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            other => return Err(unexpected(&other)),
        };
        rows.push(vec![Value::Text(id.clone()), fields_cell(fields)?]);
        last = Some(id);
    }
    let next = match last {
        Some(id) if rows.len() as u64 == limit => after(&id).map(KeyCursor::new),
        _ => None,
    };
    let result = table(&[text_column("id"), text_column("fields")], rows);
    Ok((result, next))
}

fn fields_cell(fields: Reply) -> Result<Value, DriverError> {
    let Reply::Array(flat) = fields else {
        return Err(unexpected(&fields));
    };
    let text = |reply: Reply| match reply {
        Reply::BulkString(bytes) => Ok(match String::from_utf8(bytes) {
            Ok(text) => text,
            Err(error) => quoted_argument(error.as_bytes()),
        }),
        other => Err(unexpected(&other)),
    };
    // Written out by hand: a map would put the fields in another order
    // than the entry has them.
    let mut object = String::from("{");
    let mut flat = flat.into_iter();
    while let (Some(field), Some(value)) = (flat.next(), flat.next()) {
        if object.len() > 1 {
            object.push(',');
        }
        object.push_str(&serde_json::Value::String(text(field)?).to_string());
        object.push(':');
        object.push_str(&serde_json::Value::String(text(value)?).to_string());
    }
    object.push('}');
    JsonText::parse(object)
        .map(Value::Json)
        .map_err(|error| DriverError::Protocol(error.to_string()))
}

/// The stream id right after `id`: `<ms>-<seq + 1>`, or the next
/// millisecond once the sequence is at its end.
fn after(id: &str) -> Option<String> {
    let (millis, sequence) = id.split_once('-')?;
    let millis: u64 = millis.parse().ok()?;
    let sequence: u64 = sequence.parse().ok()?;
    match sequence.checked_add(1) {
        Some(sequence) => Some(format!("{millis}-{sequence}")),
        None => Some(format!("{}-0", millis.checked_add(1)?)),
    }
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroU32;

    use super::*;

    fn bulk(text: &str) -> Reply {
        Reply::BulkString(text.as_bytes().to_vec())
    }

    fn window(cursor: &str, limit: u32) -> KeyWindow {
        KeyWindow {
            cursor: KeyCursor::new(cursor),
            limit: NonZeroU32::new(limit).unwrap(),
        }
    }

    #[test]
    fn a_list_window_reads_by_index_and_stops_at_the_end() {
        let plan = WindowPlan::new(KeyKind::List, b"l", &window("2", 2)).unwrap();

        let (rows, next) = plan.rows(Reply::Array(vec![bulk("c"), bulk("d")]), Some(5)).unwrap();
        assert_eq!(
            rows.rows,
            vec![
                vec![Value::Int(2), Value::Text("c".to_owned())],
                vec![Value::Int(3), Value::Text("d".to_owned())]
            ]
        );
        assert_eq!(next, Some(KeyCursor::new("4")));
        let (_, end) = plan.rows(Reply::Array(vec![bulk("c"), bulk("d")]), Some(4)).unwrap();
        assert_eq!(end, None);
    }

    #[test]
    fn a_sorted_set_pairs_members_with_scores() {
        let plan = WindowPlan::new(KeyKind::SortedSet, b"z", &KeyWindow::first()).unwrap();

        let (rows, next) = plan
            .rows(
                Reply::Array(vec![bulk("a"), bulk("1.5"), bulk("b"), bulk("inf")]),
                Some(2),
            )
            .unwrap();

        assert_eq!(
            rows.rows,
            vec![
                vec![Value::Text("a".to_owned()), Value::Float64(1.5)],
                vec![Value::Text("b".to_owned()), Value::Float64(f64::INFINITY)]
            ]
        );
        assert_eq!(next, None);
    }

    #[test]
    fn a_hash_window_follows_the_scan_cursor() {
        let plan = WindowPlan::new(KeyKind::Hash, b"h", &KeyWindow::first()).unwrap();

        let (rows, next) = plan
            .rows(
                Reply::Array(vec![bulk("12"), Reply::Array(vec![bulk("f"), bulk("v")])]),
                Some(9),
            )
            .unwrap();

        assert_eq!(
            rows.rows,
            vec![vec![Value::Text("f".to_owned()), Value::Text("v".to_owned())]]
        );
        assert_eq!(next, Some(KeyCursor::new("12")));
    }

    #[test]
    fn a_long_string_is_cut_and_says_so() {
        let plan = WindowPlan::new(KeyKind::String, b"s", &KeyWindow::first()).unwrap();
        // "é" is two bytes, and the window ends after the first.
        let (rows, next) = plan.rows(Reply::BulkString(b"ab\xc3".to_vec()), Some(4)).unwrap();

        assert_eq!(rows.rows, vec![vec![Value::Text("ab".to_owned())]]);
        assert!(rows.truncated);
        assert_eq!(next, None);
    }

    #[test]
    fn a_stream_window_starts_past_the_last_id() {
        let entry = |id: &str| Reply::Array(vec![bulk(id), Reply::Array(vec![bulk("f"), bulk("v")])]);
        let read = Reply::Array(vec![entry("1-0"), entry("1-1")]);

        let (rows, next) = stream_rows(read, 2).unwrap();

        assert_eq!(rows.rows.len(), 2);
        assert_eq!(
            rows.rows[0][1],
            Value::Json(JsonText::parse(r#"{"f":"v"}"#.to_owned()).unwrap())
        );
        assert_eq!(next, Some(KeyCursor::new("1-2")));
        assert_eq!(after(&format!("5-{}", u64::MAX)).as_deref(), Some("6-0"));
    }

    #[test]
    fn a_module_type_reads_nothing() {
        assert!(WindowPlan::new(KeyKind::Other, b"j", &KeyWindow::first()).is_none());
    }
}
