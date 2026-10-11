//! Defines types to use with Bloom filter commands.

use crate::errors::invalid_type_error;
use crate::{
    Commands, Connection, FromRedisValue, ParsingError, RedisResult, RedisWrite, ToRedisArgs,
    ToSingleRedisArg, Value,
};
use std::ops::Deref;

/// Specific type of information to query for Bloom filters
#[derive(Debug)]
#[non_exhaustive]
pub enum BloomFilterInfoType {
    /// Number of unique items the Bloom filter can hold before scaling would be required
    Capacity,
    /// Number of bytes allocated for the Bloom filter
    Size,
    /// Number of sub-filters of the Bloom filter
    Filters,
    /// Number of detected unique items added to the Bloom filter
    Items,
    /// Expansion rate of the Bloom filter
    Expansion,
    /// False positive rate of the Bloom filter
    ///
    /// Only available in `valkey-bloom`.
    Error,
    /// The tightening ration of the Bloom filter
    ///
    /// Only available for scaling Bloom filters in `valkey-bloom`
    Tightening,
    /// The maximum capacity the filter can expand to
    ///
    /// Only available for scaling Bloom filters in `valkey-bloom`
    MaximumScaledCapacity,
}

impl ToRedisArgs for BloomFilterInfoType {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match *self {
            Self::Capacity => {
                out.write_arg(b"CAPACITY");
            }
            Self::Expansion => {
                out.write_arg(b"EXPANSION");
            }
            Self::Filters => {
                out.write_arg(b"FILTERS");
            }
            Self::Items => {
                out.write_arg(b"ITEMS");
            }
            Self::Size => {
                out.write_arg(b"SIZE");
            }
            Self::Error => {
                out.write_arg(b"ERROR");
            }
            Self::Tightening => {
                out.write_arg(b"TIGHTENING");
            }
            Self::MaximumScaledCapacity => {
                out.write_arg(b"MAXSCALEDCAPACITY");
            }
        }
    }
}

impl ToSingleRedisArg for BloomFilterInfoType {}

/// Response of a Bloom filter info type query
///
/// `RESP2` and `RESP3` respond with different structures, so we need to abstract that difference
/// away to make the info type query usage simple. Note that it derefs to `f64` for ease of use.
#[derive(Debug, PartialEq)]
pub struct BloomFilterInfoTypeResponse {
    value: f64,
}

impl Deref for BloomFilterInfoTypeResponse {
    type Target = f64;

    fn deref(&self) -> &Self::Target {
        &self.value
    }
}

impl PartialEq<f64> for BloomFilterInfoTypeResponse {
    fn eq(&self, other: &f64) -> bool {
        self.value == *other
    }
}
impl FromRedisValue for BloomFilterInfoTypeResponse {
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        match v {
            // type-less `redisbloom` RESP2 query gives an array of exactly one `Int`
            Value::Array(items) => {
                let mut item_iter = items.into_iter();
                let Some(value) = item_iter.next() else {
                    invalid_type_error!("array has to hold exactly one element, but was empty");
                };

                if item_iter.next().is_some() {
                    invalid_type_error!(
                        "array has to hold exactly one element, but contained more"
                    );
                }

                Ok(Self {
                    value: f64::from_redis_value(value)?,
                })
            }

            // type-less `redisbloom` RESP3 query gives a map of exactly one pair of (`SimpleString`, `Int`)
            Value::Map(items) => {
                let mut item_iter = items.into_iter();
                let Some((_, value)) = item_iter.next() else {
                    invalid_type_error!("map has to hold exactly one element, but was empty");
                };

                if item_iter.next().is_some() {
                    invalid_type_error!("map holds more than a single value");
                }

                Ok(Self {
                    value: f64::from_redis_value(value)?,
                })
            }

            // `valkey-bloom`'s `EXPANSION` response to non-scaling keys is `Nil`
            Value::Nil => Ok(Self { value: 0. }),

            // typed `redisbloom` queries and `valkey-bloom` queries give an `Int` or `SimpleString` containing a float
            _ => Ok(Self {
                value: f64::from_redis_value(v)?,
            }),
        }
    }
}

/// Strategies for how a Bloom filter can scale to hold more items
#[derive(Debug)]
#[non_exhaustive]
pub enum BloomFilterScalingOptions {
    /// Specifies the desired expansion rate for the filter to be created.
    ExpansionRate(usize),
    /// Prevents the filter from creating additional sub-filters if initial capacity is reached.
    NonScaling,
}

impl ToRedisArgs for BloomFilterScalingOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match *self {
            Self::ExpansionRate(expansion) => {
                out.write_arg(b"EXPANSION");
                expansion.write_redis_args(out);
            }
            Self::NonScaling => {
                out.write_arg(b"NONSCALING");
            }
        }
    }
}

/// Options for inserting items to a Bloom filter
#[derive(Default, Debug)]
pub struct BloomFilterInsertOptions {
    create: Option<bool>,
    capacity: Option<usize>,
    error_rate: Option<f64>,
    expansion: Option<BloomFilterScalingOptions>,
}

impl BloomFilterInsertOptions {
    ///Indicates that the filter should not be created if it does not already exist.
    pub fn nocreate(mut self) -> Self {
        self.create = Some(false);
        self
    }

    /// Specifies the desired capacity for the filter to be created.
    pub fn expansion(mut self, scale_option: BloomFilterScalingOptions) -> Self {
        self.expansion = Some(scale_option);
        self
    }

    /// Specifies the error ratio of the newly created filter if it does not yet exist.
    pub fn error_rate(mut self, error_rate: f64) -> Self {
        self.error_rate = Some(error_rate);
        self
    }

    /// Specifies the desired capacity for the filter to be created.
    pub fn capacity(mut self, capacity: usize) -> Self {
        self.capacity = Some(capacity);
        self
    }
}
impl ToRedisArgs for BloomFilterInsertOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if Some(false) == self.create {
            out.write_arg(b"NOCREATE");
        }

        if let Some(ref error) = self.error_rate {
            out.write_arg(b"ERROR");
            error.write_redis_args(out);
        }

        if let Some(ref capacity) = self.capacity {
            out.write_arg(b"CAPACITY");
            capacity.write_redis_args(out);
        }

        if let Some(ref scaling) = self.expansion {
            scaling.write_redis_args(out);
        }
    }
}

/// Single chunk of a Bloom filter scan dump
#[derive(Debug, Clone, PartialEq)]
pub struct BloomFilterDumpChunk {
    /// The iterator associated to the [`data`](Self::data)
    pub iterator: i64,
    /// The chunked data
    pub data: Vec<u8>,
}

impl FromRedisValue for BloomFilterDumpChunk {
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        // `v` should be an array holding an Int (iterator) followed by BulkString (data).

        let Value::Array(items) = v else {
            invalid_type_error!(v, "expected array response");
        };

        let mut items_iter = items.into_iter();

        // Extract the iterator
        let item = items_iter.next();
        let Some(Value::Int(iterator)) = item else {
            invalid_type_error!(item, "expected first element to be integer");
        };

        // Extract the data
        let item = items_iter.next();
        let Some(Value::BulkString(data)) = item else {
            invalid_type_error!(item, "expected second element to be a Bulk string");
        };

        // `items_iter` should be empty now, so we guard against upstream additions
        if items_iter.next().is_some() {
            invalid_type_error!("expected only two elements");
        }

        // Yield the chunk
        Ok(Self { iterator, data })
    }
}

/// An iterator performing a Bloom filter scan dump
///
/// # Examples
///
/// ```rust,no_run
/// # fn dump() -> redis::RedisResult<()> {
/// let client = redis::Client::open("redis://127.0.0.1/")?;
/// let mut con = client.get_connection()?;
///
/// // Fully dump the bloom filter at key `foo`
/// let full_dump = redis::bloom::BloomFilterDumpIterator::new(&mut con, "foo")
///     .map(|r| r.expect("dump should succeed"))
///     .collect::<Vec<_>>();
/// # Ok(())
/// # }
/// ```
pub struct BloomFilterDumpIterator<'a> {
    con: &'a mut Connection,
    key: &'a str,
    iterator: i64,
    /// `true`, iff the iterator cannot produce more elements.
    dry: bool,
}

impl<'a> BloomFilterDumpIterator<'a> {
    /// Create a new iterator for the given key
    pub fn new(con: &'a mut Connection, key: &'a str) -> Self {
        BloomFilterDumpIterator {
            con,
            key,
            iterator: 0,
            dry: false,
        }
    }
}

impl Iterator for BloomFilterDumpIterator<'_> {
    type Item = RedisResult<BloomFilterDumpChunk>;

    #[inline]
    fn next(&mut self) -> Option<Self::Item> {
        if self.dry {
            return None;
        }
        let dump_result: Self::Item = self.con.bf_scandump(self.key, self.iterator);
        match dump_result {
            Ok(ref dump) => {
                self.iterator = dump.iterator;
                if dump.iterator == 0 {
                    self.dry = true;
                    return None;
                }
                Some(dump_result)
            }

            Err(e) => {
                self.dry = true;
                Some(Err(e))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BloomFilterDumpChunk, BloomFilterInfoTypeResponse};
    use crate::FromRedisValue;
    use crate::types::Value;

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from wrong type gives a useful error
    #[test]
    fn info_type_response_from_value_wrong_type() {
        // The value to try to parse from.
        // An `Array` or `Map` or something convertible to a float is expected, but it is text,
        // so conversion should fail.
        let value = Value::SimpleString("foo".to_string());

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("string"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a too short RESP2 response gives a useful error
    #[test]
    fn info_type_response_from_value_array_missing_item() {
        // The value to try to parse from.
        // An `Array` response should have exactly 1 entry. Here we have 0, so the conversion should fail.
        let value = Value::Array(vec![]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("empty"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a too long RESP2 response gives a useful error
    #[test]
    fn info_type_response_from_value_array_extra_item() {
        // The value to try to parse from.
        // An `Array` response should have exactly 1 entry. Here we have 2, so the conversion should fail.
        let value = Value::Array(vec![Value::Int(42), Value::Int(23)]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("more"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a faulty RESP2 response gives a useful error
    #[test]
    fn info_type_response_from_value_array_wrong_type() {
        // The value to try to parse from.
        // An `Array` response should have exactly 1 `Int`. Here we have an `Okay` instead, so the conversion should fail.
        let value = Value::Array(vec![Value::Okay]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("not convertible"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a too short RESP3 response gives a useful error
    #[test]
    fn info_type_response_from_value_map_missing_item() {
        // The value to try to parse from.
        // A `Map` response should have exactly 1 entry. Here we have 0, so the conversion should fail.
        let value = Value::Map(vec![]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("empty"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a too long RESP3 response gives a useful error
    #[test]
    fn info_type_response_from_value_map_extra_item() {
        // The value to try to parse from.
        // A `Map` response should have exactly 1 entry. Here we have 2, so the conversion should fail.
        let value = Value::Map(vec![
            (Value::SimpleString("foo".to_string()), Value::Int(42)),
            (Value::SimpleString("bar".to_string()), Value::Int(23)),
        ]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("more"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a faulty RESP3 response gives a useful error
    #[test]
    fn info_type_response_from_value_map_wrong_type() {
        // The value to try to parse from.
        // A `Map` response should have exactly entry mapping to `Int`. Here we have an `Okay`
        // instead, so the conversion should fail.
        let value = Value::Map(vec![(Value::SimpleString("foo".to_string()), Value::Okay)]);

        // Actual parsing
        let err = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("not convertible"));
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a good RESP2 response works
    #[test]
    fn info_type_response_from_value_ok_resp2() {
        // The value to try to parse from.
        // A good RESP2 Response is an `Array` of a single `Int`.
        let value = Value::Array(vec![Value::Int(42)]);

        // Actual parsing
        let response = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect("conversion should succeed");

        // Checking the response
        assert_eq!(*response, 42.);
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a good RESP3 response works
    #[test]
    fn info_type_response_from_value_ok_resp3() {
        // The value to try to parse from.
        // A good RESP3 Response is an `Map` of a single `SimpleString`, `Int` pair.
        let value = Value::Map(vec![(
            Value::SimpleString("foo".to_string()),
            Value::Int(42),
        )]);

        // Actual parsing
        let response = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect("conversion should succeed");

        // Checking the response
        assert_eq!(*response, 42.);
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from an integer succeeds
    #[test]
    fn info_type_response_from_value_ok_int() {
        // The value to try to parse from.
        let value = Value::Int(42);

        // Actual parsing
        let response = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect("conversion should succeed");

        // Checking the response
        assert_eq!(*response, 42.);
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a String encoded float succeeds
    #[test]
    fn info_type_response_from_value_ok_float_in_string() {
        // The value to try to parse from.
        let value = Value::SimpleString("42.4711".to_string());

        // Actual parsing
        let response = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect("conversion should succeed");

        // Checking the response
        assert_eq!(*response, 42.4711);
    }

    /// Tries to assure that [`BloomFilterInfoTypeResponse`] conversion from a `Nil` succeeds
    #[test]
    fn info_type_response_from_value_ok_nil() {
        // The value to try to parse from.
        let value = Value::Nil;

        // Actual parsing
        let response = BloomFilterInfoTypeResponse::from_redis_value(value)
            .expect("conversion should succeed");

        // Checking the response
        assert_eq!(*response, 0.);
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion from non-array gives a useful error
    #[test]
    fn dump_chunk_from_value_no_array() {
        // The value to try to parse from.
        // An `Array` is expected, but it is an `Int`, so conversion should fail.
        let value = Value::Int(42);

        // Actual parsing
        let err =
            BloomFilterDumpChunk::from_redis_value(value).expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("expected array"));
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion from mistyped first array element gives a useful error
    #[test]
    fn dump_chunk_from_value_first_item_wrong_type() {
        // The value to try to parse from.
        // The first element should be an `Int`, but is an `Ok`, so conversion should fail.
        let value = Value::Array(vec![
            Value::Okay,
            Value::BulkString("bar".as_bytes().to_vec()),
        ]);

        // Actual parsing
        let err =
            BloomFilterDumpChunk::from_redis_value(value).expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("expected first"));
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion from mistyped second array element gives a useful error
    #[test]
    fn dump_chunk_from_value_second_item_wrong_type() {
        // The value to try to parse from.
        // The second element should be a `BulkString`, but is an `Ok`, so conversion should fail.
        let value = Value::Array(vec![Value::Int(42), Value::Okay]);

        // Actual parsing
        let err =
            BloomFilterDumpChunk::from_redis_value(value).expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("expected second"));
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion from too short array gives a useful error
    #[test]
    fn dump_chunk_from_value_missing_item() {
        // The value to try to parse from.
        // The array should have two elements, but has only one, so conversion should fail.
        let value = Value::Array(vec![Value::Int(42)]);

        // Actual parsing
        let err =
            BloomFilterDumpChunk::from_redis_value(value).expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("expected second"));
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion from too long array gives a useful error
    #[test]
    fn dump_chunk_from_value_extra_item() {
        // The value to try to parse from.
        // The array should have two elements, but has only one, so conversion should fail.
        let value = Value::Array(vec![
            Value::Int(42),
            Value::BulkString("foo".as_bytes().to_vec()),
            Value::Okay,
        ]);

        // Actual parsing
        let err =
            BloomFilterDumpChunk::from_redis_value(value).expect_err("conversion should fail");

        // Checking the error message
        assert!(err.to_string().contains("expected only"));
    }

    /// Tries to assure that [`BloomFilterDumpChunk`] conversion can succeed
    #[test]
    fn dump_chunk_from_value_ok() {
        // The value to try to parse from.
        let value = Value::Array(vec![
            Value::Int(42),
            Value::BulkString("foo".as_bytes().to_vec()),
        ]);

        // Actual parsing
        let chunk =
            BloomFilterDumpChunk::from_redis_value(value).expect("conversion should succeed");

        // Checking the returned chunk
        let expected = BloomFilterDumpChunk {
            iterator: 42,
            data: "foo".as_bytes().to_vec(),
        };
        assert_eq!(chunk, expected);
    }
}
