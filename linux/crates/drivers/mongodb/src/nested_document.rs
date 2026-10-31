//! A cursor's documents, taken out only once their nesting is known.
//!
//! bson turns raw bytes into a `Document` by calling itself once per
//! level, and writing one out and dropping it do the same, so a document
//! nested deep enough would overflow the stack of the thread that reads
//! it.

use bson::Document;
use bson::raw::{RawBsonRef, RawDocument};
use mongodb::SessionCursor;
use tablepro_core::DriverError;

/// Deeper than MongoDB stores a document (100 levels), so only a hostile
/// server sends one.
const MAX_DEPTH: usize = 128;

/// The cursor's current document, refused when it nests deeper than
/// [`MAX_DEPTH`].
pub(crate) fn current_document(cursor: &SessionCursor<Document>) -> Result<Document, DriverError> {
    if !within_depth(cursor.current()) {
        return Err(DriverError::Decode {
            column: String::new(),
            detail: format!("the document nests deeper than {MAX_DEPTH} levels"),
        });
    }
    cursor.deserialize_current().map_err(|error| DriverError::Decode {
        column: String::new(),
        detail: error.to_string(),
    })
}

/// Walks the levels with a stack of its own, so the walk itself stays
/// off the thread's stack. A malformed element is left for bson to
/// report.
fn within_depth(document: &RawDocument) -> bool {
    let mut open = vec![document.iter_elements()];
    while let Some(elements) = open.last_mut() {
        let Some(element) = elements.next() else {
            open.pop();
            continue;
        };
        let nested = match element.and_then(|element| element.value()) {
            Ok(RawBsonRef::Document(inner)) => inner.iter_elements(),
            Ok(RawBsonRef::Array(inner)) => inner.iter_elements(),
            Ok(RawBsonRef::JavaScriptCodeWithScope(code)) => code.scope.iter_elements(),
            _ => continue,
        };
        if open.len() >= MAX_DEPTH {
            return false;
        }
        open.push(nested);
    }
    true
}

#[cfg(test)]
mod tests {
    use bson::{Bson, RawDocumentBuf, doc};

    use super::*;

    /// A document `levels` containers deep, the outer document included,
    /// arrays and documents in turn.
    fn nested(levels: usize) -> RawDocumentBuf {
        let mut value = Bson::Int32(1);
        for level in 1..levels {
            value = match level % 2 {
                0 => Bson::Document(doc! { "inner": value }),
                _ => Bson::Array(vec![value]),
            };
        }
        RawDocumentBuf::try_from(&doc! { "root": value }).unwrap()
    }

    #[test]
    fn a_document_at_the_limit_is_read() {
        assert!(within_depth(&nested(MAX_DEPTH)));
    }

    #[test]
    fn a_document_past_the_limit_is_refused() {
        assert!(!within_depth(&nested(MAX_DEPTH + 1)));
    }
}
