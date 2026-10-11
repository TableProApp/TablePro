//! Contains the types for read concerns and write concerns.

#[cfg(test)]
mod test;

use std::time::Duration;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_with::skip_serializing_none;
use typed_builder::TypedBuilder;

use crate::{
    bson::{doc, Timestamp},
    error::{ErrorKind, Result},
    serde_util,
};

/// Specifies the consistency and isolation properties of read operations from replica sets and
/// replica set shards.
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/reference/read-concern/) for more
/// information about read concerns.
#[skip_serializing_none]
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ReadConcern {
    /// The level of the read concern.
    pub level: ReadConcernLevel,
}

/// An internal-only read concern type that allows the omission of a "level" as well as
/// specification of "atClusterTime" and "afterClusterTime".
#[skip_serializing_none]
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[serde(rename = "readConcern")]
pub(crate) struct ReadConcernInternal {
    /// The level of the read concern.
    pub(crate) level: Option<ReadConcernLevel>,

    /// The snapshot read timestamp.
    pub(crate) at_cluster_time: Option<Timestamp>,

    /// The time of most recent operation using this session.
    /// Used for providing causal consistency.
    pub(crate) after_cluster_time: Option<Timestamp>,
}

impl ReadConcern {
    /// Creates a read concern with level "majority".
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-majority/).
    pub fn majority() -> Self {
        ReadConcernLevel::Majority.into()
    }

    /// Creates a read concern with level "local".
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-local/).
    pub fn local() -> Self {
        ReadConcernLevel::Local.into()
    }

    /// Creates a read concern with level "linearizable".
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-linearizable/).
    pub fn linearizable() -> Self {
        ReadConcernLevel::Linearizable.into()
    }

    /// Creates a read concern with level "available".
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-available/).
    pub fn available() -> Self {
        ReadConcernLevel::Available.into()
    }

    /// Creates a read concern with level "snapshot".
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-snapshot/).
    pub fn snapshot() -> Self {
        ReadConcernLevel::Snapshot.into()
    }

    /// Creates a read concern with a custom read concern level. This is present to provide forwards
    /// compatibility with any future read concerns which may be added to new versions of
    /// MongoDB.
    pub fn custom(level: impl AsRef<str>) -> Self {
        ReadConcernLevel::from_str(level.as_ref()).into()
    }

    pub(crate) fn serialize<S>(
        read_concern: &Option<ReadConcern>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        #[derive(Serialize)]
        struct ReadConcernHelper<'a> {
            readconcernlevel: &'a str,
        }

        let state = read_concern.as_ref().map(|concern| ReadConcernHelper {
            readconcernlevel: concern.level.as_str(),
        });
        state.serialize(serializer)
    }
}

impl From<ReadConcern> for ReadConcernInternal {
    fn from(rc: ReadConcern) -> Self {
        ReadConcernInternal {
            level: Some(rc.level),
            at_cluster_time: None,
            after_cluster_time: None,
        }
    }
}

impl From<ReadConcernLevel> for ReadConcern {
    fn from(level: ReadConcernLevel) -> Self {
        Self { level }
    }
}

/// Specifies the level consistency and isolation properties of a given `ReadCocnern`.
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/reference/read-concern/) for more
/// information about read concerns.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum ReadConcernLevel {
    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-local/).
    Local,

    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-majority/).
    Majority,

    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-linearizable/).
    Linearizable,

    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-available/).
    Available,

    /// See the specific documentation for this read concern level [here](https://www.mongodb.com/docs/manual/reference/read-concern-snapshot/).
    Snapshot,

    /// Specify a custom read concern level. This is present to provide forwards compatibility with
    /// any future read concerns which may be added to new versions of MongoDB.
    Custom(String),
}

impl ReadConcernLevel {
    pub(crate) fn from_str(s: &str) -> Self {
        match s {
            "local" => ReadConcernLevel::Local,
            "majority" => ReadConcernLevel::Majority,
            "linearizable" => ReadConcernLevel::Linearizable,
            "available" => ReadConcernLevel::Available,
            "snapshot" => ReadConcernLevel::Snapshot,
            s => ReadConcernLevel::Custom(s.to_string()),
        }
    }

    /// Gets the string representation of the `ReadConcernLevel`.
    pub(crate) fn as_str(&self) -> &str {
        match self {
            ReadConcernLevel::Local => "local",
            ReadConcernLevel::Majority => "majority",
            ReadConcernLevel::Linearizable => "linearizable",
            ReadConcernLevel::Available => "available",
            ReadConcernLevel::Snapshot => "snapshot",
            ReadConcernLevel::Custom(ref s) => s,
        }
    }
}

impl<'de> Deserialize<'de> for ReadConcernLevel {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Ok(ReadConcernLevel::from_str(&s))
    }
}

impl Serialize for ReadConcernLevel {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.as_str().serialize(serializer)
    }
}

/// Specifies the level of acknowledgement requested from the server for write operations.
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/reference/write-concern/) for more
/// information about write concerns.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, PartialEq, TypedBuilder, Serialize, Deserialize)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct WriteConcern {
    /// Requests acknowledgement that the operation has propagated to a specific number or variety
    /// of servers.
    pub w: Option<Acknowledgment>,

    /// Specifies a time limit for the write concern. If an operation has not propagated to the
    /// requested level within the time limit, an error will return.
    ///
    /// Note that an error being returned due to a write concern error does not imply that the
    /// write would not have finished propagating if allowed more time to finish, and the
    /// server will not roll back the writes that occurred before the timeout was reached.
    #[serde(rename = "wtimeout", alias = "wtimeoutMS")]
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    #[serde(deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis")]
    #[serde(default)]
    pub w_timeout: Option<Duration>,

    /// Requests acknowledgement that the operation has propagated to the on-disk journal.
    #[serde(rename = "j", alias = "journal")]
    pub journal: Option<bool>,
}

/// The type of the `w` field in a [`WriteConcern`](struct.WriteConcern.html).
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum Acknowledgment {
    /// Requires acknowledgement that the write has reached the specified number of nodes.
    ///
    /// Note: specifying 0 here indicates that the write concern is unacknowledged, which is
    /// currently unsupported and will result in an error during operation execution.
    Nodes(u32),

    /// Requires acknowledgement that the write has reached the majority of nodes.
    Majority,

    /// Requires acknowledgement according to the given custom write concern. See [here](https://www.mongodb.com/docs/manual/tutorial/configure-replica-set-tag-sets/#tag-sets-and-custom-write-concern-behavior)
    /// for more information.
    Custom(String),
}

impl Serialize for Acknowledgment {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Acknowledgment::Majority => serializer.serialize_str("majority"),
            Acknowledgment::Nodes(n) => serde_util::serialize_u32_as_i32(n, serializer),
            Acknowledgment::Custom(name) => serializer.serialize_str(name),
        }
    }
}

impl<'de> Deserialize<'de> for Acknowledgment {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum IntOrString {
            Int(u32),
            String(String),
        }
        match IntOrString::deserialize(deserializer)? {
            IntOrString::String(s) => Ok(s.into()),
            IntOrString::Int(i) => Ok(i.into()),
        }
    }
}

impl From<u32> for Acknowledgment {
    fn from(i: u32) -> Self {
        Acknowledgment::Nodes(i)
    }
}

impl From<&str> for Acknowledgment {
    fn from(s: &str) -> Self {
        if s == "majority" {
            Acknowledgment::Majority
        } else {
            Acknowledgment::Custom(s.to_string())
        }
    }
}

impl From<String> for Acknowledgment {
    fn from(s: String) -> Self {
        if s == "majority" {
            Acknowledgment::Majority
        } else {
            Acknowledgment::Custom(s)
        }
    }
}

impl WriteConcern {
    /// A 'WriteConcern' requesting [`Acknowledgment::Nodes`].
    pub fn nodes(v: u32) -> Self {
        Acknowledgment::Nodes(v).into()
    }

    /// A `WriteConcern` requesting [`Acknowledgment::Majority`].
    pub fn majority() -> Self {
        Acknowledgment::Majority.into()
    }

    /// A `WriteConcern` with a custom acknowledgment.
    pub fn custom(s: impl AsRef<str>) -> Self {
        Acknowledgment::from(s.as_ref()).into()
    }

    pub(crate) fn is_acknowledged(&self) -> bool {
        self.w != Some(Acknowledgment::Nodes(0)) || self.journal == Some(true)
    }

    /// Whether the write concern was created with no values specified. If true, the write concern
    /// should be considered the server's default.
    pub(crate) fn is_empty(&self) -> bool {
        self.w.is_none() && self.w_timeout.is_none() && self.journal.is_none()
    }

    /// Validates that the write concern. A write concern is invalid if both the `w` field is 0
    /// and the `j` field is `true`.
    pub(crate) fn validate(&self) -> Result<()> {
        if self.w == Some(Acknowledgment::Nodes(0)) && self.journal == Some(true) {
            return Err(ErrorKind::InvalidArgument {
                message: "write concern cannot have w=0 and j=true".to_string(),
            }
            .into());
        }

        if let Some(w_timeout) = self.w_timeout {
            if w_timeout < Duration::from_millis(0) {
                return Err(ErrorKind::InvalidArgument {
                    message: "write concern `w_timeout` field cannot be negative".to_string(),
                }
                .into());
            }
        }

        Ok(())
    }

    pub(crate) fn serialize<S>(
        write_concern: &Option<WriteConcern>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        #[derive(Serialize)]
        struct WriteConcernHelper<'a> {
            w: Option<&'a Acknowledgment>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            wtimeoutms: Option<Duration>,

            journal: Option<bool>,
        }

        let state = write_concern.as_ref().map(|concern| WriteConcernHelper {
            w: concern.w.as_ref(),
            wtimeoutms: concern.w_timeout,
            journal: concern.journal,
        });

        state.serialize(serializer)
    }
}

impl From<Acknowledgment> for WriteConcern {
    fn from(w: Acknowledgment) -> Self {
        WriteConcern {
            w: Some(w),
            w_timeout: None,
            journal: None,
        }
    }
}
