use std::{
    collections::HashSet,
    convert::TryFrom,
    io::{Read, Write},
};

use serde::Serialize;

#[cfg(feature = "bson-3")]
use crate::bson_compat::RawBsonRefExt as _;
use crate::{
    bson::{
        oid::ObjectId,
        rawdoc,
        Bson,
        Document,
        RawArrayBuf,
        RawBson,
        RawBsonRef,
        RawDocumentBuf,
    },
    bson_compat::CStr,
    checked::Checked,
    cmap::Command,
    error::{Error, ErrorKind, Result},
    runtime::SyncLittleEndianRead,
};

/// Coerce numeric types into an `i64` if it would be lossless to do so. If this Bson is not numeric
/// or the conversion would be lossy (e.g. 1.5 -> 1), this returns `None`.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn get_int(val: &Bson) -> Option<i64> {
    match *val {
        Bson::Int32(i) => Some(i64::from(i)),
        Bson::Int64(i) => Some(i),
        Bson::Double(f) if (f - (f as i64 as f64)).abs() <= f64::EPSILON => Some(f as i64),
        _ => None,
    }
}

/// Coerce numeric types into an `f64` if it would be lossless to do so. If this Bson is not numeric
/// or the conversion would be lossy (e.g. 1.5 -> 1), this returns `None`.
#[cfg(test)]
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn get_double(val: &Bson) -> Option<f64> {
    match *val {
        Bson::Int32(i) => Some(f64::from(i)),
        Bson::Int64(i) if i == i as f64 as i64 => Some(i as f64),
        Bson::Double(f) => Some(f),
        _ => None,
    }
}

/// Coerce numeric types into an `i64` if it would be lossless to do so. If this Bson is not numeric
/// or the conversion would be lossy (e.g. 1.5 -> 1), this returns `None`.
pub(crate) fn get_int_raw(val: RawBsonRef<'_>) -> Option<i64> {
    match val {
        RawBsonRef::Int32(i) => get_int(&Bson::Int32(i)),
        RawBsonRef::Int64(i) => get_int(&Bson::Int64(i)),
        RawBsonRef::Double(i) => get_int(&Bson::Double(i)),
        _ => None,
    }
}

#[allow(private_bounds)]
pub(crate) fn round_clamp<T: RoundClampTarget>(input: f64) -> T {
    T::round_clamp(input)
}

trait RoundClampTarget {
    fn round_clamp(input: f64) -> Self;
}

impl RoundClampTarget for u64 {
    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    fn round_clamp(input: f64) -> Self {
        input as u64
    }
}

impl RoundClampTarget for u32 {
    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    fn round_clamp(input: f64) -> Self {
        input as u32
    }
}

/// Coerce numeric types into an `u64` if it would be lossless to do so. If this Bson is not numeric
/// or the conversion would be lossy (e.g. 1.5 -> 1), this returns `None`.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn get_u64(val: &Bson) -> Option<u64> {
    match *val {
        Bson::Int32(i) => u64::try_from(i).ok(),
        Bson::Int64(i) => u64::try_from(i).ok(),
        Bson::Double(f) if (f - (round_clamp::<u64>(f) as f64)).abs() <= f64::EPSILON => {
            Some(round_clamp(f))
        }
        _ => None,
    }
}

pub(crate) fn get_u64_raw(val: &RawBsonRef) -> Option<u64> {
    match val {
        RawBsonRef::Int32(i) => get_u64(&Bson::Int32(*i)),
        RawBsonRef::Int64(i) => get_u64(&Bson::Int64(*i)),
        RawBsonRef::Double(i) => get_u64(&Bson::Double(*i)),
        _ => None,
    }
}

pub(crate) fn to_bson_array(docs: &[Document]) -> Bson {
    Bson::Array(docs.iter().map(|doc| Bson::Document(doc.clone())).collect())
}

pub(crate) fn to_raw_bson_array(docs: &[Document]) -> Result<RawBson> {
    let mut array = RawArrayBuf::new();
    for doc in docs {
        array.push(RawDocumentBuf::try_from(doc)?);
    }
    Ok(RawBson::Array(array))
}
pub(crate) fn to_raw_bson_array_ser<T: Serialize>(values: &[T]) -> Result<RawBson> {
    let mut array = RawArrayBuf::new();
    for value in values {
        array.push(crate::bson_compat::serialize_to_raw_document_buf(value)?);
    }
    Ok(RawBson::Array(array))
}

pub(crate) fn first_key(document: &Document) -> Option<&str> {
    document.keys().next().map(String::as_str)
}

pub(crate) fn update_document_check(update: &Document) -> Result<()> {
    match first_key(update) {
        Some(key) => {
            if !key.starts_with('$') {
                Err(ErrorKind::InvalidArgument {
                    message: "update document must only contain update modifiers".to_string(),
                }
                .into())
            } else {
                Ok(())
            }
        }
        None => Err(ErrorKind::InvalidArgument {
            message: "update document must not be empty".to_string(),
        }
        .into()),
    }
}

pub(crate) fn replacement_document_check(replacement: &Document) -> Result<()> {
    if let Some(key) = first_key(replacement) {
        if key.starts_with('$') {
            return Err(ErrorKind::InvalidArgument {
                message: "replacement document must not contain update modifiers".to_string(),
            }
            .into());
        }
    }
    Ok(())
}

pub(crate) fn replacement_raw_document_check(replacement: &RawDocumentBuf) -> Result<()> {
    if let Some((key, _)) = replacement.iter().next().transpose()? {
        if crate::bson_compat::cstr_to_str(key).starts_with('$') {
            return Err(ErrorKind::InvalidArgument {
                message: "replacement document must not contain update modifiers".to_string(),
            }
            .into());
        };
    }
    Ok(())
}

/// The size in bytes of the provided document's entry in a BSON array at the given index.
pub(crate) fn array_entry_size_bytes(index: usize, doc_len: usize) -> Result<usize> {
    //   * type (1 byte)
    //   * number of decimal digits in key
    //   * null terminator for the key (1 byte)
    //   * size of value

    (Checked::new(1) + num_decimal_digits(index) + 1 + doc_len).get()
}

pub(crate) fn vec_to_raw_array_buf(docs: Vec<RawDocumentBuf>) -> RawArrayBuf {
    let mut array = RawArrayBuf::new();
    for doc in docs {
        array.push(doc);
    }
    array
}

/// The number of digits in `n` in base 10.
/// Useful for calculating the size of an array entry in BSON.
fn num_decimal_digits(mut n: usize) -> usize {
    let mut digits = 0;

    loop {
        n /= 10;
        digits += 1;

        if n == 0 {
            return digits;
        }
    }
}

/// Read a document's raw BSON bytes from the provided reader.
pub(crate) fn read_document_bytes<R: Read>(mut reader: R) -> Result<Vec<u8>> {
    let length = Checked::new(reader.read_i32_sync()?);

    let mut bytes = Vec::with_capacity(length.try_into()?);
    bytes.write_all(&length.try_into::<u32>()?.to_le_bytes())?;

    reader
        .take((length - 4).try_into()?)
        .read_to_end(&mut bytes)?;

    Ok(bytes)
}

pub(crate) fn extend_raw_document_buf(
    this: &mut RawDocumentBuf,
    other: RawDocumentBuf,
) -> Result<()> {
    let mut keys: HashSet<crate::bson_compat::CString> = HashSet::new();
    for elem in this.iter_elements() {
        keys.insert(elem?.key().to_owned());
    }
    for result in other.iter() {
        let (k, v) = result?;
        if keys.contains(k) {
            return Err(Error::internal(format!("duplicate raw document key {k:?}")));
        }
        this.append(k, v.to_raw_bson());
    }
    Ok(())
}

/// Returns the _id field of this document, prepending the field to the document if one is not
/// already present.
pub(crate) fn get_or_prepend_id_field(doc: &mut RawDocumentBuf) -> Result<Bson> {
    match doc.get("_id")? {
        Some(id) => Ok(id.try_into()?),
        None => {
            let id = ObjectId::new();
            let mut new_bytes = rawdoc! { "_id": id }.into_bytes();

            // Remove the trailing null byte (which will be replaced by the null byte in the given
            // document) and append the document's elements
            new_bytes.pop();
            new_bytes.extend(&doc.as_bytes()[4..]);

            let new_length: i32 = Checked::new(new_bytes.len()).try_into()?;
            new_bytes[0..4].copy_from_slice(&new_length.to_le_bytes());

            *doc = RawDocumentBuf::from_bytes(new_bytes)?;

            Ok(id.into())
        }
    }
}

/// A helper trait for working with collections of raw documents. This is useful for unifying
/// command-building implementations that conditionally construct either document sequences or a
/// single command document.
pub(crate) trait RawDocumentCollection: Default {
    /// Calculates the total number of bytes that would be added to a collection of this type by the
    /// given document.
    fn bytes_added(index: usize, doc: &RawDocumentBuf) -> Result<usize>;

    /// Adds the given document to the collection.
    fn push(&mut self, doc: RawDocumentBuf);

    /// Adds the collection of raw documents to the provided command.
    fn add_to_command(self, identifier: &CStr, command: &mut Command);
}

impl RawDocumentCollection for Vec<RawDocumentBuf> {
    fn bytes_added(_index: usize, doc: &RawDocumentBuf) -> Result<usize> {
        Ok(doc.as_bytes().len())
    }

    fn push(&mut self, doc: RawDocumentBuf) {
        self.push(doc);
    }

    fn add_to_command(self, identifier: &CStr, command: &mut Command) {
        command.add_document_sequence(identifier, self);
    }
}

impl RawDocumentCollection for RawArrayBuf {
    fn bytes_added(index: usize, doc: &RawDocumentBuf) -> Result<usize> {
        array_entry_size_bytes(index, doc.as_bytes().len())
    }

    fn push(&mut self, doc: RawDocumentBuf) {
        self.push(doc);
    }

    fn add_to_command(self, identifier: &CStr, command: &mut Command) {
        command.body.append(identifier, self);
    }
}

pub(crate) mod option_u64_as_i64 {
    use serde::{Deserialize, Serialize};

    pub(crate) fn serialize<S: serde::Serializer>(
        value: &Option<u64>,
        s: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        let conv: Option<i64> = value
            .as_ref()
            .map(|&u| u.try_into())
            .transpose()
            .map_err(serde::ser::Error::custom)?;
        conv.serialize(s)
    }

    pub(crate) fn deserialize<'de, D: serde::Deserializer<'de>>(
        d: D,
    ) -> std::result::Result<Option<u64>, D::Error> {
        let conv = Option::<i64>::deserialize(d)?;
        conv.map(|i| i.try_into())
            .transpose()
            .map_err(serde::de::Error::custom)
    }
}

/// Truncates the given string at the closest UTF-8 character boundary >= the provided length.
/// If the new length is >= the current length, does nothing.
#[cfg(any(feature = "tracing-unstable", feature = "opentelemetry"))]
#[must_use]
pub(crate) fn truncate_on_char_boundary(s: &mut String, new_len: usize) -> bool {
    let original_len = s.len();
    if new_len >= original_len {
        return false;
    }

    // to avoid generating invalid UTF-8, find the first index >= max_length_bytes that is
    // the end of a character.
    // TODO: RUST-1496 we should use ceil_char_boundary here but it's currently nightly-only.
    // see: https://doc.rust-lang.org/std/string/struct.String.html#method.ceil_char_boundary
    let mut truncate_index = new_len;
    // is_char_boundary returns true when the provided value == the length of the string, so
    // if we reach the end of the string this loop will terminate.
    while !s.is_char_boundary(truncate_index) {
        truncate_index += 1;
    }
    s.truncate(truncate_index);
    // due to the "rounding up" behavior we might not actually end up truncating anything.
    truncate_index < original_len
}

#[cfg(feature = "tracing-unstable")]
pub(crate) fn rawdoc_to_json_str(
    doc: &crate::bson::RawDocument,
    max_length_bytes: usize,
) -> Result<String> {
    rawdoc_to_json_str_inner(doc, max_length_bytes, false)
}

#[cfg(feature = "opentelemetry")]
pub(crate) fn rawdoc_to_json_str_otel(
    doc: &crate::bson::RawDocument,
    max_length_bytes: usize,
) -> Result<String> {
    rawdoc_to_json_str_inner(doc, max_length_bytes, true)
}

#[cfg(any(feature = "tracing-unstable", feature = "opentelemetry"))]
pub(crate) fn doc_err(e: Error) -> String {
    serde_json::json!({
        "serialization error": e.to_string()
    })
    .to_string()
}

#[cfg(any(feature = "tracing-unstable", feature = "opentelemetry"))]
fn push_trunc(out: &mut String, max: usize, s: &str) -> bool {
    let new_len = out.len().saturating_add(s.len());
    if new_len <= max {
        out.push_str(s);
        return false;
    }

    let delta = max.abs_diff(new_len);
    let new_len = s.len().saturating_sub(delta);
    let mut s = s.to_owned();
    let _ = truncate_on_char_boundary(&mut s, new_len);
    out.push_str(&s);
    out.push_str("...");
    true
}

#[cfg(any(feature = "tracing-unstable", feature = "opentelemetry"))]
macro_rules! push_trunc {
    ($out:expr, $max:expr, $s:expr) => {{
        if push_trunc(&mut $out, $max, $s) {
            return Ok($out);
        }
    }};
}

#[cfg(any(feature = "tracing-unstable", feature = "opentelemetry"))]
fn rawdoc_to_json_str_inner(
    doc: &crate::bson::RawDocument,
    max_length_bytes: usize,
    otel: bool,
) -> Result<String> {
    use crate::bson_compat::cstr;

    let mut out = String::new();
    let mut stack = vec![]; // [(iter, is_array)]
    let mut current = doc.iter_elements();
    let mut is_array = false;
    let mut is_first = true;
    push_trunc!(out, max_length_bytes, "{");
    'outer: loop {
        while let Some(elt) = current.next() {
            let elt = elt?;
            let value = elt.value()?;
            // The opentelemetry spec requires omitting some toplevel fields.
            if otel && stack.is_empty() {
                if [
                    cstr!("lsid"),
                    cstr!("$db"),
                    cstr!("$clusterTime"),
                    cstr!("signature"),
                ]
                .iter()
                .any(|k| *k == elt.key())
                {
                    continue;
                }
            }

            if !is_first {
                push_trunc!(out, max_length_bytes, ",");
            }
            is_first = false;

            if !is_array {
                let key = serde_json::Value::String(
                    crate::bson_compat::cstr_to_str(elt.key()).to_owned(),
                )
                .to_string();
                push_trunc!(out, max_length_bytes, &key);
                push_trunc!(out, max_length_bytes, ":");
            }
            match value {
                RawBsonRef::Document(d) => {
                    push_trunc!(out, max_length_bytes, "{");
                    let mut tmp = d.iter_elements();
                    std::mem::swap(&mut current, &mut tmp);
                    stack.push((tmp, is_array));
                    is_array = false;
                    is_first = true;
                    continue 'outer;
                }
                RawBsonRef::Array(a) => {
                    push_trunc!(out, max_length_bytes, "[");
                    // bson 2.x doesn't have .iter_elements() on RawArray, so we have to jump
                    // through some hoops...
                    let mut tmp =
                        crate::bson::RawDocument::from_bytes(a.as_bytes())?.iter_elements();
                    std::mem::swap(&mut current, &mut tmp);
                    stack.push((tmp, is_array));
                    is_array = true;
                    is_first = true;
                    continue 'outer;
                }
                _ => {
                    let parsed: Bson = value.try_into()?;
                    push_trunc!(
                        out,
                        max_length_bytes,
                        &parsed.into_relaxed_extjson().to_string()
                    );
                }
            }
        }
        push_trunc!(out, max_length_bytes, if is_array { "]" } else { "}" });
        let Some(outer) = stack.pop() else {
            break;
        };
        current = outer.0;
        is_array = outer.1;
        is_first = false;
    }

    Ok(out)
}

#[cfg(test)]
mod test {
    use crate::bson_util::num_decimal_digits;

    #[test]
    fn num_digits() {
        assert_eq!(num_decimal_digits(0), 1);
        assert_eq!(num_decimal_digits(1), 1);
        assert_eq!(num_decimal_digits(10), 2);
        assert_eq!(num_decimal_digits(15), 2);
        assert_eq!(num_decimal_digits(100), 3);
        assert_eq!(num_decimal_digits(125), 3);
    }
}
