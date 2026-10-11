use crate::errors::ParsingError;
#[cfg(feature = "ahash")]
pub(crate) use ahash::{AHashMap as HashMap, AHashSet as HashSet};
#[cfg(feature = "num-bigint")]
use num_bigint::BigInt;
use std::borrow::Cow;
#[cfg(not(feature = "ahash"))]
pub(crate) use std::collections::{HashMap, HashSet};
use std::default::Default;
use std::ffi::CString;
use std::fmt;
use std::hash::{BuildHasher, Hash};
use std::io;
use std::ops::Deref;
use std::str::from_utf8;

use crate::errors::{RedisError, ServerError};

/// Helper enum that is used to define expiry time
#[derive(Clone)]
#[non_exhaustive]
pub enum Expiry {
    /// EX seconds -- Set the specified expire time, in seconds.
    EX(u64),
    /// PX milliseconds -- Set the specified expire time, in milliseconds.
    PX(u64),
    /// EXAT timestamp-seconds -- Set the specified Unix time at which the key will expire, in seconds.
    EXAT(u64),
    /// PXAT timestamp-milliseconds -- Set the specified Unix time at which the key will expire, in milliseconds.
    PXAT(u64),
    /// PERSIST -- Remove the time to live associated with the key.
    PERSIST,
}

/// Helper enum that is used to define expiry time for SET command
#[derive(Clone, Copy)]
#[non_exhaustive]
pub enum SetExpiry {
    /// EX seconds -- Set the specified expire time, in seconds.
    EX(u64),
    /// PX milliseconds -- Set the specified expire time, in milliseconds.
    PX(u64),
    /// EXAT timestamp-seconds -- Set the specified Unix time at which the key will expire, in seconds.
    EXAT(u64),
    /// PXAT timestamp-milliseconds -- Set the specified Unix time at which the key will expire, in milliseconds.
    PXAT(u64),
    /// KEEPTTL -- Retain the time to live associated with the key.
    KEEPTTL,
}

impl ToRedisArgs for SetExpiry {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        let mut buf = ::itoa::Buffer::new();
        match self {
            Self::EX(secs) => {
                out.write_arg(b"EX");
                out.write_arg(buf.format(*secs).as_bytes());
            }
            Self::PX(millis) => {
                out.write_arg(b"PX");
                out.write_arg(buf.format(*millis).as_bytes());
            }
            Self::EXAT(unix_time) => {
                out.write_arg(b"EXAT");
                out.write_arg(buf.format(*unix_time).as_bytes());
            }
            Self::PXAT(unix_time) => {
                out.write_arg(b"PXAT");
                out.write_arg(buf.format(*unix_time).as_bytes());
            }
            Self::KEEPTTL => {
                out.write_arg(b"KEEPTTL");
            }
        }
    }
}

/// Helper enum that is used to define existence checks
#[derive(Clone, Copy)]
#[non_exhaustive]
pub enum ExistenceCheck {
    /// NX -- Only set the key if it does not already exist.
    NX,
    /// XX -- Only set the key if it already exists.
    XX,
}

impl ToRedisArgs for ExistenceCheck {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::NX => {
                out.write_arg(b"NX");
            }
            Self::XX => {
                out.write_arg(b"XX");
            }
        }
    }
}

/// Helper enum that is used to define field existence checks
#[derive(Clone, Copy)]
#[non_exhaustive]
pub enum FieldExistenceCheck {
    /// FNX -- Only set the fields if all do not already exist.
    FNX,
    /// FXX -- Only set the fields if all already exist.
    FXX,
}

impl ToRedisArgs for FieldExistenceCheck {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::FNX => out.write_arg(b"FNX"),
            Self::FXX => out.write_arg(b"FXX"),
        }
    }
}

/// Helper enum that is used in some situations to describe
/// the behavior of arguments in a numeric context.
#[derive(PartialEq, Eq, Clone, Debug, Copy)]
#[non_exhaustive]
pub enum NumericBehavior {
    /// This argument is not numeric.
    NonNumeric,
    /// This argument is an integer.
    NumberIsInteger,
    /// This argument is a floating point value.
    NumberIsFloat,
}

/// Internal low-level redis value enum.
#[derive(PartialEq, Clone, Default)]
#[non_exhaustive]
pub enum Value {
    /// A nil response from the server.
    #[default]
    Nil,
    /// An integer response.  Note that there are a few situations
    /// in which redis actually returns a string for an integer which
    /// is why this library generally treats integers and strings
    /// the same for all numeric responses.
    Int(i64),
    /// An arbitrary binary data, usually represents a binary-safe string.
    BulkString(Vec<u8>),
    /// A response containing an array with more data. This is generally used by redis
    /// to express nested structures.
    Array(Vec<Self>),
    /// A simple string response, without line breaks and not binary safe.
    SimpleString(String),
    /// A status response which represents the string "OK".
    Okay,
    /// Unordered key,value list from the server. Use `as_map_iter` function.
    Map(Vec<(Self, Self)>),
    /// Attribute value from the server. Client will give data instead of whole Attribute type.
    Attribute {
        /// Data that attributes belong to.
        data: Box<Self>,
        /// Key,Value list of attributes.
        attributes: Vec<(Self, Self)>,
    },
    /// Unordered set value from the server.
    Set(Vec<Self>),
    /// A floating number response from the server.
    Double(f64),
    /// A boolean response from the server.
    Boolean(bool),
    /// First String is format and other is the string
    VerbatimString {
        /// Text's format type
        format: VerbatimFormat,
        /// Remaining string check format before using!
        text: String,
    },
    #[cfg(feature = "num-bigint")]
    /// Very large number that out of the range of the signed 64 bit numbers
    BigNumber(BigInt),
    #[cfg(not(feature = "num-bigint"))]
    /// Very large number that out of the range of the signed 64 bit numbers
    BigNumber(Vec<u8>),
    /// Push data from the server.
    Push {
        /// Push Kind
        kind: PushKind,
        /// Remaining data from push message
        data: Vec<Self>,
    },
    /// Represents an error message from the server
    ServerError(ServerError),
}

/// Helper enum that is used to define comparisons between values and their digests
///
/// # Example
/// ```rust
/// use redis::ValueComparison;
///
/// // Create comparisons using constructor methods
/// let eq_comparison = ValueComparison::ifeq("my_value");
/// let ne_comparison = ValueComparison::ifne("other_value");
/// let deq_comparison = ValueComparison::ifdeq("digest_hash");
/// let dne_comparison = ValueComparison::ifdne("other_digest");
/// ```
#[derive(Clone, Debug)]
#[non_exhaustive]
pub enum ValueComparison {
    /// Value is equal
    IFEQ(String),
    /// Value is not equal
    IFNE(String),
    /// Value's digest is equal
    IFDEQ(String),
    /// Value's digest is not equal
    IFDNE(String),
}

impl ValueComparison {
    /// Create a new IFEQ (if equal) comparison
    ///
    /// Performs the operation only if the key's current value is equal to the provided value.
    ///
    /// For SET: Sets the key only if its current value matches. Non-existent keys are not created.
    /// For DEL_EX: Deletes the key only if its current value matches. Non-existent keys are ignored.
    pub fn ifeq(value: impl ToSingleRedisArg) -> Self {
        Self::IFEQ(Self::arg_to_string(value))
    }

    /// Create a new IFNE (if not equal) comparison
    ///
    /// Performs the operation only if the key's current value is not equal to the provided value.
    ///
    /// For SET: Sets the key only if its current value doesn't match. Non-existent keys are created.
    /// For DEL_EX: Deletes the key only if its current value doesn't match. Non-existent keys are ignored.
    pub fn ifne(value: impl ToSingleRedisArg) -> Self {
        Self::IFNE(Self::arg_to_string(value))
    }

    /// Create a new IFDEQ (if digest equal) comparison
    ///
    /// Performs the operation only if the digest of the key's current value is equal to the provided digest.
    ///
    /// For SET: Sets the key only if its current value's digest matches. Non-existent keys are not created.
    /// For DEL_EX: Deletes the key only if its current value's digest matches. Non-existent keys are ignored.
    ///
    /// Use [`calculate_value_digest`] to compute the digest of a value.
    pub fn ifdeq(digest: impl ToSingleRedisArg) -> Self {
        Self::IFDEQ(Self::arg_to_string(digest))
    }

    /// Create a new IFDNE (if digest not equal) comparison
    ///
    /// Performs the operation only if the digest of the key's current value is not equal to the provided digest.
    ///
    /// For SET: Sets the key only if its current value's digest doesn't match. Non-existent keys are created.
    /// For DEL_EX: Deletes the key only if its current value's digest doesn't match. Non-existent keys are ignored.
    ///
    /// Use [`calculate_value_digest`] to compute the digest of a value.
    pub fn ifdne(digest: impl ToSingleRedisArg) -> Self {
        Self::IFDNE(Self::arg_to_string(digest))
    }

    fn arg_to_string(value: impl ToSingleRedisArg) -> String {
        let args = value.to_redis_args();
        String::from_utf8_lossy(&args[0]).into_owned()
    }
}

impl ToRedisArgs for ValueComparison {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::IFEQ(value) => {
                out.write_arg(b"IFEQ");
                out.write_arg(value.as_bytes());
            }
            Self::IFNE(value) => {
                out.write_arg(b"IFNE");
                out.write_arg(value.as_bytes());
            }
            Self::IFDEQ(digest) => {
                out.write_arg(b"IFDEQ");
                out.write_arg(digest.as_bytes());
            }
            Self::IFDNE(digest) => {
                out.write_arg(b"IFDNE");
                out.write_arg(digest.as_bytes());
            }
        }
    }
}

/// `VerbatimString`'s format types defined by spec
#[derive(PartialEq, Clone, Debug)]
#[non_exhaustive]
pub enum VerbatimFormat {
    /// Unknown type to catch future formats.
    Unknown(String),
    /// `mkd` format
    Markdown,
    /// `txt` format
    Text,
}

/// `Push` type's currently known kinds.
#[derive(PartialEq, Clone, Debug)]
#[non_exhaustive]
pub enum PushKind {
    /// `Disconnection` is sent from the **library** when connection is closed.
    Disconnection,
    /// Other kind to catch future kinds.
    Other(String),
    /// `invalidate` is received when a key is changed/deleted.
    Invalidate,
    /// `message` is received when pubsub message published by another client.
    Message,
    /// `pmessage` is received when pubsub message published by another client and client subscribed to topic via pattern.
    PMessage,
    /// `smessage` is received when pubsub message published by another client and client subscribed to it with sharding.
    SMessage,
    /// `unsubscribe` is received when client unsubscribed from a channel.
    Unsubscribe,
    /// `punsubscribe` is received when client unsubscribed from a pattern.
    PUnsubscribe,
    /// `sunsubscribe` is received when client unsubscribed from a shard channel.
    SUnsubscribe,
    /// `subscribe` is received when client subscribed to a channel.
    Subscribe,
    /// `psubscribe` is received when client subscribed to a pattern.
    PSubscribe,
    /// `ssubscribe` is received when client subscribed to a shard channel.
    SSubscribe,
}

impl PushKind {
    #[cfg(feature = "aio")]
    pub(crate) fn has_reply(&self) -> bool {
        matches!(
            self,
            &Self::Unsubscribe
                | &Self::PUnsubscribe
                | &Self::SUnsubscribe
                | &Self::Subscribe
                | &Self::PSubscribe
                | &Self::SSubscribe
        )
    }
}

impl fmt::Display for VerbatimFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Markdown => write!(f, "mkd"),
            Self::Unknown(val) => write!(f, "{val}"),
            Self::Text => write!(f, "txt"),
        }
    }
}

impl fmt::Display for PushKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Other(kind) => write!(f, "{kind}"),
            Self::Invalidate => write!(f, "invalidate"),
            Self::Message => write!(f, "message"),
            Self::PMessage => write!(f, "pmessage"),
            Self::SMessage => write!(f, "smessage"),
            Self::Unsubscribe => write!(f, "unsubscribe"),
            Self::PUnsubscribe => write!(f, "punsubscribe"),
            Self::SUnsubscribe => write!(f, "sunsubscribe"),
            Self::Subscribe => write!(f, "subscribe"),
            Self::PSubscribe => write!(f, "psubscribe"),
            Self::SSubscribe => write!(f, "ssubscribe"),
            Self::Disconnection => write!(f, "disconnection"),
        }
    }
}

#[non_exhaustive]
pub enum MapIter<'a> {
    Array(std::slice::Iter<'a, Value>),
    Map(std::slice::Iter<'a, (Value, Value)>),
}

impl<'a> Iterator for MapIter<'a> {
    type Item = (&'a Value, &'a Value);

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            MapIter::Array(iter) => Some((iter.next()?, iter.next()?)),
            MapIter::Map(iter) => {
                let (k, v) = iter.next()?;
                Some((k, v))
            }
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        match self {
            MapIter::Array(iter) => iter.size_hint(),
            MapIter::Map(iter) => iter.size_hint(),
        }
    }
}

#[non_exhaustive]
pub enum OwnedMapIter {
    Array(std::vec::IntoIter<Value>),
    Map(std::vec::IntoIter<(Value, Value)>),
}

impl Iterator for OwnedMapIter {
    type Item = (Value, Value);

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::Array(iter) => Some((iter.next()?, iter.next()?)),
            Self::Map(iter) => iter.next(),
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        match self {
            Self::Array(iter) => {
                let (low, high) = iter.size_hint();
                (low / 2, high.map(|h| h / 2))
            }
            Self::Map(iter) => iter.size_hint(),
        }
    }
}

/// Values are generally not used directly unless you are using the
/// more low level functionality in the library.  For the most part
/// this is hidden with the help of the `FromRedisValue` trait.
///
/// While on the redis protocol there is an error type this is already
/// separated at an early point so the value only holds the remaining
/// types.
impl Value {
    /// Checks if the return value looks like it fulfils the cursor
    /// protocol.  That means the result is an array item of length
    /// two with the first one being a cursor and the second an
    /// array response.
    pub fn looks_like_cursor(&self) -> bool {
        match *self {
            Self::Array(ref items) => {
                if items.len() != 2 {
                    return false;
                }
                matches!(items[0], Self::BulkString(_)) && matches!(items[1], Self::Array(_))
            }
            _ => false,
        }
    }

    /// Returns an `&[Value]` if `self` is compatible with a sequence type
    pub fn as_sequence(&self) -> Option<&[Self]> {
        match self {
            Self::Array(items) | Self::Set(items) => Some(&items[..]),
            Self::Nil => Some(&[]),
            _ => None,
        }
    }

    /// Returns a `Vec<Value>` if `self` is compatible with a sequence type,
    /// otherwise returns `Err(self)`.
    pub fn into_sequence(self) -> Result<Vec<Self>, Self> {
        match self {
            Self::Array(items) | Self::Set(items) => Ok(items),
            Self::Nil => Ok(vec![]),
            _ => Err(self),
        }
    }

    /// Returns an iterator of `(&Value, &Value)` if `self` is compatible with a map type
    pub fn as_map_iter(&self) -> Option<MapIter<'_>> {
        match self {
            Self::Array(items) => (items.len() % 2 == 0).then(|| MapIter::Array(items.iter())),
            Self::Map(items) => Some(MapIter::Map(items.iter())),
            _ => None,
        }
    }

    /// Returns an iterator of `(Value, Value)` if `self` is compatible with a map type.
    /// If not, returns `Err(self)`.
    pub fn into_map_iter(self) -> Result<OwnedMapIter, Self> {
        match self {
            Self::Array(items) => {
                if items.len() % 2 == 0 {
                    Ok(OwnedMapIter::Array(items.into_iter()))
                } else {
                    Err(Self::Array(items))
                }
            }
            Self::Map(items) => Ok(OwnedMapIter::Map(items.into_iter())),
            _ => Err(self),
        }
    }

    /// If value contains a server error, return it as an Err. Otherwise wrap the value in Ok.
    pub fn extract_error(self) -> RedisResult<Self> {
        match self {
            Self::Array(val) => Ok(Self::Array(Self::extract_error_vec(val)?)),
            Self::Map(map) => Ok(Self::Map(Self::extract_error_map(map)?)),
            Self::Attribute { data, attributes } => {
                let data = Box::new((*data).extract_error()?);
                let attributes = Self::extract_error_map(attributes)?;
                Ok(Self::Attribute { data, attributes })
            }
            Self::Set(set) => Ok(Self::Set(Self::extract_error_vec(set)?)),
            Self::Push { kind, data } => Ok(Self::Push {
                kind,
                data: Self::extract_error_vec(data)?,
            }),
            Self::ServerError(err) => Err(err.into()),
            _ => Ok(self),
        }
    }

    pub(crate) fn extract_error_vec(vec: Vec<Self>) -> RedisResult<Vec<Self>> {
        vec.into_iter()
            .map(Self::extract_error)
            .collect::<RedisResult<Vec<_>>>()
    }

    pub(crate) fn extract_error_map(map: Vec<(Self, Self)>) -> RedisResult<Vec<(Self, Self)>> {
        let mut vec = Vec::with_capacity(map.len());
        for (key, value) in map.into_iter() {
            vec.push((key.extract_error()?, value.extract_error()?));
        }
        Ok(vec)
    }

    fn is_collection_of_len(&self, len: usize) -> bool {
        match self {
            Self::Array(values) | Self::Set(values) => values.len() == len,
            Self::Map(items) => items.len() * 2 == len,
            _ => false,
        }
    }

    #[cfg(feature = "cluster-async")]
    pub(crate) fn is_error_that_requires_action(&self) -> bool {
        matches!(self, Self::ServerError(error) if error.requires_action())
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Nil => write!(f, "nil"),
            Self::Int(val) => write!(f, "int({val:?})"),
            Self::BulkString(ref val) => match from_utf8(val) {
                Ok(x) => write!(f, "bulk-string('{x:?}')"),
                Err(_) => write!(f, "binary-data({val:?})"),
            },
            Self::Array(ref values) => write!(f, "array({values:?})"),
            Self::Push { ref kind, ref data } => write!(f, "push({kind:?}, {data:?})"),
            Self::Okay => write!(f, "ok"),
            Self::SimpleString(ref s) => write!(f, "simple-string({s:?})"),
            Self::Map(ref values) => write!(f, "map({values:?})"),
            Self::Attribute {
                ref data,
                attributes: _,
            } => write!(f, "attribute({data:?})"),
            Self::Set(ref values) => write!(f, "set({values:?})"),
            Self::Double(ref d) => write!(f, "double({d:?})"),
            Self::Boolean(ref b) => write!(f, "boolean({b:?})"),
            Self::VerbatimString {
                ref format,
                ref text,
            } => {
                write!(f, "verbatim-string({format:?},{text:?})")
            }
            Self::BigNumber(ref m) => write!(f, "big-number({m:?})"),
            Self::ServerError(ref err) => match err.details() {
                Some(details) => write!(f, "Server error: `{}: {details}`", err.code()),
                None => write!(f, "Server error: `{}`", err.code()),
            },
        }
    }
}

/// Library generic result type.
pub type RedisResult<T> = Result<T, RedisError>;

impl<T: FromRedisValue> FromRedisValue for RedisResult<T> {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        match v {
            Value::ServerError(err) => Ok(Err(err.clone().into())),
            _ => from_redis_value_ref(v).map(|result| Ok(result)),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        match v {
            Value::ServerError(err) => Ok(Err(err.into())),
            _ => from_redis_value(v).map(|result| Ok(result)),
        }
    }
}

/// Library generic future type.
#[cfg(feature = "aio")]
pub type RedisFuture<'a, T> = futures_util::future::BoxFuture<'a, RedisResult<T>>;

/// An info dictionary type for `INFO`s response.
///
/// This type provides convenient access to key/value data returned by
/// the `INFO` command.  It acts like a regular mapping but also has
/// a convenience method `get` which can return data in the appropriate
/// type.
///
/// For instance this can be used to query the server for the role it's
/// in (master, slave) etc:
///
/// # Caveats
///
/// As this struct internally uses a [`HashMap`], it only collects the last value for each key, if
/// they occur multiple times. So if a key occurs multiple times (e.g.: `module`), this struct holds
/// only its last value.
///
/// # Examples
///
/// ```rust,no_run
/// # fn do_something() -> redis::RedisResult<()> {
/// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
/// # let mut con = client.get_connection().unwrap();
/// let info : redis::InfoDict = redis::cmd("INFO").query(&mut con)?;
/// let role : Option<String> = info.get("role");
/// # Ok(()) }
/// ```
#[derive(Debug, Clone)]
pub struct InfoDict {
    map: HashMap<String, Value>,
}

impl InfoDict {
    /// Creates a new info dictionary from a string in the response of
    /// the INFO command.  Each line is a key, value pair with the
    /// key and value separated by a colon (`:`).  Lines starting with a
    /// hash (`#`) are ignored.
    pub fn new(kvpairs: &str) -> Self {
        let mut map = HashMap::new();
        for line in kvpairs.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut p = line.splitn(2, ':');
            let (k, v) = match (p.next(), p.next()) {
                (Some(k), Some(v)) => (k.to_string(), v.to_string()),
                _ => continue,
            };
            map.insert(k, Value::SimpleString(v));
        }
        Self { map }
    }

    /// Fetches a value by key and converts it into the given type.
    /// Typical types are `String`, `bool` and integer types.
    pub fn get<T: FromRedisValue>(&self, key: &str) -> Option<T> {
        match self.find(&key) {
            Some(x) => from_redis_value_ref(x).ok(),
            None => None,
        }
    }

    /// Looks up a key in the info dict.
    pub fn find(&self, key: &&str) -> Option<&Value> {
        self.map.get(*key)
    }

    /// Checks if a key is contained in the info dicf.
    pub fn contains_key(&self, key: &&str) -> bool {
        self.find(key).is_some()
    }

    /// Returns the size of the info dict.
    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// Checks if the dict is empty.
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

impl Deref for InfoDict {
    type Target = HashMap<String, Value>;

    fn deref(&self) -> &Self::Target {
        &self.map
    }
}

/// High level representation of response to the [`ROLE`][1] command.
///
/// [1]: https://redis.io/docs/latest/commands/role/
#[derive(Debug, Clone, Eq, PartialEq)]
#[non_exhaustive]
pub enum Role {
    /// Represents a primary role, which is `master` in legacy Redis terminology.
    Primary {
        /// The current primary replication offset
        replication_offset: u64,
        /// List of replica, each represented by a tuple of IP, port and the last acknowledged replication offset.
        replicas: Vec<ReplicaInfo>,
    },
    /// Represents a replica role, which is `slave` in legacy Redis terminology.
    Replica {
        /// The IP of the primary.
        primary_ip: String,
        /// The port of the primary.
        primary_port: u16,
        /// The state of the replication from the point of view of the primary.
        replication_state: String,
        /// The amount of data received from the replica so far in terms of primary replication offset.
        data_received: u64,
    },
    /// Represents a sentinel role.
    Sentinel {
        /// List of primary names monitored by this Sentinel instance.
        primary_names: Vec<String>,
    },
}

/// Replication information for a replica, as returned by the [`ROLE`][1] command.
///
/// [1]: https://redis.io/docs/latest/commands/role/
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ReplicaInfo {
    /// The IP of the replica.
    pub ip: String,
    /// The port of the replica.
    pub port: u16,
    /// The last acknowledged replication offset.
    pub replication_offset: i64,
}

impl FromRedisValue for ReplicaInfo {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        Self::from_redis_value(v.clone())
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = match get_owned_inner_value(v).into_sequence() {
            Ok(v) => v,
            Err(v) => crate::errors::invalid_type_error!(v, "Replica response should be an array"),
        };
        if v.len() < 3 {
            crate::errors::invalid_type_error!(
                v,
                "Replica array is too short, expected 3 elements"
            );
        }
        let mut v = v.into_iter();
        let ip = from_redis_value(v.next().expect("len was checked"))?;
        let port = from_redis_value(v.next().expect("len was checked"))?;
        let offset = from_redis_value(v.next().expect("len was checked"))?;
        Ok(Self {
            ip,
            port,
            replication_offset: offset,
        })
    }
}

impl FromRedisValue for Role {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        Self::from_redis_value(v.clone())
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = match get_owned_inner_value(v).into_sequence() {
            Ok(v) => v,
            Err(v) => crate::errors::invalid_type_error!(v, "Role response should be an array"),
        };
        if v.len() < 2 {
            crate::errors::invalid_type_error!(
                v,
                "Role array is too short, expected at least 2 elements"
            );
        }
        match &v[0] {
            Value::BulkString(role) => match role.as_slice() {
                b"master" => Self::new_primary(v),
                b"slave" => Self::new_replica(v),
                b"sentinel" => Self::new_sentinel(v),
                _ => crate::errors::invalid_type_error!(
                    v,
                    "Role type is not master, slave or sentinel"
                ),
            },
            _ => crate::errors::invalid_type_error!(v, "Role type is not a bulk string"),
        }
    }
}

impl Role {
    fn new_primary(values: Vec<Value>) -> Result<Self, ParsingError> {
        if values.len() < 3 {
            crate::errors::invalid_type_error!(
                values,
                "Role primary response too short, expected 3 elements"
            );
        }

        let mut values = values.into_iter();
        _ = values.next();

        let replication_offset = from_redis_value(values.next().expect("len was checked"))?;
        let replicas = from_redis_value(values.next().expect("len was checked"))?;

        Ok(Self::Primary {
            replication_offset,
            replicas,
        })
    }

    fn new_replica(values: Vec<Value>) -> Result<Self, ParsingError> {
        if values.len() < 5 {
            crate::errors::invalid_type_error!(
                values,
                "Role replica response too short, expected 5 elements"
            );
        }

        let mut values = values.into_iter();
        _ = values.next();

        let primary_ip = from_redis_value(values.next().expect("len was checked"))?;
        let primary_port = from_redis_value(values.next().expect("len was checked"))?;
        let replication_state = from_redis_value(values.next().expect("len was checked"))?;
        let data_received = from_redis_value(values.next().expect("len was checked"))?;

        Ok(Self::Replica {
            primary_ip,
            primary_port,
            replication_state,
            data_received,
        })
    }

    fn new_sentinel(values: Vec<Value>) -> Result<Self, ParsingError> {
        if values.len() < 2 {
            crate::errors::invalid_type_error!(
                values,
                "Role sentinel response too short, expected at least 2 elements"
            );
        }
        let second_val = values.into_iter().nth(1).expect("len was checked");
        let primary_names = from_redis_value(second_val)?;
        Ok(Self::Sentinel { primary_names })
    }
}

/// Abstraction trait for redis command abstractions.
pub trait RedisWrite {
    /// Accepts a serialized redis command.
    fn write_arg(&mut self, arg: &[u8]);

    /// Accepts a serialized redis command.
    fn write_arg_fmt(&mut self, arg: impl fmt::Display) {
        self.write_arg(arg.to_string().as_bytes());
    }

    /// Appends an empty argument to the command, and returns a
    /// [`std::io::Write`] instance that can write to it.
    ///
    /// Writing multiple arguments into this buffer is unsupported. The resulting
    /// data will be interpreted as one argument by Redis.
    ///
    /// Writing no data is supported and is similar to having an empty bytestring
    /// as an argument.
    fn writer_for_next_arg(&mut self) -> impl io::Write + '_;

    /// Reserve space for `additional` arguments in the command
    ///
    /// `additional` is a list of the byte sizes of the arguments.
    ///
    /// # Examples
    /// Sending some Protobufs with `prost` to Redis.
    /// ```rust,ignore
    /// use prost::Message;
    ///
    /// let to_send: Vec<SomeType> = todo!();
    /// let mut cmd = Cmd::new();
    ///
    /// // Calculate and reserve the space for the args
    /// cmd.reserve_space_for_args(to_send.iter().map(Message::encoded_len));
    ///
    /// // Write the args to the buffer
    /// for arg in to_send {
    ///     // Encode the type directly into the Cmd buffer
    ///     // Supplying the required capacity again is not needed for Cmd,
    ///     // but can be useful for other implementers like Vec<Vec<u8>>.
    ///     arg.encode(cmd.bufmut_for_next_arg(arg.encoded_len()));
    /// }
    ///
    /// ```
    ///
    /// # Implementation note
    /// The default implementation provided by this trait is a no-op. It's therefore strongly
    /// recommended to implement this function. Depending on the internal buffer it might only
    /// be possible to use the numbers of arguments (`additional.len()`) or the total expected
    /// capacity (`additional.iter().sum()`). Implementors should assume that the caller will
    /// be wrong and might over or under specify the amount of arguments and space required.
    fn reserve_space_for_args(&mut self, additional: impl IntoIterator<Item = usize>) {
        // _additional would show up in the documentation, so we assign it
        // to make it used.
        let _do_nothing = additional;
    }

    #[cfg(feature = "bytes")]
    /// Appends an empty argument to the command, and returns a
    /// [`bytes::BufMut`] instance that can write to it.
    ///
    /// `capacity` should be equal or greater to the amount of bytes
    /// expected, as some implementations might not be able to resize
    /// the returned buffer.
    ///
    /// Writing multiple arguments into this buffer is unsupported. The resulting
    /// data will be interpreted as one argument by Redis.
    ///
    /// Writing no data is supported and is similar to having an empty bytestring
    /// as an argument.
    fn bufmut_for_next_arg(&mut self, capacity: usize) -> impl bytes::BufMut + '_ {
        // This default implementation is not the most efficient, but does
        // allow for implementers to skip this function. This means that
        // upstream libraries that implement this trait don't suddenly
        // stop working because someone enabled one of the async features.

        /// Has a temporary buffer that is written to [`writer_for_next_arg`]
        /// on drop.
        struct Wrapper<'a> {
            /// The buffer, implements [`bytes::BufMut`] allowing passthrough
            buf: Vec<u8>,
            /// The writer to the command, used on drop
            writer: Box<dyn io::Write + 'a>,
        }
        unsafe impl bytes::BufMut for Wrapper<'_> {
            fn remaining_mut(&self) -> usize {
                self.buf.remaining_mut()
            }

            unsafe fn advance_mut(&mut self, cnt: usize) {
                unsafe {
                    self.buf.advance_mut(cnt);
                }
            }

            fn chunk_mut(&mut self) -> &mut bytes::buf::UninitSlice {
                self.buf.chunk_mut()
            }

            // Vec specializes these methods, so we do too
            fn put<T: bytes::buf::Buf>(&mut self, src: T)
            where
                Self: Sized,
            {
                self.buf.put(src);
            }

            fn put_slice(&mut self, src: &[u8]) {
                self.buf.put_slice(src);
            }

            fn put_bytes(&mut self, val: u8, cnt: usize) {
                self.buf.put_bytes(val, cnt);
            }
        }
        impl Drop for Wrapper<'_> {
            fn drop(&mut self) {
                self.writer.write_all(&self.buf).unwrap();
            }
        }

        Wrapper {
            buf: Vec::with_capacity(capacity),
            writer: Box::new(self.writer_for_next_arg()),
        }
    }
}

impl RedisWrite for Vec<Vec<u8>> {
    fn write_arg(&mut self, arg: &[u8]) {
        self.push(arg.to_owned());
    }

    fn write_arg_fmt(&mut self, arg: impl fmt::Display) {
        self.push(arg.to_string().into_bytes());
    }

    fn writer_for_next_arg(&mut self) -> impl io::Write + '_ {
        self.push(Vec::new());
        self.last_mut().unwrap()
    }

    fn reserve_space_for_args(&mut self, additional: impl IntoIterator<Item = usize>) {
        // It would be nice to do this, but there's no way to store where we currently are.
        // Checking for the first empty Vec is not possible, as it's valid to write empty args.
        // self.extend(additional.iter().copied().map(Vec::with_capacity));
        // So we just reserve space for the extra args and have to forgo the extra optimisation
        self.reserve(additional.into_iter().count());
    }

    #[cfg(feature = "bytes")]
    fn bufmut_for_next_arg(&mut self, capacity: usize) -> impl bytes::BufMut + '_ {
        self.push(Vec::with_capacity(capacity));
        self.last_mut().unwrap()
    }
}

/// This trait marks that a value is serialized only into a single Redis value.
///
/// This should be implemented only for types that are serialized into exactly one value,
/// otherwise the compiler can't ensure the correctness of some commands.
pub trait ToSingleRedisArg: ToRedisArgs {}

/// Used to convert a value into one or multiple redis argument
/// strings.  Most values will produce exactly one item but in
/// some cases it might make sense to produce more than one.
pub trait ToRedisArgs: Sized {
    /// This converts the value into a vector of bytes.  Each item
    /// is a single argument.  Most items generate a vector of a
    /// single item.
    ///
    /// The exception to this rule currently are vectors of items.
    fn to_redis_args(&self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        self.write_redis_args(&mut out);
        out
    }

    /// This writes the value into a vector of bytes.  Each item
    /// is a single argument.  Most items generate a single item.
    ///
    /// The exception to this rule currently are vectors of items.
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite;

    /// Returns an information about the contained value with regards
    /// to it's numeric behavior in a redis context.  This is used in
    /// some high level concepts to switch between different implementations
    /// of redis functions (for instance `INCR` vs `INCRBYFLOAT`).
    fn describe_numeric_behavior(&self) -> NumericBehavior {
        NumericBehavior::NonNumeric
    }

    /// Returns the number of arguments this value will generate.
    ///
    /// This is used in some high level functions to intelligently switch
    /// between `GET` and `MGET` variants. Also, for some commands like HEXPIREDAT
    /// which require a specific number of arguments, this method can be used to
    /// know the number of arguments.
    fn num_of_args(&self) -> usize {
        1
    }

    /// This only exists internally as a workaround for the lack of
    /// specialization.
    #[doc(hidden)]
    fn write_args_from_slice<W>(items: &[Self], out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        Self::make_arg_iter_ref(items.iter(), out);
    }

    /// This only exists internally as a workaround for the lack of
    /// specialization.
    #[doc(hidden)]
    fn make_arg_iter_ref<'a, I, W>(items: I, out: &mut W)
    where
        W: ?Sized + RedisWrite,
        I: Iterator<Item = &'a Self>,
        Self: 'a,
    {
        for item in items {
            item.write_redis_args(out);
        }
    }

    #[doc(hidden)]
    fn is_single_vec_arg(items: &[Self]) -> bool {
        items.len() == 1 && items[0].num_of_args() <= 1
    }
}

macro_rules! itoa_based_to_redis_impl {
    ($t:ty, $numeric:expr) => {
        impl ToRedisArgs for $t {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                let mut buf = ::itoa::Buffer::new();
                let s = buf.format(*self);
                out.write_arg(s.as_bytes())
            }

            fn describe_numeric_behavior(&self) -> NumericBehavior {
                $numeric
            }
        }

        impl ToSingleRedisArg for $t {}
    };
}

macro_rules! non_zero_itoa_based_to_redis_impl {
    ($t:ty, $numeric:expr) => {
        impl ToRedisArgs for $t {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                let mut buf = ::itoa::Buffer::new();
                let s = buf.format(self.get());
                out.write_arg(s.as_bytes())
            }

            fn describe_numeric_behavior(&self) -> NumericBehavior {
                $numeric
            }
        }

        impl ToSingleRedisArg for $t {}
    };
}

macro_rules! ryu_based_to_redis_impl {
    ($t:ty, $numeric:expr) => {
        impl ToRedisArgs for $t {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                let mut buf = ::ryu::Buffer::new();
                let s = buf.format(*self);
                out.write_arg(s.as_bytes())
            }

            fn describe_numeric_behavior(&self) -> NumericBehavior {
                $numeric
            }
        }

        impl ToSingleRedisArg for $t {}
    };
}

impl ToRedisArgs for u8 {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        let mut buf = ::itoa::Buffer::new();
        let s = buf.format(*self);
        out.write_arg(s.as_bytes());
    }

    fn write_args_from_slice<W>(items: &[Self], out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(items);
    }

    fn is_single_vec_arg(_items: &[Self]) -> bool {
        true
    }
}

impl ToSingleRedisArg for u8 {}

itoa_based_to_redis_impl!(i8, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(i16, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(u16, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(i32, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(u32, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(i64, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(u64, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(i128, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(u128, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(isize, NumericBehavior::NumberIsInteger);
itoa_based_to_redis_impl!(usize, NumericBehavior::NumberIsInteger);

non_zero_itoa_based_to_redis_impl!(core::num::NonZeroU8, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroI8, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroU16, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroI16, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroU32, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroI32, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroU64, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroI64, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroU128, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroI128, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroUsize, NumericBehavior::NumberIsInteger);
non_zero_itoa_based_to_redis_impl!(core::num::NonZeroIsize, NumericBehavior::NumberIsInteger);

ryu_based_to_redis_impl!(f32, NumericBehavior::NumberIsFloat);
ryu_based_to_redis_impl!(f64, NumericBehavior::NumberIsFloat);

#[cfg(any(
    feature = "rust_decimal",
    feature = "bigdecimal",
    feature = "num-bigint"
))]
macro_rules! bignum_to_redis_impl {
    ($t:ty) => {
        impl ToRedisArgs for $t {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                out.write_arg(&self.to_string().into_bytes())
            }
        }

        impl ToSingleRedisArg for $t {}
    };
}

#[cfg(feature = "rust_decimal")]
bignum_to_redis_impl!(rust_decimal::Decimal);
#[cfg(feature = "bigdecimal")]
bignum_to_redis_impl!(bigdecimal::BigDecimal);
#[cfg(feature = "num-bigint")]
bignum_to_redis_impl!(num_bigint::BigInt);
#[cfg(feature = "num-bigint")]
bignum_to_redis_impl!(num_bigint::BigUint);

impl ToRedisArgs for bool {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(if *self { b"1" } else { b"0" });
    }
}

impl ToSingleRedisArg for bool {}

impl ToRedisArgs for String {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(self.as_bytes());
    }
}
impl ToSingleRedisArg for String {}

impl ToRedisArgs for &str {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(self.as_bytes());
    }
}

impl ToSingleRedisArg for &str {}

impl<'a, T> ToRedisArgs for Cow<'a, T>
where
    T: ToOwned + ?Sized,
    &'a T: ToRedisArgs,
    T::Owned: ToRedisArgs,
{
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Cow::Borrowed(inner) => inner.write_redis_args(out),
            Cow::Owned(inner) => inner.write_redis_args(out),
        }
    }
}

impl<'a, T> ToSingleRedisArg for Cow<'a, T>
where
    T: ToOwned + ?Sized,
    &'a T: ToSingleRedisArg,
    T::Owned: ToSingleRedisArg,
{
}

impl<T: ToRedisArgs> ToRedisArgs for Option<T> {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if let Some(ref x) = *self {
            x.write_redis_args(out);
        }
    }

    fn describe_numeric_behavior(&self) -> NumericBehavior {
        match *self {
            Some(ref x) => x.describe_numeric_behavior(),
            None => NumericBehavior::NonNumeric,
        }
    }

    fn num_of_args(&self) -> usize {
        match *self {
            Some(ref x) => x.num_of_args(),
            None => 0,
        }
    }
}

macro_rules! impl_write_redis_args_for_collection {
    ($type:ty) => {
        impl<'a, T> ToRedisArgs for $type
        where
            T: ToRedisArgs,
        {
            #[inline]
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                ToRedisArgs::write_args_from_slice(self, out)
            }

            fn num_of_args(&self) -> usize {
                if ToRedisArgs::is_single_vec_arg(&self[..]) {
                    return 1;
                }
                if self.len() == 1 {
                    self[0].num_of_args()
                } else {
                    self.len()
                }
            }

            fn describe_numeric_behavior(&self) -> NumericBehavior {
                NumericBehavior::NonNumeric
            }
        }
    };
}

macro_rules! deref_to_write_redis_args_impl {
    ($type:ty) => {
        impl<'a, T> ToRedisArgs for $type
        where
            T: ToRedisArgs,
        {
            #[inline]
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                (**self).write_redis_args(out)
            }

            fn num_of_args(&self) -> usize {
                (**self).num_of_args()
            }

            fn describe_numeric_behavior(&self) -> NumericBehavior {
                (**self).describe_numeric_behavior()
            }
        }

        impl<'a, T> ToSingleRedisArg for $type where T: ToSingleRedisArg {}
    };
}

deref_to_write_redis_args_impl! {&'a T}
deref_to_write_redis_args_impl! {&'a mut T}
deref_to_write_redis_args_impl! {Box<T>}
deref_to_write_redis_args_impl! {std::sync::Arc<T>}
deref_to_write_redis_args_impl! {std::rc::Rc<T>}
impl_write_redis_args_for_collection! {&'a [T]}
impl_write_redis_args_for_collection! {&'a mut [T]}
impl_write_redis_args_for_collection! {Box<[T]>}
impl_write_redis_args_for_collection! {std::sync::Arc<[T]>}
impl_write_redis_args_for_collection! {std::rc::Rc<[T]>}
impl_write_redis_args_for_collection! {Vec<T>}
impl ToSingleRedisArg for &[u8] {}
impl ToSingleRedisArg for &mut [u8] {}
impl ToSingleRedisArg for Vec<u8> {}
impl ToSingleRedisArg for Box<[u8]> {}
impl ToSingleRedisArg for std::rc::Rc<[u8]> {}
impl ToSingleRedisArg for std::sync::Arc<[u8]> {}

/// @note: Redis cannot store empty sets so the application has to
/// check whether the set is empty and if so, not attempt to use that
/// result
macro_rules! impl_to_redis_args_for_set {
    (for <$($TypeParam:ident),+> $SetType:ty, where ($($WhereClause:tt)+) ) => {
        impl< $($TypeParam),+ > ToRedisArgs for $SetType
        where
            $($WhereClause)+
        {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                ToRedisArgs::make_arg_iter_ref(self.iter(), out)
            }

            fn num_of_args(&self) -> usize {
                self.len()
            }
        }
    };
}

impl_to_redis_args_for_set!(
    for <T, S> std::collections::HashSet<T, S>,
    where (T: ToRedisArgs)
);

impl_to_redis_args_for_set!(
    for <T> std::collections::BTreeSet<T>,
    where (T: ToRedisArgs)
);

#[cfg(feature = "hashbrown")]
impl_to_redis_args_for_set!(
    for <T, S> hashbrown::HashSet<T, S>,
    where (T: ToRedisArgs)
);

#[cfg(feature = "ahash")]
impl_to_redis_args_for_set!(
    for <T, S> ahash::AHashSet<T, S>,
    where (T: ToRedisArgs)
);

/// @note: Redis cannot store empty maps so the application has to
/// check whether the set is empty and if so, not attempt to use that
/// result
macro_rules! impl_to_redis_args_for_map {
    (
        $(#[$meta:meta])*
        for <$($TypeParam:ident),+> $MapType:ty,
        where ($($WhereClause:tt)+)
    ) => {
        $(#[$meta])*
        impl< $($TypeParam),+ > ToRedisArgs for $MapType
        where
            $($WhereClause)+
        {
            fn write_redis_args<W>(&self, out: &mut W)
            where
                W: ?Sized + RedisWrite,
            {
                for (key, value) in self {
                    // Ensure key and value produce a single argument each
                    assert!(key.num_of_args() <= 1 && value.num_of_args() <= 1);
                    key.write_redis_args(out);
                    value.write_redis_args(out);
                }
            }

            fn num_of_args(&self) -> usize {
                self.len()
            }
        }
    };
}

impl_to_redis_args_for_map!(
    for <K, V, S> std::collections::HashMap<K, V, S>,
    where (K: ToRedisArgs, V: ToRedisArgs)
);

impl_to_redis_args_for_map!(
    /// this flattens BTreeMap into something that goes well with HMSET
    for <K, V> std::collections::BTreeMap<K, V>,
    where (K: ToRedisArgs, V: ToRedisArgs)
);

#[cfg(feature = "hashbrown")]
impl_to_redis_args_for_map!(
    for <K, V, S> hashbrown::HashMap<K, V, S>,
    where (K: ToRedisArgs, V: ToRedisArgs)
);

#[cfg(feature = "ahash")]
impl_to_redis_args_for_map!(
    for <K, V, S> ahash::AHashMap<K, V, S>,
    where (K: ToRedisArgs, V: ToRedisArgs)
);

macro_rules! to_redis_args_for_tuple {
    () => ();
    ($(#[$meta:meta],)*$($name:ident,)+) => (
        $(#[$meta])*
        impl<$($name: ToRedisArgs),*> ToRedisArgs for ($($name,)*) {
            // we have local variables named T1 as dummies and those
            // variables are unused.
            #[allow(non_snake_case, unused_variables)]
            fn write_redis_args<W>(&self, out: &mut W) where W: ?Sized + RedisWrite {
                let ($(ref $name,)*) = *self;
                $($name.write_redis_args(out);)*
            }

            #[allow(non_snake_case, unused_variables)]
            fn num_of_args(&self) -> usize {
                let mut n: usize = 0;
                $(let $name = (); n += 1;)*
                n
            }
        }
    )
}

to_redis_args_for_tuple! { #[cfg_attr(docsrs, doc(fake_variadic))], #[doc = "This trait is implemented for tuples up to 12 items long."], T, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, }
to_redis_args_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, }

impl<T: ToRedisArgs, const N: usize> ToRedisArgs for &[T; N] {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        ToRedisArgs::write_args_from_slice(self.as_slice(), out);
    }

    fn num_of_args(&self) -> usize {
        if ToRedisArgs::is_single_vec_arg(&self[..]) {
            return 1;
        }
        if self.len() == 1 {
            self[0].num_of_args()
        } else {
            self.len()
        }
    }
}
impl<const N: usize> ToSingleRedisArg for &[u8; N] {}

fn vec_to_array<T, const N: usize>(
    items: Vec<T>,
    original_value: &Value,
) -> Result<[T; N], ParsingError> {
    match items.try_into() {
        Ok(array) => Ok(array),
        Err(items) => {
            let msg = format!(
                "Response has wrong dimension, expected {N}, got {}",
                items.len()
            );
            crate::errors::invalid_type_error!(original_value, msg)
        }
    }
}

impl<T: FromRedisValue, const N: usize> FromRedisValue for [T; N] {
    fn from_redis_value_ref(v: &Value) -> Result<[T; N], ParsingError> {
        match *v {
            Value::BulkString(ref bytes) => match FromRedisValue::from_byte_slice(bytes) {
                Some(items) => vec_to_array(items, v),
                None => {
                    let msg = format!(
                        "Conversion to Array[{}; {N}] failed",
                        std::any::type_name::<T>()
                    );
                    crate::errors::invalid_type_error!(v, msg)
                }
            },
            Value::Array(ref items) => {
                let items = FromRedisValue::from_redis_value_refs(items)?;
                vec_to_array(items, v)
            }
            Value::Nil => vec_to_array(vec![], v),
            _ => crate::errors::invalid_type_error!(v, "Response type not array compatible"),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        Self::from_redis_value_ref(&v)
    }
}

/// This trait is used to convert a redis value into a more appropriate
/// type.
///
/// While a redis `Value` can represent any response that comes
/// back from the redis server, usually you want to map this into something
/// that works better in rust.  For instance you might want to convert the
/// return value into a `String` or an integer.
///
/// This trait is well supported throughout the library and you can
/// implement it for your own types if you want.
///
/// In addition to what you can see from the docs, this is also implemented
/// for tuples up to size 12 and for `Vec<u8>`.
pub trait FromRedisValue: Sized {
    /// Given a redis `Value` this attempts to convert it into the given
    /// destination type.  If that fails because it's not compatible an
    /// appropriate error is generated.
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        // By default, fall back to `from_redis_value_ref`.
        // This function only needs to be implemented if it can benefit
        // from taking `v` by value.
        Self::from_redis_value(v.clone())
    }

    /// Given a redis `Value` this attempts to convert it into the given
    /// destination type.  If that fails because it's not compatible an
    /// appropriate error is generated.
    fn from_redis_value(v: Value) -> Result<Self, ParsingError>;

    /// Similar to `from_redis_value_ref` but constructs a vector of objects
    /// from another vector of values.  This primarily exists internally
    /// to customize the behavior for vectors of tuples.
    fn from_redis_value_refs(items: &[Value]) -> Result<Vec<Self>, ParsingError> {
        items
            .iter()
            .map(FromRedisValue::from_redis_value_ref)
            .collect()
    }

    /// The same as `from_redis_value_refs`, but takes a `Vec<Value>` instead
    /// of a `&[Value]`.
    fn from_redis_values(items: Vec<Value>) -> Result<Vec<Self>, ParsingError> {
        items
            .into_iter()
            .map(FromRedisValue::from_redis_value)
            .collect()
    }

    /// The same as `from_redis_values`, but returns a result for each
    /// conversion to make handling them case-by-case possible.
    fn from_each_redis_values(items: Vec<Value>) -> Vec<Result<Self, ParsingError>> {
        items
            .into_iter()
            .map(FromRedisValue::from_redis_value)
            .collect()
    }

    /// Convert bytes to a single element vector.
    fn from_byte_slice(_vec: &[u8]) -> Option<Vec<Self>> {
        Self::from_redis_value(Value::BulkString(_vec.into()))
            .map(|rv| vec![rv])
            .ok()
    }

    /// Convert bytes to a single element vector.
    fn from_byte_vec(_vec: Vec<u8>) -> Result<Vec<Self>, ParsingError> {
        Self::from_redis_value(Value::BulkString(_vec)).map(|rv| vec![rv])
    }
}

fn get_inner_value(v: &Value) -> &Value {
    if let Value::Attribute {
        data,
        attributes: _,
    } = v
    {
        data.as_ref()
    } else {
        v
    }
}

fn get_owned_inner_value(v: Value) -> Value {
    if let Value::Attribute {
        data,
        attributes: _,
    } = v
    {
        *data
    } else {
        v
    }
}

macro_rules! from_redis_value_for_num_internal {
    ($t:ty, $v:expr) => {{
        let v = if let Value::Attribute {
            data,
            attributes: _,
        } = $v
        {
            data
        } else {
            $v
        };
        match *v {
            Value::Int(val) => Ok(val as $t),
            Value::SimpleString(ref s) => match s.parse::<$t>() {
                Ok(rv) => Ok(rv),
                Err(_) => crate::errors::invalid_type_error!(v, "Could not convert from string."),
            },
            Value::BulkString(ref bytes) => match from_utf8(bytes)?.parse::<$t>() {
                Ok(rv) => Ok(rv),
                Err(_) => crate::errors::invalid_type_error!(v, "Could not convert from string."),
            },
            Value::Double(val) => Ok(val as $t),
            _ => crate::errors::invalid_type_error!(v, "Response type not convertible to numeric."),
        }
    }};
}

macro_rules! from_redis_value_for_num {
    ($t:ty) => {
        impl FromRedisValue for $t {
            fn from_redis_value_ref(v: &Value) -> Result<$t, ParsingError> {
                from_redis_value_for_num_internal!($t, v)
            }

            fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
                Self::from_redis_value_ref(&v)
            }
        }
    };
}

impl FromRedisValue for u8 {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        from_redis_value_for_num_internal!(Self, v)
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        Self::from_redis_value_ref(&v)
    }

    // this hack allows us to specialize Vec<u8> to work with binary data.
    fn from_byte_slice(vec: &[u8]) -> Option<Vec<Self>> {
        Some(vec.to_vec())
    }
    fn from_byte_vec(vec: Vec<u8>) -> Result<Vec<Self>, ParsingError> {
        Ok(vec)
    }
}

from_redis_value_for_num!(i8);
from_redis_value_for_num!(i16);
from_redis_value_for_num!(u16);
from_redis_value_for_num!(i32);
from_redis_value_for_num!(u32);
from_redis_value_for_num!(i64);
from_redis_value_for_num!(u64);
from_redis_value_for_num!(i128);
from_redis_value_for_num!(u128);
from_redis_value_for_num!(f32);
from_redis_value_for_num!(f64);
from_redis_value_for_num!(isize);
from_redis_value_for_num!(usize);

#[cfg(any(
    feature = "rust_decimal",
    feature = "bigdecimal",
    feature = "num-bigint"
))]
macro_rules! from_redis_value_for_bignum_internal {
    ($t:ty, $v:expr) => {{
        let v = $v;
        match *v {
            Value::Int(val) => <$t>::try_from(val).map_err(|_| {
                crate::errors::invalid_type_error_inner!(v, "Could not convert from integer.")
            }),
            Value::SimpleString(ref s) => match s.parse::<$t>() {
                Ok(rv) => Ok(rv),
                Err(_) => crate::errors::invalid_type_error!(v, "Could not convert from string."),
            },
            Value::BulkString(ref bytes) => match from_utf8(bytes)?.parse::<$t>() {
                Ok(rv) => Ok(rv),
                Err(_) => crate::errors::invalid_type_error!(v, "Could not convert from string."),
            },
            _ => crate::errors::invalid_type_error!(v, "Response type not convertible to numeric."),
        }
    }};
}

#[cfg(any(
    feature = "rust_decimal",
    feature = "bigdecimal",
    feature = "num-bigint"
))]
macro_rules! from_redis_value_for_bignum {
    ($t:ty) => {
        impl FromRedisValue for $t {
            fn from_redis_value_ref(v: &Value) -> Result<$t, ParsingError> {
                from_redis_value_for_bignum_internal!($t, v)
            }

            fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
                Self::from_redis_value_ref(&v)
            }
        }
    };
}

#[cfg(feature = "rust_decimal")]
from_redis_value_for_bignum!(rust_decimal::Decimal);
#[cfg(feature = "bigdecimal")]
from_redis_value_for_bignum!(bigdecimal::BigDecimal);
#[cfg(feature = "num-bigint")]
from_redis_value_for_bignum!(num_bigint::BigInt);
#[cfg(feature = "num-bigint")]
from_redis_value_for_bignum!(num_bigint::BigUint);

impl FromRedisValue for bool {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        match *v {
            Value::Nil => Ok(false),
            Value::Int(val) => Ok(val != 0),
            Value::SimpleString(ref s) => {
                if &s[..] == "1" {
                    Ok(true)
                } else if &s[..] == "0" {
                    Ok(false)
                } else {
                    crate::errors::invalid_type_error!(v, "Response status not valid boolean");
                }
            }
            Value::BulkString(ref bytes) => {
                if bytes == b"1" {
                    Ok(true)
                } else if bytes == b"0" {
                    Ok(false)
                } else {
                    crate::errors::invalid_type_error!(v, "Response type not bool compatible.");
                }
            }
            Value::Boolean(b) => Ok(b),
            Value::Okay => Ok(true),
            _ => crate::errors::invalid_type_error!(v, "Response type not bool compatible."),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        Self::from_redis_value_ref(&v)
    }
}

impl FromRedisValue for CString {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        match *v {
            Value::BulkString(ref bytes) => Ok(Self::new(bytes.as_slice())?),
            Value::Okay => Ok(Self::new("OK")?),
            Value::SimpleString(ref val) => Ok(Self::new(val.as_bytes())?),
            _ => crate::errors::invalid_type_error!(v, "Response type not CString compatible."),
        }
    }
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = get_owned_inner_value(v);
        match v {
            Value::BulkString(bytes) => Ok(Self::new(bytes)?),
            Value::Okay => Ok(Self::new("OK")?),
            Value::SimpleString(val) => Ok(Self::new(val)?),
            _ => crate::errors::invalid_type_error!(v, "Response type not CString compatible."),
        }
    }
}

impl FromRedisValue for String {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        match *v {
            Value::BulkString(ref bytes) => Ok(from_utf8(bytes)?.to_string()),
            Value::Okay => Ok("OK".to_string()),
            Value::SimpleString(ref val) => Ok(val.to_string()),
            Value::VerbatimString {
                format: _,
                ref text,
            } => Ok(text.to_string()),
            Value::Double(ref val) => Ok(val.to_string()),
            Value::Int(val) => Ok(val.to_string()),
            _ => crate::errors::invalid_type_error!(v, "Response type not string compatible."),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = get_owned_inner_value(v);
        match v {
            Value::BulkString(bytes) => Ok(Self::from_utf8(bytes)?),
            Value::Okay => Ok("OK".to_string()),
            Value::SimpleString(val) => Ok(val),
            Value::VerbatimString { format: _, text } => Ok(text),
            Value::Double(val) => Ok(val.to_string()),
            Value::Int(val) => Ok(val.to_string()),
            _ => crate::errors::invalid_type_error!(v, "Response type not string compatible."),
        }
    }
}

macro_rules! pointer_from_redis_value_impl {
    (
        $(#[$attr:meta])*
        $id:ident, $ty:ty, $func:expr
    ) => {
        $(#[$attr])*
        impl<$id:  FromRedisValue> FromRedisValue for $ty {
            fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError>
            {
                FromRedisValue::from_redis_value_ref(v).map($func)
            }

            fn from_redis_value(v: Value) -> Result<Self, ParsingError>{
                FromRedisValue::from_redis_value(v).map($func)
            }
        }
    }
}

pointer_from_redis_value_impl!(T, Box<T>, Box::new);
pointer_from_redis_value_impl!(T, std::sync::Arc<T>, std::sync::Arc::new);
pointer_from_redis_value_impl!(T, std::rc::Rc<T>, std::rc::Rc::new);

/// Implement `FromRedisValue` for `$Type` (which should use the generic parameter `$T`).
///
/// The implementation parses the value into a vec, and then passes the value through `$convert`.
/// If `$convert` is omitted, it defaults to `Into::into`.
macro_rules! from_vec_from_redis_value {
    (<$T:ident> $Type:ty) => {
        from_vec_from_redis_value!(<$T> $Type; Into::into);
    };

    (<$T:ident> $Type:ty; $convert:expr) => {
        impl<$T: FromRedisValue> FromRedisValue for $Type {
            fn from_redis_value_ref(v: &Value) -> Result<$Type, ParsingError> {
                match v {
                    // All binary data except u8 will try to parse into a single element vector.
                    // u8 has its own implementation of from_byte_slice.
                    Value::BulkString(bytes) => match FromRedisValue::from_byte_slice(bytes) {
                        Some(x) => Ok($convert(x)),
                        None => crate::errors::invalid_type_error!(
                            v,
                            format!("Conversion to {} failed.", std::any::type_name::<$Type>())
                        ),
                    },
                    Value::Array(items) => FromRedisValue::from_redis_value_refs(items).map($convert),
                    Value::Set(items) => FromRedisValue::from_redis_value_refs(items).map($convert),
                    Value::Map(items) => {
                        let mut n: Vec<T> = vec![];
                        for item in items {
                            match FromRedisValue::from_redis_value_ref(&Value::Map(vec![item.clone()])) {
                                Ok(v) => {
                                    n.push(v);
                                }
                                Err(e) => {
                                    return Err(e);
                                }
                            }
                        }
                        Ok($convert(n))
                    }
                    Value::Nil => Ok($convert(Vec::new())),
                    _ => crate::errors::invalid_type_error!(v, "Response type not vector compatible."),
                }
            }
            fn from_redis_value(v: Value) -> Result<$Type, ParsingError> {
                match v {
                    // Binary data is parsed into a single-element vector, except
                    // for the element type `u8`, which directly consumes the entire
                    // array of bytes.
                    Value::BulkString(bytes) => FromRedisValue::from_byte_vec(bytes).map($convert),
                    Value::Array(items) => FromRedisValue::from_redis_values(items).map($convert),
                    Value::Set(items) => FromRedisValue::from_redis_values(items).map($convert),
                    Value::Map(items) => {
                        let mut n: Vec<T> = vec![];
                        for item in items {
                            match FromRedisValue::from_redis_value(Value::Map(vec![item])) {
                                Ok(v) => {
                                    n.push(v);
                                }
                                Err(e) => {
                                    return Err(e);
                                }
                            }
                        }
                        Ok($convert(n))
                    }
                    Value::Nil => Ok($convert(Vec::new())),
                    _ => crate::errors::invalid_type_error!(v, "Response type not vector compatible."),
                }
            }
        }
    };
}

from_vec_from_redis_value!(<T> Vec<T>);
from_vec_from_redis_value!(<T> std::sync::Arc<[T]>);
from_vec_from_redis_value!(<T> Box<[T]>; Vec::into_boxed_slice);

macro_rules! impl_from_redis_value_for_map {
    (for <$($TypeParam:ident),+> $MapType:ty, where ($($WhereClause:tt)+)) => {
        impl< $($TypeParam),+ > FromRedisValue for $MapType
        where
            $($WhereClause)+
        {
            fn from_redis_value_ref(v: &Value) -> Result<$MapType, ParsingError> {
                let v = get_inner_value(v);
                match *v {
                    Value::Nil => Ok(Default::default()),
                    _ => v
                        .as_map_iter()
                        .ok_or_else(|| crate::errors::invalid_type_error_inner!(v, "Response type not map compatible"))?
                        .map(|(k, v)| {
                            Ok((from_redis_value_ref(k)?, from_redis_value_ref(v)?))
                        })
                        .collect(),
                }
            }

            fn from_redis_value(v: Value) -> Result<$MapType, ParsingError> {
                let v = get_owned_inner_value(v);
                match v {
                    Value::Nil => Ok(Default::default()),
                    _ => v
                        .into_map_iter()
                        .map_err(|v| crate::errors::invalid_type_error_inner!(v, "Response type not map compatible"))?
                        .map(|(k, v)| {
                            Ok((from_redis_value(k)?, from_redis_value(v)?))
                        })
                        .collect(),
                }
            }
        }
    };
}

impl_from_redis_value_for_map!(
    for <K, V, S> std::collections::HashMap<K, V, S>,
    where (K: FromRedisValue + Eq + Hash, V: FromRedisValue, S: BuildHasher + Default)
);

impl_from_redis_value_for_map!(
    for <K, V> std::collections::BTreeMap<K, V>,
    where (K: FromRedisValue + Eq + Ord, V: FromRedisValue)
);

#[cfg(feature = "hashbrown")]
impl_from_redis_value_for_map!(
    for <K, V, S> hashbrown::HashMap<K, V, S>,
    where (K: FromRedisValue + Eq + Hash, V: FromRedisValue, S: BuildHasher + Default)
);

// `AHashMap::default` is not generic over `S` param so we can't be generic over it as well.
#[cfg(feature = "ahash")]
impl_from_redis_value_for_map!(
    for <K, V> ahash::AHashMap<K, V>,
    where (K: FromRedisValue + Eq + Hash, V: FromRedisValue)
);

macro_rules! impl_from_redis_value_for_set {
    (for <$($TypeParam:ident),+> $SetType:ty, where ($($WhereClause:tt)+)) => {
        impl< $($TypeParam),+ > FromRedisValue for $SetType
        where
            $($WhereClause)+
        {
            fn from_redis_value_ref(v: &Value) -> Result<$SetType, ParsingError> {
                let v = get_inner_value(v);
                let items = v
                    .as_sequence()
                    .ok_or_else(|| crate::errors::invalid_type_error_inner!(v, "Response type not map compatible"))?;
                items.iter().map(|item| from_redis_value_ref(item)).collect()
            }

            fn from_redis_value(v: Value) -> Result<$SetType, ParsingError> {
                let v = get_owned_inner_value(v);
                let items = v
                    .into_sequence()
                    .map_err(|v| crate::errors::invalid_type_error_inner!(v, "Response type not map compatible"))?;
                items
                    .into_iter()
                    .map(|item| from_redis_value(item))
                    .collect()
            }
        }
    };
}

impl_from_redis_value_for_set!(
    for <T, S> std::collections::HashSet<T, S>,
    where (T: FromRedisValue + Eq + Hash, S: BuildHasher + Default)
);

impl_from_redis_value_for_set!(
    for <T> std::collections::BTreeSet<T>,
    where (T: FromRedisValue + Ord)
);

#[cfg(feature = "hashbrown")]
impl_from_redis_value_for_set!(
    for <T, S> hashbrown::HashSet<T, S>,
    where (T: FromRedisValue + Eq + Hash, S: BuildHasher + Default)
);

// `AHashSet::from_iter` is not generic over `S` param so we can't be generic over it as well.
#[cfg(feature = "ahash")]
impl_from_redis_value_for_set!(
    for <T> ahash::AHashSet<T>,
    where (T: FromRedisValue + Eq + Hash)
);

impl FromRedisValue for Value {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        Ok(v.clone())
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        Ok(v)
    }
}

impl FromRedisValue for () {
    fn from_redis_value_ref(v: &Value) -> Result<(), ParsingError> {
        match v {
            Value::ServerError(err) => Err(ParsingError::from(err.to_string())),
            _ => Ok(()),
        }
    }

    fn from_redis_value(v: Value) -> Result<(), ParsingError> {
        Self::from_redis_value_ref(&v)
    }
}

macro_rules! from_redis_value_for_tuple {
    () => ();
    ($(#[$meta:meta],)*$($name:ident,)+) => (
        $(#[$meta])*
        impl<$($name: FromRedisValue),*> FromRedisValue for ($($name,)*) {
            // we have local variables named T1 as dummies and those
            // variables are unused.
            #[allow(non_snake_case, unused_variables)]
            fn from_redis_value_ref(v: &Value) -> Result<($($name,)*), ParsingError> {
                let v = get_inner_value(v);
                // hacky way to count the tuple size
                let mut n = 0;
                $(let $name = (); n += 1;)*

                match *v {
                    Value::Array(ref items) => {
                        if items.len() != n {
                            crate::errors::invalid_type_error!(v, "Array response of wrong dimension")
                        }

                        // The { i += 1; i - 1} is rust's postfix increment :)
                        let mut i = 0;
                        Ok(($({let $name = (); from_redis_value_ref(
                             &items[{ i += 1; i - 1 }])?},)*))
                    }

                    Value::Set(ref items) => {
                        if items.len() != n {
                            crate::errors::invalid_type_error!(v, "Set response of wrong dimension")
                        }

                        // The { i += 1; i - 1} is rust's postfix increment :)
                        let mut i = 0;
                        Ok(($({let $name = (); from_redis_value_ref(
                             &items[{ i += 1; i - 1 }])?},)*))
                    }

                    Value::Map(ref items) => {
                        if n != items.len() * 2 {
                            crate::errors::invalid_type_error!(v, "Map response of wrong dimension")
                        }

                        let mut flatten_items = items.iter().map(|(a,b)|[a,b]).flatten();

                        Ok(($({let $name = (); from_redis_value_ref(
                             &flatten_items.next().unwrap())?},)*))
                    }

                    _ => crate::errors::invalid_type_error!(v, "Not a Array response")
                }
            }

            // we have local variables named T1 as dummies and those
            // variables are unused.
            #[allow(non_snake_case, unused_variables)]
            fn from_redis_value(v: Value) -> Result<($($name,)*), ParsingError> {
                let v = get_owned_inner_value(v);
                // hacky way to count the tuple size
                let mut n = 0;
                $(let $name = (); n += 1;)*
                match v {
                    Value::Array(mut items) => {
                        if items.len() != n {
                            crate::errors::invalid_type_error!(Value::Array(items), "Array response of wrong dimension")
                        }

                        // The { i += 1; i - 1} is rust's postfix increment :)
                        let mut i = 0;
                        Ok(($({let $name = (); from_redis_value(
                            ::std::mem::replace(&mut items[{ i += 1; i - 1 }], Value::Nil)
                        )?},)*))
                    }

                    Value::Set(mut items) => {
                        if items.len() != n {
                            crate::errors::invalid_type_error!(Value::Array(items), "Set response of wrong dimension")
                        }

                        // The { i += 1; i - 1} is rust's postfix increment :)
                        let mut i = 0;
                        Ok(($({let $name = (); from_redis_value(
                            ::std::mem::replace(&mut items[{ i += 1; i - 1 }], Value::Nil)
                        )?},)*))
                    }

                    Value::Map(items) => {
                        if n != items.len() * 2 {
                            crate::errors::invalid_type_error!(Value::Map(items), "Map response of wrong dimension")
                        }

                        let mut flatten_items = items.into_iter().map(|(a,b)|[a,b]).flatten();

                        Ok(($({let $name = (); from_redis_value(
                            ::std::mem::replace(&mut flatten_items.next().unwrap(), Value::Nil)
                        )?},)*))
                    }

                    _ => crate::errors::invalid_type_error!(v, "Not a Array response")
                }
            }

            #[allow(non_snake_case, unused_variables)]
            fn from_redis_value_refs(items: &[Value]) -> Result<Vec<($($name,)*)>, ParsingError> {
                // hacky way to count the tuple size
                let mut n = 0;
                $(let $name = (); n += 1;)*
                if items.len() == 0 {
                    return Ok(vec![]);
                }

                if items.iter().all(|item| item.is_collection_of_len(n)) {
                    return items.iter().map(|item| from_redis_value_ref(item)).collect();
                }

                let mut rv = Vec::with_capacity(items.len() / n);
                if let [$($name),*] = items {
                    rv.push(($(from_redis_value_ref($name)?,)*));
                    return Ok(rv);
                }
                for chunk in items.chunks(n) {
                    match chunk {
                        [$($name),*] => rv.push(($(from_redis_value_ref($name)?,)*)),
                         _ => return Err(format!("Vector of length {} doesn't have arity of {n}", items.len()).into()),
                    }
                }
                Ok(rv)
            }

            #[allow(non_snake_case, unused_variables)]
            fn from_each_redis_values(mut items: Vec<Value>) -> Vec<Result<($($name,)*), ParsingError>> {
                #[allow(unused_parens)]
                let extract = |val: ($(Result<$name, ParsingError>,)*)| -> Result<($($name,)*), ParsingError> {
                    let ($($name,)*) = val;
                    Ok(($($name?,)*))
                };

                // hacky way to count the tuple size
                let mut n = 0;
                $(let $name = (); n += 1;)*

                // let mut rv = vec![];
                if items.len() == 0 {
                    return vec![];
                }
                if items.iter().all(|item| item.is_collection_of_len(n)) {
                    return items.into_iter().map(|item| from_redis_value(item).map_err(|err|err.into())).collect();
                }

                let mut rv = Vec::with_capacity(items.len() / n);

                for chunk in items.chunks_mut(n) {
                    match chunk {
                        // Take each element out of the chunk with `std::mem::replace`, leaving a `Value::Nil`
                        // in its place. This allows each `Value` to be parsed without being copied.
                        // Since `items` is consumed by this function and not used later, this replacement
                        // is not observable to the rest of the code.
                        [$($name),*] => rv.push(extract(($(from_redis_value(std::mem::replace($name, Value::Nil)).into(),)*))),
                         _ => return vec![Err(format!("Vector of length {} doesn't have arity of {n}", items.len()).into())],
                    }
                }
                rv
            }

            #[allow(non_snake_case, unused_variables)]
            fn from_redis_values(mut items: Vec<Value>) -> Result<Vec<($($name,)*)>, ParsingError> {
                // hacky way to count the tuple size
                let mut n = 0;
                $(let $name = (); n += 1;)*

                // let mut rv = vec![];
                if items.len() == 0 {
                    return Ok(vec![])
                }
                if items.iter().all(|item| item.is_collection_of_len(n)) {
                    return items.into_iter().map(|item| from_redis_value(item)).collect();
                }

                let mut rv = Vec::with_capacity(items.len() / n);
                for chunk in items.chunks_mut(n) {
                    match chunk {
                        // Take each element out of the chunk with `std::mem::replace`, leaving a `Value::Nil`
                        // in its place. This allows each `Value` to be parsed without being copied.
                        // Since `items` is consume by this function and not used later, this replacement
                        // is not observable to the rest of the code.
                        [$($name),*] => rv.push(($(from_redis_value(std::mem::replace($name, Value::Nil))?,)*)),
                         _ => return Err(format!("Vector of length {} doesn't have arity of {n}", items.len()).into()),
                    }
                }
                Ok(rv)
            }
        }
    )
}

from_redis_value_for_tuple! { #[cfg_attr(docsrs, doc(fake_variadic))], #[doc = "This trait is implemented for tuples up to 12 items long."], T, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, }
from_redis_value_for_tuple! { #[doc(hidden)], T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, }

impl FromRedisValue for InfoDict {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        let s: String = from_redis_value_ref(v)?;
        Ok(Self::new(&s))
    }
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = get_owned_inner_value(v);
        let s: String = from_redis_value(v)?;
        Ok(Self::new(&s))
    }
}

impl<T: FromRedisValue> FromRedisValue for Option<T> {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        if *v == Value::Nil {
            return Ok(None);
        }
        Ok(Some(from_redis_value_ref(v)?))
    }
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = get_owned_inner_value(v);
        if v == Value::Nil {
            return Ok(None);
        }
        Ok(Some(from_redis_value(v)?))
    }
}

#[cfg(feature = "bytes")]
impl FromRedisValue for bytes::Bytes {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        let v = get_inner_value(v);
        match v {
            Value::BulkString(bytes_vec) => Ok(Self::copy_from_slice(bytes_vec.as_ref())),
            _ => crate::errors::invalid_type_error!(v, "Not a bulk string"),
        }
    }
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let v = get_owned_inner_value(v);
        match v {
            Value::BulkString(bytes_vec) => Ok(bytes_vec.into()),
            _ => crate::errors::invalid_type_error!(v, "Not a bulk string"),
        }
    }
}

#[cfg(feature = "uuid")]
impl FromRedisValue for uuid::Uuid {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        match *v {
            Value::BulkString(ref bytes) => Ok(Self::from_slice(bytes)?),
            _ => crate::errors::invalid_type_error!(v, "Response type not uuid compatible."),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        Self::from_redis_value_ref(&v)
    }
}

#[cfg(feature = "uuid")]
impl ToRedisArgs for uuid::Uuid {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(self.as_bytes());
    }
}

#[cfg(feature = "uuid")]
impl ToSingleRedisArg for uuid::Uuid {}

/// A shortcut function to invoke `FromRedisValue::from_redis_value_ref`
/// to make the API slightly nicer.
pub fn from_redis_value_ref<T: FromRedisValue>(v: &Value) -> Result<T, ParsingError> {
    FromRedisValue::from_redis_value_ref(v)
}

/// A shortcut function to invoke `FromRedisValue::from_redis_value`
/// to make the API slightly nicer.
pub fn from_redis_value<T: FromRedisValue>(v: Value) -> Result<T, ParsingError> {
    FromRedisValue::from_redis_value(v)
}

/// Calculates a digest/hash of the given value for use with Redis value comparison operations.
/// This function uses the XXH3 algorithm, which is the same algorithm used by Redis for its DIGEST command.
/// The resulting digest can be used with `ValueComparison::IFDEQ` and `ValueComparison::IFDNE`.
///
/// # Example
/// ```rust
/// use redis::{calculate_value_digest, ValueComparison, SetOptions};
///
/// let value = "my_value";
/// let digest = calculate_value_digest(value);
///
/// // Use the digest in a value comparison
/// let opts = SetOptions::default()
///     .value_comparison(ValueComparison::ifdeq(&digest));
/// ```
pub fn calculate_value_digest<T: ToRedisArgs>(value: T) -> String {
    use xxhash_rust::xxh3::xxh3_64;

    // Convert the value to Redis args format (bytes)
    let args = value.to_redis_args();

    // For consistency with Redis behavior, hash the concatenated bytes
    // of all arguments, similar to how Redis would serialize the value
    let mut combined_bytes = Vec::new();
    for arg in args {
        combined_bytes.extend_from_slice(&arg);
    }

    // Calculate XXH3 hash (64-bit) and format as hexadecimal string
    let hash = xxh3_64(&combined_bytes);
    format!("{hash:016x}")
}

/// Validates that the given string is a valid 16-byte hex digest.
pub fn is_valid_16_bytes_hex_digest(s: &str) -> bool {
    s.len() == 16 && s.chars().all(|c| c.is_ascii_hexdigit())
}

/// Enum representing the communication protocol with the server.
///
/// This enum represents the types of data that the server can send to the client,
/// and the capabilities that the client can use.
#[derive(Clone, Eq, PartialEq, Default, Debug, Copy)]
#[non_exhaustive]
pub enum ProtocolVersion {
    /// <https://github.com/redis/redis-specifications/blob/master/protocol/RESP2.md>
    #[default]
    RESP2,
    /// <https://github.com/redis/redis-specifications/blob/master/protocol/RESP3.md>
    RESP3,
}

impl ProtocolVersion {
    /// Returns true if the protocol can support RESP3 features.
    pub fn supports_resp3(&self) -> bool {
        !matches!(self, Self::RESP2)
    }
}

/// Helper enum that is used to define option for the hash expire commands
#[derive(Clone, Copy)]
#[non_exhaustive]
pub enum ExpireOption {
    /// NONE -- Set expiration regardless of the field's current expiration.
    NONE,
    /// NX -- Only set expiration only when the field has no expiration.
    NX,
    /// XX -- Only set expiration only when the field has an existing expiration.
    XX,
    /// GT -- Only set expiration only when the new expiration is greater than current one.
    GT,
    /// LT -- Only set expiration only when the new expiration is less than current one.
    LT,
}

impl ToRedisArgs for ExpireOption {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::NX => out.write_arg(b"NX"),
            Self::XX => out.write_arg(b"XX"),
            Self::GT => out.write_arg(b"GT"),
            Self::LT => out.write_arg(b"LT"),
            _ => {}
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
/// A push message from the server.
pub struct PushInfo {
    /// Push Kind
    pub kind: PushKind,
    /// Data from push message
    pub data: Vec<Value>,
}

impl PushInfo {
    pub(crate) fn disconnect() -> Self {
        Self {
            kind: crate::PushKind::Disconnection,
            data: vec![],
        }
    }
}

pub(crate) type SyncPushSender = std::sync::mpsc::Sender<PushInfo>;

/// Possible types of value held in Redis: [Redis Docs](https://redis.io/docs/latest/commands/type/)
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum ValueType {
    /// Key does not have a value
    None,
    /// Generally returned by anything that returns a single element. [Redis Docs](https://redis.io/docs/latest/develop/data-types/strings/)
    String,
    /// A list of String values. [Redis Docs](https://redis.io/docs/latest/develop/data-types/lists/)
    List,
    /// A set of unique String values. [Redis Docs](https://redis.io/docs/latest/develop/data-types/sets/)
    Set,
    /// A sorted set of String values. [Redis Docs](https://redis.io/docs/latest/develop/data-types/sorted-sets/)
    ZSet,
    /// A collection of field-value pairs. [Redis Docs](https://redis.io/docs/latest/develop/data-types/hashes/)
    Hash,
    /// A Redis Stream. [Redis Docs](https://redis.io/docs/latest/develop/data-types/stream)
    Stream,
    /// A vector set. [Redis Docs](https://redis.io/docs/latest/develop/data-types/vector-sets/)
    VectorSet,
    /// A RedisJSON value. [Redis Docs](https://redis.io/docs/latest/develop/data-types/json/)
    JSON,
    /// A Bloom filter from Redis' module. [Redis Docs](https://redis.io/docs/latest/develop/data-types/probabilistic/bloom-filter/)
    BloomFilterRedis,
    /// A Cuckoo filter. [Redis Docs](https://redis.io/docs/latest/develop/data-types/probabilistic/cuckoo-filter/)
    CuckooFilter,
    /// A Count-min. [Redis Docs](https://redis.io/docs/latest/develop/data-types/probabilistic/count-min-sketch/)
    CountMin,
    /// A t-Digest. [Redis Docs](https://redis.io/docs/latest/develop/data-types/probabilistic/t-digest/)
    TDigest,
    /// A Top-K. [Redis Docs](https://redis.io/docs/latest/develop/data-types/probabilistic/top-k/)
    TopK,
    /// A time series. [Redis Docs](https://redis.io/docs/latest/develop/data-types/timeseries/)
    TimeSeries,
    /// A Trie. [Redis Docs](https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/autocomplete/)
    Trie,
    /// A Bloom filter from Valkey's module. [ValKey Docs](https://valkey.io/topics/bloomfilters/)
    BloomFilterValKey,
    /// Any other value type not explicitly defined in [Redis Docs](https://redis.io/docs/latest/commands/type/)
    Unknown(String),
}

impl<T: AsRef<str>> From<T> for ValueType {
    fn from(s: T) -> Self {
        match s.as_ref() {
            "none" => Self::None,
            "string" => Self::String,
            "list" => Self::List,
            "set" => Self::Set,
            "zset" => Self::ZSet,
            "hash" => Self::Hash,
            "stream" => Self::Stream,
            "vectorset" => Self::VectorSet,
            // JSON module
            "ReJSON-RL" => Self::JSON,
            // Bloom module (Redis)
            "CMSk-TYPE" => Self::CountMin,
            "MBbloom--" => Self::BloomFilterRedis,
            "MBbloomCF" => Self::CuckooFilter,
            "TDIS-TYPE" => Self::TDigest,
            "TopK-TYPE" => Self::TopK,
            // Search module
            "trietype0" => Self::Trie,
            // Timeseries module
            "TSDB-TYPE" => Self::TimeSeries,
            // Bloom module (ValKey)
            "bloomfltr" => Self::BloomFilterValKey,
            // Fallback
            s => Self::Unknown(s.to_string()),
        }
    }
}

impl From<ValueType> for String {
    fn from(v: ValueType) -> Self {
        match v {
            ValueType::None => "none".to_string(),
            ValueType::String => "string".to_string(),
            ValueType::List => "list".to_string(),
            ValueType::Set => "set".to_string(),
            ValueType::ZSet => "zset".to_string(),
            ValueType::Hash => "hash".to_string(),
            ValueType::Stream => "stream".to_string(),
            ValueType::VectorSet => "vectorset".to_string(),
            // JSON module
            ValueType::JSON => "ReJSON-RL".to_string(),
            // Bloom module (Redis)
            ValueType::BloomFilterRedis => "MBbloom--".to_string(),
            ValueType::CuckooFilter => "MBbloomCF".to_string(),
            ValueType::TDigest => "TDIS-TYPE".to_string(),
            ValueType::TopK => "TopK-TYPE".to_string(),
            ValueType::CountMin => "CMSk-TYPE".to_string(),
            // Search module
            ValueType::Trie => "trietype0".to_string(),
            // Timeseries module
            ValueType::TimeSeries => "TSDB-TYPE".to_string(),
            // Bloom module (ValKey)
            ValueType::BloomFilterValKey => "bloomfltr".to_string(),
            // Fallback
            ValueType::Unknown(s) => s,
        }
    }
}

impl FromRedisValue for ValueType {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        match v {
            Value::SimpleString(s) => Ok(s.into()),
            _ => crate::errors::invalid_type_error!(v, "Value type should be a simple string"),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        match v {
            Value::SimpleString(s) => Ok(s.into()),
            _ => crate::errors::invalid_type_error!(v, "Value type should be a simple string"),
        }
    }
}

/// Returned by typed commands which either return a positive integer or some negative integer indicating some kind of no-op.
#[derive(Debug, PartialEq, Clone)]
#[non_exhaustive]
pub enum IntegerReplyOrNoOp {
    /// A positive integer reply indicating success of some kind.
    IntegerReply(usize),
    /// The field/key you are trying to operate on does not exist.
    NotExists,
    /// The field/key you are trying to operate on exists but is not of the correct type or does not have some property you are trying to affect.
    ExistsButNotRelevant,
}

impl IntegerReplyOrNoOp {
    /// Returns the integer value of the reply.
    pub fn raw(&self) -> isize {
        match self {
            Self::IntegerReply(s) => *s as isize,
            Self::NotExists => -2,
            Self::ExistsButNotRelevant => -1,
        }
    }
}

impl FromRedisValue for IntegerReplyOrNoOp {
    fn from_redis_value_ref(v: &Value) -> Result<Self, ParsingError> {
        match v {
            Value::Int(s) => match s {
                -2 => Ok(Self::NotExists),
                -1 => Ok(Self::ExistsButNotRelevant),
                _ => Ok(Self::IntegerReply(*s as usize)),
            },
            _ => crate::errors::invalid_type_error!(v, "Value should be an integer"),
        }
    }

    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        match v {
            Value::Int(s) => match s {
                -2 => Ok(Self::NotExists),
                -1 => Ok(Self::ExistsButNotRelevant),
                _ => Ok(Self::IntegerReply(s as usize)),
            },
            _ => crate::errors::invalid_type_error!(v, "Value should be an integer"),
        }
    }
}

impl PartialEq<isize> for IntegerReplyOrNoOp {
    fn eq(&self, other: &isize) -> bool {
        match self {
            Self::IntegerReply(s) => *s as isize == *other,
            Self::NotExists => *other == -2,
            Self::ExistsButNotRelevant => *other == -1,
        }
    }
}

impl PartialEq<usize> for IntegerReplyOrNoOp {
    fn eq(&self, other: &usize) -> bool {
        match self {
            Self::IntegerReply(s) => *s == *other,
            _ => false,
        }
    }
}

impl PartialEq<i32> for IntegerReplyOrNoOp {
    fn eq(&self, other: &i32) -> bool {
        match self {
            Self::IntegerReply(s) => *s as i32 == *other,
            Self::NotExists => *other == -2,
            Self::ExistsButNotRelevant => *other == -1,
        }
    }
}

impl PartialEq<u32> for IntegerReplyOrNoOp {
    fn eq(&self, other: &u32) -> bool {
        match self {
            Self::IntegerReply(s) => *s as u32 == *other,
            _ => false,
        }
    }
}

/// The two-element reply of the [INCREX](https://redis.io/commands/increx) command.
///
/// Each field holds the raw [`Value`] returned by the server.
/// For `BYINT` operations this is an integer, while for `BYFLOAT` it is a bulk string (RESP2) or double (RESP3).
/// Decode a field into a concrete type with [`value_as`](Self::value_as) / [`actual_increment_as`](Self::actual_increment_as)
/// - e.g. `i64` for `BYINT` or `f64` (or a wider type such as `bigdecimal::BigDecimal`) for `BYFLOAT`.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub struct IncrexResult {
    /// The key's value after the increment.
    pub value: Value,
    /// The increment that was actually applied.
    ///
    /// This is `0` when the default policy (when `SATURATE` is not set) rejected an out-of-bounds operation.
    /// In that case `value` holds the unchanged current value and the TTL is left untouched.
    /// When `SATURATE` is set, it clamps the result to a bound.
    /// This reflects the clamped delta, which may differ from the requested increment.
    pub actual_increment: Value,
}

impl IncrexResult {
    /// Decode [`value`](Self::value) into the desired type.
    /// - e.g. `i64` for `BYINT` operations and `f64` or a wider type for `BYFLOAT` operations.
    pub fn value_as<T: FromRedisValue>(&self) -> Result<T, ParsingError> {
        T::from_redis_value_ref(&self.value)
    }

    /// Decode [`actual_increment`](Self::actual_increment) into the desired type.
    /// - e.g. `i64` for `BYINT` operations and `f64` or a wider type for `BYFLOAT` operations.
    pub fn actual_increment_as<T: FromRedisValue>(&self) -> Result<T, ParsingError> {
        T::from_redis_value_ref(&self.actual_increment)
    }

    /// Decode both fields as `i64`, the natural type for a `BYINT` result, returning `(value, actual_increment)`.
    pub fn as_i64(&self) -> Result<(i64, i64), ParsingError> {
        Ok((self.value_as()?, self.actual_increment_as()?))
    }

    /// Decode both fields as `f64`, the natural type for a `BYFLOAT` result, returning `(value, actual_increment)`.
    pub fn as_f64(&self) -> Result<(f64, f64), ParsingError> {
        Ok((self.value_as()?, self.actual_increment_as()?))
    }
}

impl FromRedisValue for IncrexResult {
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let [value, actual_increment] = <[Value; 2]>::from_redis_value(v)?;
        Ok(Self {
            value,
            actual_increment,
        })
    }
}
