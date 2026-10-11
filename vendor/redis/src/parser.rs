use std::{
    io::{self, Read},
    str,
};

use crate::errors::{ParsingError, RedisError, Repr, ServerError, ServerErrorKind};
use crate::types::{PushKind, RedisResult, Value, VerbatimFormat};

use combine::{
    ParseError, Parser as _, any,
    error::StreamError,
    opaque,
    parser::{
        byte::{crlf, take_until_bytes},
        combinator::{AnySendSyncPartialState, any_send_sync_partial_state},
        range::{recognize, take},
    },
    stream::{
        PointerOffset, RangeStream, StreamErrorFor,
        decoder::{self, Decoder},
    },
    unexpected_any,
};

const MAX_RECURSE_DEPTH: usize = 100;

fn err_parser(line: &str) -> ServerError {
    let mut pieces = line.splitn(2, ' ');
    let kind = match pieces.next().unwrap() {
        "ERR" => ServerErrorKind::ResponseError,
        "EXECABORT" => ServerErrorKind::ExecAbort,
        "LOADING" => ServerErrorKind::BusyLoading,
        "NOSCRIPT" => ServerErrorKind::NoScript,
        "MOVED" => ServerErrorKind::Moved,
        "ASK" => ServerErrorKind::Ask,
        "TRYAGAIN" => ServerErrorKind::TryAgain,
        "CLUSTERDOWN" => ServerErrorKind::ClusterDown,
        "CROSSSLOT" => ServerErrorKind::CrossSlot,
        "MASTERDOWN" => ServerErrorKind::MasterDown,
        "READONLY" => ServerErrorKind::ReadOnly,
        "NOTBUSY" => ServerErrorKind::NotBusy,
        "NOSUB" => ServerErrorKind::NoSub,
        "NOPERM" => ServerErrorKind::NoPerm,
        code => {
            return ServerError(Repr::Extension {
                code: code.into(),
                detail: pieces.next().map(|str| str.into()),
            });
        }
    };
    let detail = pieces.next().map(|str| str.into());
    ServerError(Repr::Known { kind, detail })
}

pub fn get_push_kind(kind: String) -> PushKind {
    match kind.as_str() {
        "invalidate" => PushKind::Invalidate,
        "message" => PushKind::Message,
        "pmessage" => PushKind::PMessage,
        "smessage" => PushKind::SMessage,
        "unsubscribe" => PushKind::Unsubscribe,
        "punsubscribe" => PushKind::PUnsubscribe,
        "sunsubscribe" => PushKind::SUnsubscribe,
        "subscribe" => PushKind::Subscribe,
        "psubscribe" => PushKind::PSubscribe,
        "ssubscribe" => PushKind::SSubscribe,
        _ => PushKind::Other(kind),
    }
}

fn value<'a, I>(
    count: Option<usize>,
) -> impl combine::Parser<I, Output = Value, PartialState = AnySendSyncPartialState>
where
    I: RangeStream<Token = u8, Range = &'a [u8]>,
    I::Error: combine::ParseError<u8, &'a [u8], I::Position>,
{
    let count = count.unwrap_or(1);

    opaque!(any_send_sync_partial_state(
        any()
            .then_partial(move |&mut b| {
                if count > MAX_RECURSE_DEPTH {
                    combine::unexpected_any("Maximum recursion depth exceeded").left()
                } else {
                    combine::value(b).right()
                }
            })
            .then_partial(move |&mut b| {
                let line = || {
                    recognize(take_until_bytes(&b"\r\n"[..]).with(take(2).map(|_| ()))).and_then(
                        |line: &[u8]| {
                            str::from_utf8(&line[..line.len() - 2])
                                .map_err(StreamErrorFor::<I>::other)
                        },
                    )
                };

                let simple_string = || {
                    line().map(|line| {
                        if line == "OK" {
                            Value::Okay
                        } else {
                            Value::SimpleString(line.into())
                        }
                    })
                };

                let int = || {
                    line().and_then(|line| {
                        line.trim().parse::<i64>().map_err(|_| {
                            StreamErrorFor::<I>::message_static_message(
                                "Expected integer, got garbage",
                            )
                        })
                    })
                };

                let bulk_string = || {
                    int().then_partial(move |size| {
                        if *size < 0 {
                            combine::produce(|| Value::Nil).left()
                        } else {
                            take(*size as usize)
                                .map(|bs: &[u8]| Value::BulkString(bs.to_vec()))
                                .skip(crlf())
                                .right()
                        }
                    })
                };
                let blob = || {
                    int().then_partial(move |size| {
                        take(*size as usize)
                            .map(|bs: &[u8]| String::from_utf8_lossy(bs).to_string())
                            .skip(crlf())
                    })
                };

                let array = || {
                    int().then_partial(move |&mut length| {
                        if length < 0 {
                            combine::produce(|| Value::Nil).left()
                        } else {
                            let length = length as usize;
                            combine::count_min_max(length, length, value(Some(count + 1)))
                                .map(Value::Array)
                                .right()
                        }
                    })
                };

                let error = || line().map(err_parser);
                let map = || {
                    int().then_partial(move |&mut kv_length| {
                        match (kv_length as usize).checked_mul(2) {
                            Some(length) => {
                                combine::count_min_max(length, length, value(Some(count + 1)))
                                    .map(move |result: Vec<Value>| {
                                        let mut it = result.into_iter();
                                        let mut x = vec![];
                                        for _ in 0..kv_length {
                                            if let (Some(k), Some(v)) = (it.next(), it.next()) {
                                                x.push((k, v));
                                            }
                                        }
                                        Value::Map(x)
                                    })
                                    .left()
                            }
                            None => {
                                unexpected_any("Attribute key-value length is too large").right()
                            }
                        }
                    })
                };
                let attribute = || {
                    int().then_partial(move |&mut kv_length| {
                        match (kv_length as usize).checked_mul(2) {
                            Some(length) => {
                                // + 1 is for data!
                                let length = length + 1;
                                combine::count_min_max(length, length, value(Some(count + 1)))
                                    .map(move |result: Vec<Value>| {
                                        let mut it = result.into_iter();
                                        let mut attributes = vec![];
                                        for _ in 0..kv_length {
                                            if let (Some(k), Some(v)) = (it.next(), it.next()) {
                                                attributes.push((k, v));
                                            }
                                        }
                                        Value::Attribute {
                                            data: Box::new(it.next().unwrap()),
                                            attributes,
                                        }
                                    })
                                    .left()
                            }
                            None => {
                                unexpected_any("Attribute key-value length is too large").right()
                            }
                        }
                    })
                };
                let set = || {
                    int().then_partial(move |&mut length| {
                        if length < 0 {
                            combine::produce(|| Value::Nil).left()
                        } else {
                            let length = length as usize;
                            combine::count_min_max(length, length, value(Some(count + 1)))
                                .map(Value::Set)
                                .right()
                        }
                    })
                };
                let push = || {
                    int().then_partial(move |&mut length| {
                        if length <= 0 {
                            combine::produce(|| Value::Push {
                                kind: PushKind::Other("".to_string()),
                                data: vec![],
                            })
                            .left()
                        } else {
                            let length = length as usize;
                            combine::count_min_max(length, length, value(Some(count + 1)))
                                .and_then(|result: Vec<Value>| {
                                    let mut it = result.into_iter();
                                    let first = it.next().unwrap_or(Value::Nil);
                                    if let Value::BulkString(kind) = first {
                                        let push_kind = String::from_utf8(kind)
                                            .map_err(StreamErrorFor::<I>::other)?;
                                        Ok(Value::Push {
                                            kind: get_push_kind(push_kind),
                                            data: it.collect(),
                                        })
                                    } else if let Value::SimpleString(kind) = first {
                                        Ok(Value::Push {
                                            kind: get_push_kind(kind),
                                            data: it.collect(),
                                        })
                                    } else {
                                        Err(StreamErrorFor::<I>::message_static_message(
                                            "parse error when decoding push",
                                        ))
                                    }
                                })
                                .right()
                        }
                    })
                };
                let null = || line().map(|_| Value::Nil);
                let double = || {
                    line().and_then(|line| {
                        line.trim()
                            .parse::<f64>()
                            .map_err(StreamErrorFor::<I>::other)
                    })
                };
                let boolean = || {
                    line().and_then(|line: &str| match line {
                        "t" => Ok(true),
                        "f" => Ok(false),
                        _ => Err(StreamErrorFor::<I>::message_static_message(
                            "Expected boolean, got garbage",
                        )),
                    })
                };
                let blob_error = || blob().map(|line| err_parser(&line));
                let verbatim = || {
                    blob().and_then(|line| {
                        if let Some((format, text)) = line.split_once(':') {
                            let format = match format {
                                "txt" => VerbatimFormat::Text,
                                "mkd" => VerbatimFormat::Markdown,
                                x => VerbatimFormat::Unknown(x.to_string()),
                            };
                            Ok(Value::VerbatimString {
                                format,
                                text: text.to_string(),
                            })
                        } else {
                            Err(StreamErrorFor::<I>::message_static_message(
                                "parse error when decoding verbatim string",
                            ))
                        }
                    })
                };
                let big_number = || {
                    line().and_then(|line| {
                        #[cfg(not(feature = "num-bigint"))]
                        return Ok::<_, StreamErrorFor<I>>(Value::BigNumber(
                            line.as_bytes().to_vec(),
                        ));
                        #[cfg(feature = "num-bigint")]
                        num_bigint::BigInt::parse_bytes(line.as_bytes(), 10)
                            .ok_or_else(|| {
                                StreamErrorFor::<I>::message_static_message(
                                    "Expected bigint, got garbage",
                                )
                            })
                            .map(Value::BigNumber)
                    })
                };
                combine::dispatch!(b;
                    b'+' => simple_string(),
                    b':' => int().map(Value::Int),
                    b'$' => bulk_string(),
                    b'*' => array(),
                    b'%' => map(),
                    b'|' => attribute(),
                    b'~' => set(),
                    b'-' => error().map(Value::ServerError),
                    b'_' => null(),
                    b',' => double().map(Value::Double),
                    b'#' => boolean().map(Value::Boolean),
                    b'!' => blob_error().map(Value::ServerError),
                    b'=' => verbatim(),
                    b'(' => big_number(),
                    b'>' => push(),
                    b => combine::unexpected_any(combine::error::Token(b))
                )
            })
    ))
}

// a macro is needed because of lifetime shenanigans with `decoder`.
macro_rules! to_redis_err {
    ($err: expr, $decoder: expr) => {
        match $err {
            decoder::Error::Io { error, .. } => error.into(),
            decoder::Error::Parse(err) => {
                if err.is_unexpected_end_of_input() {
                    RedisError::from(io::Error::from(io::ErrorKind::UnexpectedEof))
                } else {
                    let err = err
                        .map_range(|range| format!("{range:?}"))
                        .map_position(|pos| pos.translate_position($decoder.buffer()))
                        .to_string();
                    RedisError::from(ParsingError::from(err))
                }
            }
        }
    };
}

#[cfg(feature = "aio")]
mod aio_support {
    use super::*;

    use bytes::{Buf, BytesMut};
    use tokio::io::AsyncRead;
    use tokio_util::codec::{Decoder, Encoder};

    #[derive(Default)]
    pub struct ValueCodec {
        state: AnySendSyncPartialState,
    }

    impl ValueCodec {
        fn decode_stream(&mut self, bytes: &mut BytesMut, eof: bool) -> RedisResult<Option<Value>> {
            let (opt, removed_len) = {
                let buffer = &bytes[..];
                let mut stream =
                    combine::easy::Stream(combine::stream::MaybePartialStream(buffer, !eof));
                match combine::stream::decode_tokio(value(None), &mut stream, &mut self.state) {
                    Ok(x) => x,
                    Err(err) => {
                        let err = err
                            .map_position(|pos| pos.translate_position(buffer))
                            .map_range(|range| format!("{range:?}"))
                            .to_string();
                        return Err(RedisError::from(ParsingError::from(err)));
                    }
                }
            };

            bytes.advance(removed_len);
            match opt {
                Some(result) => Ok(Some(result)),
                None => Ok(None),
            }
        }
    }

    impl Encoder<Vec<u8>> for ValueCodec {
        type Error = RedisError;
        fn encode(&mut self, item: Vec<u8>, dst: &mut BytesMut) -> Result<(), Self::Error> {
            dst.extend_from_slice(item.as_ref());
            Ok(())
        }
    }

    impl Decoder for ValueCodec {
        type Item = Value;
        type Error = RedisError;

        fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
            self.decode_stream(src, false)
        }

        fn decode_eof(&mut self, buf: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
            self.decode_stream(buf, true)
        }
    }

    /// Parses a redis value asynchronously.
    pub async fn parse_redis_value_async<R>(
        decoder: &mut combine::stream::Decoder<AnySendSyncPartialState, PointerOffset<[u8]>>,
        read: &mut R,
    ) -> RedisResult<Value>
    where
        R: AsyncRead + std::marker::Unpin,
    {
        let result = combine::decode_tokio!(*decoder, *read, value(None), |input, _| {
            combine::stream::easy::Stream::from(input)
        });
        match result {
            Err(err) => Err(to_redis_err!(err, decoder)),
            Ok(result) => Ok(result),
        }
    }
}

#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
pub use self::aio_support::*;

/// The internal redis response parser.
pub struct Parser {
    decoder: Decoder<AnySendSyncPartialState, PointerOffset<[u8]>>,
}

impl Default for Parser {
    fn default() -> Self {
        Self::new()
    }
}

/// The parser can be used to parse redis responses into values.  Generally
/// you normally do not use this directly as it's already done for you by
/// the client but in some more complex situations it might be useful to be
/// able to parse the redis responses.
impl Parser {
    /// Creates a new parser that parses the data behind the reader.  More
    /// than one value can be behind the reader in which case the parser can
    /// be invoked multiple times.  In other words: the stream does not have
    /// to be terminated.
    pub fn new() -> Self {
        Self {
            decoder: Decoder::new(),
        }
    }

    // public api

    /// Parses synchronously into a single value from the reader.
    pub fn parse_value<T: Read>(&mut self, mut reader: T) -> RedisResult<Value> {
        let mut decoder = &mut self.decoder;
        let result = combine::decode!(decoder, reader, value(None), |input, _| {
            combine::stream::easy::Stream::from(input)
        });
        match result {
            Err(err) => Err(to_redis_err!(err, decoder)),
            Ok(result) => Ok(result),
        }
    }
}

/// Parses bytes into a redis value.
///
/// This is the most straightforward way to parse something into a low
/// level redis value instead of having to use a whole parser.
pub fn parse_redis_value(bytes: &[u8]) -> RedisResult<Value> {
    let mut parser = Parser::new();
    parser.parse_value(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::ErrorKind;
    use assert_matches::assert_matches;

    #[cfg(feature = "aio")]
    #[test]
    fn decode_eof_returns_none_at_eof() {
        use tokio_util::codec::Decoder;
        let mut codec = ValueCodec::default();

        let mut bytes = bytes::BytesMut::from(&b"+GET 123\r\n"[..]);
        assert_eq!(
            codec.decode_eof(&mut bytes),
            Ok(Some(parse_redis_value(b"+GET 123\r\n").unwrap()))
        );
        assert_eq!(codec.decode_eof(&mut bytes), Ok(None));
        assert_eq!(codec.decode_eof(&mut bytes), Ok(None));
    }

    #[cfg(feature = "aio")]
    #[test]
    fn decode_eof_returns_error_inside_array_and_can_parse_more_inputs() {
        use tokio_util::codec::Decoder;
        let mut codec = ValueCodec::default();

        let mut bytes =
            bytes::BytesMut::from(b"*3\r\n+OK\r\n-LOADING server is loading\r\n+OK\r\n".as_slice());
        let result = codec.decode_eof(&mut bytes).unwrap().unwrap();

        assert_eq!(
            result,
            Value::Array(vec![
                Value::Okay,
                Value::ServerError(ServerError(Repr::Known {
                    kind: ServerErrorKind::BusyLoading,
                    detail: Some(arcstr::literal!("server is loading"))
                })),
                Value::Okay
            ])
        );

        let mut bytes = bytes::BytesMut::from(b"+OK\r\n".as_slice());
        let result = codec.decode_eof(&mut bytes).unwrap().unwrap();

        assert_eq!(result, Value::Okay);
    }

    #[test]
    fn parse_nested_error_and_handle_more_inputs() {
        // from https://redis.io/docs/interact/transactions/ -
        // "EXEC returned two-element bulk string reply where one is an OK code and the other an error reply. It's up to the client library to find a sensible way to provide the error to the user."

        let bytes = b"*3\r\n+OK\r\n-LOADING server is loading\r\n+OK\r\n";
        let result = parse_redis_value(bytes);

        assert_eq!(
            result.unwrap(),
            Value::Array(vec![
                Value::Okay,
                Value::ServerError(ServerError(Repr::Known {
                    kind: ServerErrorKind::BusyLoading,
                    detail: Some(arcstr::literal!("server is loading"))
                })),
                Value::Okay
            ])
        );

        let result = parse_redis_value(b"+OK\r\n").unwrap();

        assert_eq!(result, Value::Okay);
    }

    #[test]
    fn decode_resp3_double() {
        let val = parse_redis_value(b",1.23\r\n").unwrap();
        assert_eq!(val, Value::Double(1.23));
        let val = parse_redis_value(b",nan\r\n").unwrap();
        if let Value::Double(val) = val {
            assert!(val.is_sign_positive());
            assert!(val.is_nan());
        } else {
            panic!("expected double");
        }
        // -nan is supported prior to redis 7.2
        let val = parse_redis_value(b",-nan\r\n").unwrap();
        if let Value::Double(val) = val {
            assert!(val.is_sign_negative());
            assert!(val.is_nan());
        } else {
            panic!("expected double");
        }
        //Allow doubles in scientific E notation
        let val = parse_redis_value(b",2.67923e+8\r\n").unwrap();
        assert_eq!(val, Value::Double(267923000.0));
        let val = parse_redis_value(b",2.67923E+8\r\n").unwrap();
        assert_eq!(val, Value::Double(267923000.0));
        let val = parse_redis_value(b",-2.67923E+8\r\n").unwrap();
        assert_eq!(val, Value::Double(-267923000.0));
        let val = parse_redis_value(b",2.1E-2\r\n").unwrap();
        assert_eq!(val, Value::Double(0.021));

        let val = parse_redis_value(b",-inf\r\n").unwrap();
        assert_eq!(val, Value::Double(-f64::INFINITY));
        let val = parse_redis_value(b",inf\r\n").unwrap();
        assert_eq!(val, Value::Double(f64::INFINITY));
    }

    #[test]
    fn decode_resp3_map() {
        let val = parse_redis_value(b"%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n").unwrap();
        let mut v = val.as_map_iter().unwrap();
        assert_eq!(
            (&Value::SimpleString("first".to_string()), &Value::Int(1)),
            v.next().unwrap()
        );
        assert_eq!(
            (&Value::SimpleString("second".to_string()), &Value::Int(2)),
            v.next().unwrap()
        );
    }

    #[test]
    fn decode_resp3_boolean() {
        let val = parse_redis_value(b"#t\r\n").unwrap();
        assert_eq!(val, Value::Boolean(true));
        let val = parse_redis_value(b"#f\r\n").unwrap();
        assert_eq!(val, Value::Boolean(false));
        let val = parse_redis_value(b"#x\r\n");
        assert_matches!(val, Err(_));
        let val = parse_redis_value(b"#\r\n");
        assert_matches!(val, Err(_));
    }

    #[test]
    fn decode_resp3_blob_error() {
        let val = parse_redis_value(b"!21\r\nSYNTAX invalid syntax\r\n");
        assert_eq!(
            val.unwrap(),
            Value::ServerError(ServerError(Repr::Extension {
                code: arcstr::literal!("SYNTAX"),
                detail: Some(arcstr::literal!("invalid syntax"))
            }))
        );
    }

    #[test]
    fn decode_resp3_big_number() {
        let val = parse_redis_value(b"(3492890328409238509324850943850943825024385\r\n").unwrap();
        #[cfg(feature = "num-bigint")]
        let expected = Value::BigNumber(
            num_bigint::BigInt::parse_bytes(b"3492890328409238509324850943850943825024385", 10)
                .unwrap(),
        );
        #[cfg(not(feature = "num-bigint"))]
        let expected = Value::BigNumber(b"3492890328409238509324850943850943825024385".to_vec());
        assert_eq!(val, expected);
    }

    #[test]
    fn decode_resp3_set() {
        let val = parse_redis_value(b"~5\r\n+orange\r\n+apple\r\n#t\r\n:100\r\n:999\r\n").unwrap();
        let v = val.as_sequence().unwrap();
        assert!(v.len() >= 5);
        assert_eq!(Value::SimpleString("orange".to_string()), v[0]);
        assert_eq!(Value::SimpleString("apple".to_string()), v[1]);
        assert_eq!(Value::Boolean(true), v[2]);
        assert_eq!(Value::Int(100), v[3]);
        assert_eq!(Value::Int(999), v[4]);
    }

    #[test]
    fn decode_resp3_push() {
        let val = parse_redis_value(b">3\r\n+message\r\n+somechannel\r\n+this is the message\r\n")
            .unwrap();
        if let Value::Push { ref kind, ref data } = val {
            assert_eq!(&PushKind::Message, kind);
            assert_eq!(Value::SimpleString("somechannel".to_string()), data[0]);
            assert_eq!(
                Value::SimpleString("this is the message".to_string()),
                data[1]
            );
        } else {
            panic!("Expected Value::Push")
        }
    }

    #[test]
    fn test_max_recursion_depth_set_and_array() {
        for test_byte in ["*", "~"] {
            let initial = format!("{test_byte}1\r\n").as_bytes().to_vec();
            let end = format!("{test_byte}0\r\n").as_bytes().to_vec();

            let mut ba = initial.repeat(MAX_RECURSE_DEPTH - 1).to_vec();
            ba.extend(end.clone());
            match parse_redis_value(&ba) {
                Ok(Value::Array(a)) => assert_eq!(a.len(), 1),
                Ok(Value::Set(s)) => assert_eq!(s.len(), 1),
                _ => panic!("Expected valid array or set"),
            }

            let mut ba = initial.repeat(MAX_RECURSE_DEPTH).to_vec();
            ba.extend(end);
            match parse_redis_value(&ba) {
                Ok(_) => panic!("Expected ParseError"),
                Err(e) => assert_matches!(e.kind(), ErrorKind::Parse),
            }
        }
    }

    #[test]
    fn test_max_recursion_depth_map() {
        let initial = b"%1\r\n+a\r\n";
        let end = b"%0\r\n";

        let mut ba = initial.repeat(MAX_RECURSE_DEPTH - 1).to_vec();
        ba.extend(*end);
        match parse_redis_value(&ba) {
            Ok(Value::Map(m)) => assert_eq!(m.len(), 1),
            Ok(Value::Set(s)) => assert_eq!(s.len(), 1),
            _ => panic!("Expected valid array or set"),
        }

        let mut ba = initial.repeat(MAX_RECURSE_DEPTH).to_vec();
        ba.extend(end);
        match parse_redis_value(&ba) {
            Ok(_) => panic!("Expected ParseError"),
            Err(e) => assert_matches!(e.kind(), ErrorKind::Parse),
        }
    }
}
