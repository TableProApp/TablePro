use std::time::Duration;

use crate::{
    bson::{rawdoc, Bson, RawBson},
    bson_compat::{cstr, CStr},
    checked::Checked,
    cmap::{conn::PinnedConnectionHandle, Command, RawCommandResponse, StreamDescription},
    cursor::common::{CursorInformation, CursorReply},
    error::Result,
    operation::{Base, BaseOperation, OperationImpl},
    options::SelectionCriteria,
    results::GetMoreResult,
    Namespace,
};

use super::ExecutionContext;

#[derive(Debug)]
pub(crate) struct GetMore<'conn> {
    ns: Namespace,
    cursor_id: i64,
    selection_criteria: SelectionCriteria,
    batch_size: Option<u32>,
    max_time: Option<Duration>,
    pinned_connection: Option<&'conn PinnedConnectionHandle>,
    comment: Option<Bson>,
}

impl<'conn> GetMore<'conn> {
    pub(crate) fn new(
        info: CursorInformation,
        pinned: Option<&'conn PinnedConnectionHandle>,
    ) -> Self {
        Self {
            ns: info.ns,
            cursor_id: info.id,
            selection_criteria: SelectionCriteria::from_address(info.address),
            batch_size: info.batch_size,
            max_time: info.max_time,
            pinned_connection: pinned,
            comment: info.comment,
        }
    }
}

impl BaseOperation for GetMore<'_> {
    type O = GetMoreResult;

    const NAME: &'static CStr = cstr!("getMore");

    const ZERO_COPY: bool = true;

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.cursor_id,
            "collection": self.ns.coll.clone(),
        };

        if let Some(batch_size) = self.batch_size {
            let batch_size = Checked::from(batch_size).try_into::<i32>()?;
            if batch_size != 0 {
                body.append(cstr!("batchSize"), batch_size);
            }
        }

        if let Some(ref max_time) = self.max_time {
            body.append(
                cstr!("maxTimeMS"),
                max_time.as_millis().try_into().unwrap_or(i32::MAX),
            );
        }

        if let Some(comment) = &self.comment {
            let raw_comment: RawBson = comment.clone().try_into()?;
            body.append(cstr!("comment"), raw_comment);
        }

        Ok(Command::from_operation(self, body))
    }

    fn handle_response_cow<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        // Extract minimal fields directly from the raw reply to avoid walking the batch via serde.
        let root = response.raw_body();
        let cursor = root.get_document("cursor")?;
        let CursorReply {
            id,
            ns,
            post_batch_resume_token,
        } = CursorReply::parse(cursor)?;

        // Take ownership of the raw bytes without copying.
        let raw = response.into_owned().into_raw_document_buf();

        Ok(GetMoreResult {
            raw_reply: raw,
            exhausted: id == 0,
            post_batch_resume_token,
            ns,
            id,
        })
    }

    fn is_backpressure_retryable(&self, options: &crate::options::ClientOptions) -> bool {
        options.retry_reads != Some(false)
    }

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        super::Feature::Set(&self.selection_criteria)
    }

    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
        self.pinned_connection
    }

    fn target(&self) -> super::OperationTarget {
        super::OperationTarget::Namespace(self.ns.clone())
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for GetMore<'_> {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for GetMore<'_> {
    #[cfg(feature = "opentelemetry")]
    fn cursor_id(&self) -> Option<i64> {
        Some(self.cursor_id)
    }
}

/*
#[derive(Debug, Deserialize)]
pub(crate) struct GetMoreResponseBody {
    cursor: NextBatchBody,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NextBatchBody {
    id: i64,
    next_batch: VecDeque<RawDocumentBuf>,
    post_batch_resume_token: Option<RawDocumentBuf>,
    ns: String,
}
*/
