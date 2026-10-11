use std::{collections::VecDeque, time::Duration};

#[cfg(test)]
use tokio::sync::oneshot;

use crate::{
    bson::{Bson, Document, RawDocument, RawDocumentBuf},
    change_stream::event::ResumeToken,
    cmap::conn::PinnedConnectionHandle,
    error::{Error, Result},
    options::ServerAddress,
    Client,
    Namespace,
};

/// Specification used to create a new cursor.
#[derive(Debug, Clone)]
pub(crate) struct CursorSpecification {
    pub(crate) info: CursorInformation,
    pub(crate) initial_reply: RawDocumentBuf,
    pub(crate) is_empty: bool,
    pub(crate) post_batch_resume_token: Option<ResumeToken>,
}

impl CursorSpecification {
    pub(crate) fn new(
        response: crate::cmap::RawCommandResponse,
        address: ServerAddress,
        batch_size: impl Into<Option<u32>>,
        max_time: impl Into<Option<Duration>>,
        comment: impl Into<Option<Bson>>,
    ) -> Result<Self> {
        // Parse minimal fields via raw to avoid per-doc copies.
        let raw_root = response.raw_body();
        let cursor_doc = raw_root.get_document("cursor")?;
        let CursorReply {
            id,
            ns,
            post_batch_resume_token,
        } = CursorReply::parse(cursor_doc)?;
        let first_batch = cursor_doc.get_array("firstBatch")?;
        let is_empty = first_batch.is_empty();
        Ok(Self {
            info: CursorInformation {
                ns,
                id,
                address,
                batch_size: batch_size.into(),
                max_time: max_time.into(),
                comment: comment.into(),
            },
            initial_reply: response.into_raw_document_buf(),
            is_empty,
            post_batch_resume_token,
        })
    }

    #[cfg(feature = "opentelemetry")]
    pub(crate) fn id(&self) -> i64 {
        self.info.id
    }
}

/// Fields in an server cursor reply value, minus the actual documents.
pub(crate) struct CursorReply {
    pub(crate) id: i64,
    pub(crate) ns: Namespace,
    pub(crate) post_batch_resume_token: Option<ResumeToken>,
}

impl CursorReply {
    pub(crate) fn parse(cursor_doc: &RawDocument) -> Result<Self> {
        let id = cursor_doc.get_i64("id")?;
        let ns_str = cursor_doc.get_str("ns")?;
        let ns = Namespace::from_str(ns_str)
            .ok_or_else(|| Error::invalid_response("invalid cursor ns"))?;
        let post_token_raw = cursor_doc
            .get("postBatchResumeToken")?
            .and_then(crate::bson::RawBsonRef::as_document)
            .map(|d| d.to_owned());
        let post_batch_resume_token = ResumeToken::from_raw(post_token_raw);
        Ok(Self {
            id,
            ns,
            post_batch_resume_token,
        })
    }
}

/// Static information about a cursor.
#[derive(Clone, Debug)]
pub(crate) struct CursorInformation {
    pub(crate) ns: Namespace,
    pub(crate) address: ServerAddress,
    pub(crate) id: i64,
    pub(crate) batch_size: Option<u32>,
    pub(crate) max_time: Option<Duration>,
    pub(crate) comment: Option<Bson>,
}

#[derive(Debug)]
pub(crate) enum PinnedConnection {
    Valid(PinnedConnectionHandle),
    Invalid(PinnedConnectionHandle),
    Unpinned,
}

impl PinnedConnection {
    pub(super) fn new(handle: Option<PinnedConnectionHandle>) -> Self {
        match handle {
            Some(h) => Self::Valid(h),
            None => Self::Unpinned,
        }
    }

    /// Make a new `PinnedConnection` that refers to the same connection as this one.
    /// Use with care and only when "lending" a handle in a way that can't be expressed as a
    /// normal borrow.
    pub(crate) fn replicate(&self) -> Self {
        match self {
            Self::Valid(h) => Self::Valid(h.replicate()),
            Self::Invalid(h) => Self::Invalid(h.replicate()),
            Self::Unpinned => Self::Unpinned,
        }
    }

    pub(crate) fn handle(&self) -> Option<&PinnedConnectionHandle> {
        match self {
            Self::Valid(h) | Self::Invalid(h) => Some(h),
            Self::Unpinned => None,
        }
    }

    fn is_invalid(&self) -> bool {
        matches!(self, Self::Invalid(_))
    }

    pub(super) fn invalidate(&mut self) {
        take_mut::take(self, |self_| {
            if let Self::Valid(c) = self_ {
                Self::Invalid(c)
            } else {
                self_
            }
        });
    }
}

pub(super) fn kill_cursor(
    client: Client,
    drop_token: &mut crate::client::AsyncDropToken,
    ns: &Namespace,
    cursor_id: i64,
    pinned_conn: PinnedConnection,
    drop_address: Option<ServerAddress>,
    #[cfg(test)] kill_watcher: Option<oneshot::Sender<()>>,
) {
    let coll = client
        .database(ns.db.as_str())
        .collection::<Document>(ns.coll.as_str());
    drop_token.spawn(async move {
        if !pinned_conn.is_invalid() {
            let _ = coll
                .kill_cursor(cursor_id, pinned_conn.handle(), drop_address)
                .await;
            #[cfg(test)]
            if let Some(tx) = kill_watcher {
                let _ = tx.send(());
            }
        }
    });
}

pub(crate) fn reply_batch(
    reply: &RawDocument,
) -> Result<VecDeque<crate::bson::raw::RawDocumentBuf>> {
    let cursor = reply.get_document("cursor")?;
    let docs = match cursor.get("firstBatch")? {
        Some(d) => d
            .as_array()
            .ok_or_else(|| Error::invalid_response("invalid `firstBatch` value"))?,
        None => cursor.get_array("nextBatch")?,
    };
    let mut out = VecDeque::new();
    for elt in docs {
        out.push_back(
            elt?.as_document()
                .ok_or_else(|| Error::invalid_response("invalid cursor batch item"))?
                .to_owned(),
        );
    }
    Ok(out)
}
