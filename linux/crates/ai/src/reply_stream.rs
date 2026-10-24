use std::time::Duration;

use futures_util::StreamExt;
use http::Method;
use sse_stream::SseStream;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::protocol::Protocol;
use crate::reply::Usage;
use crate::{AiClient, AiError, ChatRequest, Endpoint, ReplyEnd, ReplyEvent, StopReason, anthropic, openai};

/// A model that thinks before it writes sends pings meanwhile, so a
/// silence this long is a dead connection.
const IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// The longest reply kept, in bytes. A chat answer is a few thousand.
const MAX_REPLY_BYTES: usize = 512 * 1024;
/// The most the stream itself may carry: each piece of text comes
/// wrapped in an event of its own, many times its size.
const MAX_STREAM_BYTES: usize = 32 * 1024 * 1024;

/// Stream one reply into `events`: its text as it comes, then
/// `Finished` or `Failed`. A cancel ends it with neither, and a closed
/// receiver stops it.
pub async fn stream_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
    cancel: CancellationToken,
    events: mpsc::UnboundedSender<ReplyEvent>,
) {
    let mut on_text = |text: String| events.send(ReplyEvent::Text(text)).is_ok();
    let outcome = tokio::select! {
        biased;
        () = cancel.cancelled() => return,
        outcome = read_reply(client, endpoint, request, &mut on_text) => outcome,
    };
    let last = match outcome {
        Ok(end) => ReplyEvent::Finished(end),
        Err(error) => ReplyEvent::Failed(error),
    };
    // The receiver may be gone already, which only means no one waits.
    let _ = events.send(last);
}

/// The whole reply at once, for a suggestion nobody watches being
/// written.
pub async fn collect_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
) -> Result<(String, ReplyEnd), AiError> {
    let mut text = String::new();
    let mut on_text = |part: String| {
        text.push_str(&part);
        true
    };
    let end = read_reply(client, endpoint, request, &mut on_text).await?;
    Ok((text, end))
}

async fn read_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
    on_text: &mut (dyn FnMut(String) -> bool + Send),
) -> Result<ReplyEnd, AiError> {
    if endpoint.model().is_empty() {
        return Err(AiError::MissingModel);
    }
    let protocol = Protocol::of(endpoint.kind());
    let (path, body) = match protocol {
        Protocol::AnthropicMessages => {
            // A model that writes less than asked for refuses the request.
            let max_tokens = crate::model_list::output_limit(client, endpoint)
                .await
                .map_or(request.max_tokens, |limit| limit.min(request.max_tokens));
            (
                "/messages",
                serde_json::to_vec(&anthropic::request_body(endpoint.model(), request, max_tokens, true)),
            )
        }
        Protocol::ChatCompletions => (
            "/chat/completions",
            serde_json::to_vec(&openai::request_body(endpoint.kind(), endpoint.model(), request, true)),
        ),
    };
    let body = body.map_err(|error| AiError::Protocol(error.to_string()))?;
    let response = client
        .send(endpoint, Method::POST, path, Some(body), "text/event-stream")
        .await?;
    // Bounded before parsing, so a server that never ends a line cannot
    // fill memory with it.
    let body = http_body_util::BodyExt::map_err(
        http_body_util::Limited::new(response.into_body(), MAX_STREAM_BYTES),
        BodyError,
    );
    let mut events = SseStream::new(body);
    let mut reading = Reading::default();
    loop {
        let next = tokio::time::timeout(IDLE_TIMEOUT, events.next())
            .await
            .map_err(|_| AiError::TimedOut {
                host: endpoint.host().to_owned(),
            })?;
        let Some(event) = next else {
            return reading.ended(protocol);
        };
        let event = event.map_err(|error| match error {
            sse_stream::Error::Body(cause)
                if cause
                    .downcast_ref::<BodyError>()
                    .is_some_and(|error| error.0.is::<http_body_util::LengthLimitError>()) =>
            {
                AiError::TooLong
            }
            sse_stream::Error::Body(cause) => AiError::Unreachable {
                host: endpoint.host().to_owned(),
                detail: crate::http_client::error_chain(cause.as_ref()),
            },
            other => AiError::Protocol(other.to_string()),
        })?;
        let Some(data) = event.data else {
            continue;
        };
        let done = match protocol {
            Protocol::AnthropicMessages => reading.anthropic(&data, on_text)?,
            Protocol::ChatCompletions => reading.chat_completions(&data, on_text)?,
        };
        if done || reading.abandoned {
            return Ok(reading.end);
        }
    }
}

/// The limited body's error, as a type the event parser takes.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct BodyError(Box<dyn std::error::Error + Send + Sync>);

#[derive(Default)]
struct Reading {
    end: ReplyEnd,
    bytes: usize,
    /// A finish reason arrived, which some compatible servers send as
    /// their last word without `[DONE]`.
    finished: bool,
    /// The receiver went away, so nothing more is read.
    abandoned: bool,
}

impl Reading {
    fn anthropic(&mut self, data: &str, on_text: &mut (dyn FnMut(String) -> bool + Send)) -> Result<bool, AiError> {
        for step in anthropic::decode_event(data)? {
            match step {
                anthropic::Step::Text(text) => self.text(text, on_text)?,
                anthropic::Step::Usage(usage) => self.usage(usage),
                anthropic::Step::Stop(stop) => self.stop(stop),
                anthropic::Step::Done => return Ok(true),
                anthropic::Step::Ignore => {}
            }
        }
        Ok(false)
    }

    fn chat_completions(
        &mut self,
        data: &str,
        on_text: &mut (dyn FnMut(String) -> bool + Send),
    ) -> Result<bool, AiError> {
        if data.trim() == openai::DONE {
            return Ok(true);
        }
        for step in openai::decode_chunk(data)? {
            match step {
                openai::Step::Text(text) => self.text(text, on_text)?,
                openai::Step::Usage(usage) => self.usage(usage),
                openai::Step::Stop(stop) => self.stop(stop),
            }
        }
        Ok(false)
    }

    fn text(&mut self, text: String, on_text: &mut (dyn FnMut(String) -> bool + Send)) -> Result<(), AiError> {
        self.bytes += text.len();
        if self.bytes > MAX_REPLY_BYTES {
            return Err(AiError::TooLong);
        }
        if !on_text(text) {
            self.abandoned = true;
        }
        Ok(())
    }

    fn usage(&mut self, usage: Usage) {
        let kept = &mut self.end.usage;
        kept.input_tokens = usage.input_tokens.or(kept.input_tokens);
        kept.output_tokens = usage.output_tokens.or(kept.output_tokens);
    }

    fn stop(&mut self, stop: StopReason) {
        self.finished = true;
        // A refusal said in the text is not undone by the finish reason
        // that follows it.
        if self.end.stop != StopReason::Refused {
            self.end.stop = stop;
        }
    }

    /// The body ended. Anthropic always says `message_stop` first, so
    /// without it the connection was cut.
    fn ended(self, protocol: Protocol) -> Result<ReplyEnd, AiError> {
        match protocol {
            Protocol::ChatCompletions if self.finished => Ok(self.end),
            _ => Err(AiError::Protocol("the reply ended before it was complete".to_owned())),
        }
    }
}
