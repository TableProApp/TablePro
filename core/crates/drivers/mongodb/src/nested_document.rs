//! Owned BSON values recurse when formatted or dropped, so cursor
//! documents need a depth bound before those operations.

use bson::raw::{RawBsonRef, RawDocument, RawIter};
use bson::{Bson, Document, JavaScriptCodeWithScope};
use mongodb::SessionCursor;
use tablepro_core::DriverError;

/// Leaves room above MongoDB's 100-level storage limit.
const MAX_DEPTH: usize = 128;

pub(crate) fn current_document(cursor: &SessionCursor<Document>) -> Result<Document, DriverError> {
    decode_document(cursor.current())
}

fn decode_document(raw: &RawDocument) -> Result<Document, DriverError> {
    let mut open = vec![Frame {
        elements: raw.iter_elements(),
        key: "",
        kind: ContainerKind::Document,
        values: Vec::new(),
    }];
    while let Some(frame) = open.last_mut() {
        let Some(element) = frame.elements.next() else {
            let Some(completed) = open.pop() else { break };
            if open.is_empty() {
                return Ok(completed.into_document());
            }
            let key = completed.key;
            if let Some(parent) = open.last_mut() {
                parent.values.push((key, completed.into_value()));
            }
            continue;
        };
        let element = element.map_err(decode_error)?;
        let key = element.key().as_str();
        // Borrow containers: direct BSON conversion copies their remaining
        // raw bytes at each level, while Serde can exhaust a worker stack.
        let (elements, kind) = match element.value().map_err(decode_error)? {
            RawBsonRef::Document(document) => (document.iter_elements(), ContainerKind::Document),
            RawBsonRef::Array(array) => (array.iter_elements(), ContainerKind::Array),
            RawBsonRef::JavaScriptCodeWithScope(code) => (code.scope.iter_elements(), ContainerKind::Scope(code.code)),
            scalar => {
                frame.values.push((key, Bson::try_from(scalar).map_err(decode_error)?));
                continue;
            }
        };
        if open.len() >= MAX_DEPTH {
            return Err(decode_error(format!(
                "the document nests deeper than {MAX_DEPTH} levels"
            )));
        }
        open.push(Frame {
            elements,
            key,
            kind,
            values: Vec::new(),
        });
    }
    Err(decode_error("the document has no outer container"))
}

fn decode_error(error: impl std::fmt::Display) -> DriverError {
    DriverError::Decode {
        column: String::new(),
        detail: error.to_string(),
    }
}

struct Frame<'a> {
    elements: RawIter<'a>,
    key: &'a str,
    kind: ContainerKind<'a>,
    values: Vec<(&'a str, Bson)>,
}

#[derive(Clone, Copy)]
enum ContainerKind<'a> {
    Document,
    Array,
    Scope(&'a str),
}

impl Frame<'_> {
    fn into_document(self) -> Document {
        self.values
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect()
    }

    fn into_value(self) -> Bson {
        match self.kind {
            ContainerKind::Document => Bson::Document(self.into_document()),
            ContainerKind::Array => Bson::Array(self.values.into_iter().map(|(_, value)| value).collect()),
            ContainerKind::Scope(code) => Bson::JavaScriptCodeWithScope(JavaScriptCodeWithScope {
                code: code.to_owned(),
                scope: self.into_document(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use bson::raw::{RawArrayBuf, RawBson, RawJavaScriptCodeWithScope, cstr};
    use bson::{RawDocumentBuf, doc};

    use super::*;

    #[derive(Clone, Copy)]
    enum Shape {
        Alternating,
        Documents,
        Arrays,
        Scopes,
    }

    fn nested_value(levels: usize, shape: Shape, mut value: RawBson) -> RawDocumentBuf {
        for level in 1..levels {
            value = match (shape, level % 2) {
                (Shape::Arrays, _) | (Shape::Alternating, 1) => {
                    let mut array = RawArrayBuf::new();
                    array.push(value.as_raw_bson_ref());
                    RawBson::Array(array)
                }
                (Shape::Scopes, _) => {
                    let mut scope = RawDocumentBuf::new();
                    scope.append(cstr!("inner"), value.as_raw_bson_ref());
                    RawBson::JavaScriptCodeWithScope(RawJavaScriptCodeWithScope {
                        code: "return inner".to_owned(),
                        scope,
                    })
                }
                _ => {
                    let mut document = RawDocumentBuf::new();
                    document.append(cstr!("inner"), value.as_raw_bson_ref());
                    RawBson::Document(document)
                }
            };
        }
        let mut document = RawDocumentBuf::new();
        document.append(cstr!("root"), value.as_raw_bson_ref());
        document
    }

    fn nested(levels: usize) -> RawDocumentBuf {
        nested_value(levels, Shape::Alternating, RawBson::Int32(1))
    }

    #[test]
    fn a_document_at_the_limit_is_read() {
        assert!(decode_document(&nested(MAX_DEPTH)).is_ok());
    }

    #[test]
    fn a_document_past_the_limit_is_refused() {
        assert!(matches!(
            decode_document(&nested(MAX_DEPTH + 1)),
            Err(DriverError::Decode { .. })
        ));
    }

    #[test]
    fn a_document_at_the_limit_is_read_and_written_on_a_worker_stack() {
        let raw = nested(MAX_DEPTH);
        let worker = std::thread::Builder::new().stack_size(2 << 20);
        let handle = worker
            .spawn(move || {
                let document = decode_document(&raw).unwrap();
                let written = crate::extended_json::extended_json(&Bson::Document(document));
                assert_eq!(written.matches(['{', '[']).count(), MAX_DEPTH, "{written}");
            })
            .unwrap();
        handle.join().unwrap();
    }

    #[test]
    fn every_container_shape_fits_a_worker_stack_at_supported_depths() {
        for levels in [100, MAX_DEPTH] {
            for shape in [Shape::Documents, Shape::Arrays, Shape::Alternating, Shape::Scopes] {
                let raw = nested_value(levels, shape, RawBson::Int32(1));
                std::thread::Builder::new()
                    .stack_size(2 << 20)
                    .spawn(move || {
                        let document = decode_document(&raw).unwrap();
                        let written = crate::extended_json::extended_json(&Bson::Document(document));
                        let containers = match shape {
                            Shape::Scopes => 1 + 2 * (levels - 1),
                            _ => levels,
                        };
                        assert_eq!(written.matches(['{', '[']).count(), containers);
                    })
                    .unwrap()
                    .join()
                    .unwrap();
            }
        }
    }

    #[test]
    fn every_container_shape_is_refused_past_the_limit() {
        for shape in [Shape::Documents, Shape::Arrays, Shape::Alternating, Shape::Scopes] {
            let raw = nested_value(MAX_DEPTH + 1, shape, RawBson::Int32(1));
            assert!(matches!(decode_document(&raw), Err(DriverError::Decode { .. })));
        }
    }

    #[test]
    fn a_large_value_in_deep_scopes_is_read_and_written_on_a_worker_stack() {
        let bytes = 1 << 20;
        let raw = nested_value(MAX_DEPTH, Shape::Scopes, RawBson::String("x".repeat(bytes)));
        std::thread::Builder::new()
            .stack_size(2 << 20)
            .spawn(move || {
                let document = decode_document(&raw).unwrap();
                let written = crate::extended_json::extended_json(&Bson::Document(document));
                assert_eq!(written.bytes().filter(|byte| *byte == b'x').count(), bytes);
                assert_eq!(written.matches('{').count(), 1 + 2 * (MAX_DEPTH - 1));
            })
            .unwrap()
            .join()
            .unwrap();
    }

    #[test]
    fn decoding_keeps_field_order_and_bson_types() {
        let expected = doc! {
            "z": 1_i32,
            "a": 2_i64,
            "date": bson::DateTime::from_millis(123),
            "nested": [true, null, { "last": "value" }],
        };
        let raw = RawDocumentBuf::try_from(&expected).unwrap();
        let decoded = decode_document(&raw).unwrap();
        assert_eq!(decoded, expected);
        assert_eq!(
            decoded.keys().map(String::as_str).collect::<Vec<_>>(),
            ["z", "a", "date", "nested"]
        );
    }

    #[test]
    fn a_malformed_nested_value_returns_a_decode_error() {
        let raw = RawDocumentBuf::try_from(&doc! { "value": 1 }).unwrap();
        let mut bytes = raw.as_bytes().to_vec();
        bytes[4] = 0x42;
        let malformed = RawDocumentBuf::from_bytes(bytes).unwrap();
        let mut outer = RawDocumentBuf::new();
        outer.append(cstr!("nested"), RawBsonRef::Document(&malformed));
        assert!(matches!(decode_document(&outer), Err(DriverError::Decode { .. })));
    }
}
