use std::{collections::HashMap, sync::Arc, time::Duration};

use derive_where::derive_where;
use serde::{de::Error as SerdeError, Deserialize, Deserializer, Serialize};
use typed_builder::TypedBuilder;

use crate::{
    bson::doc,
    error::{ErrorKind, Result},
    options::ServerAddress,
    sdam::public::ServerInfo,
    serde_util,
};

/// Describes which servers are suitable for a given operation.
#[derive(Clone, derive_more::Display)]
#[derive_where(Debug)]
#[non_exhaustive]
pub enum SelectionCriteria {
    /// A read preference that describes the suitable servers based on the server type, max
    /// staleness, and server tags.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/core/read-preference/) for more details.
    #[display("ReadPreference {_0}")]
    ReadPreference(ReadPreference),

    /// A predicate used to filter servers that are considered suitable. A `server` will be
    /// considered suitable by a `predicate` if `predicate(server)` returns true.
    #[display("Custom predicate")]
    Predicate(#[derive_where(skip)] Predicate),
}

impl PartialEq for SelectionCriteria {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::ReadPreference(r1), Self::ReadPreference(r2)) => r1 == r2,
            _ => false,
        }
    }
}

impl From<ReadPreference> for SelectionCriteria {
    fn from(read_pref: ReadPreference) -> Self {
        Self::ReadPreference(read_pref)
    }
}

impl SelectionCriteria {
    pub(crate) fn as_read_pref(&self) -> Option<&ReadPreference> {
        match self {
            Self::ReadPreference(ref read_pref) => Some(read_pref),
            Self::Predicate(..) => None,
        }
    }

    pub(crate) fn from_address(address: ServerAddress) -> Self {
        SelectionCriteria::Predicate(Arc::new(move |server| server.address() == &address))
    }

    #[cfg(test)]
    pub(crate) fn serialize_for_client_options<S>(
        selection_criteria: &Option<SelectionCriteria>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match selection_criteria {
            Some(SelectionCriteria::ReadPreference(read_preference)) => {
                read_preference.serialize(serializer)
            }
            _ => serializer.serialize_none(),
        }
    }
}

impl<'de> Deserialize<'de> for SelectionCriteria {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(SelectionCriteria::ReadPreference(
            ReadPreference::deserialize(deserializer)?,
        ))
    }
}

/// A predicate used to filter servers that are considered suitable.
pub type Predicate = Arc<dyn Send + Sync + Fn(&ServerInfo) -> bool>;

/// Specifies how the driver should route a read operation to members of a replica set.
///
/// If applicable, `tag_sets` can be used to target specific nodes in a replica set, and
/// `max_staleness` specifies the maximum lag behind the primary that a secondary can be to remain
/// eligible for the operation. The max staleness value maps to the `maxStalenessSeconds` MongoDB
/// option and will be sent to the server as an integer number of seconds.
///
/// See the [MongoDB docs](https://www.mongodb.com/docs/manual/core/read-preference) for more details.
#[allow(missing_docs)]
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum ReadPreference {
    /// Only route this operation to the primary.
    Primary,

    /// Only route this operation to a secondary.
    Secondary {
        options: Option<ReadPreferenceOptions>,
    },

    /// Route this operation to the primary if it's available, but fall back to the secondaries if
    /// not.
    PrimaryPreferred {
        options: Option<ReadPreferenceOptions>,
    },

    /// Route this operation to a secondary if one is available, but fall back to the primary if
    /// not.
    SecondaryPreferred {
        options: Option<ReadPreferenceOptions>,
    },

    /// Route this operation to the node with the least network latency regardless of whether it's
    /// the primary or a secondary.
    Nearest {
        options: Option<ReadPreferenceOptions>,
    },
}

impl std::fmt::Display for ReadPreference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut mode = self.mode().to_string();
        mode[0..1].make_ascii_uppercase();
        write!(f, "{{ Mode: {mode}")?;

        if let Some(options) = self.options() {
            if let Some(ref tag_sets) = options.tag_sets {
                write!(f, ", Tag Sets: {tag_sets:?}")?;
            }
            if let Some(ref max_staleness) = options.max_staleness {
                write!(f, ", Max Staleness: {max_staleness:?}")?;
            }
            #[allow(deprecated)]
            if let Some(ref hedge) = options.hedge {
                write!(f, ", Hedge: {}", hedge.enabled)?;
            }
        }

        write!(f, " }}")
    }
}

impl<'de> Deserialize<'de> for ReadPreference {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Serialize, Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct ReadPreferenceHelper {
            mode: String,
            #[serde(flatten)]
            options: ReadPreferenceOptions,
        }
        let helper = ReadPreferenceHelper::deserialize(deserializer)?;
        match helper.mode.to_ascii_lowercase().as_str() {
            "primary" => {
                if !helper.options.is_default() {
                    return Err(D::Error::custom(format!(
                        "cannot specify options for primary read preference, got {:?}",
                        helper.options
                    )));
                }
                Ok(ReadPreference::Primary)
            }
            "secondary" => Ok(ReadPreference::Secondary {
                options: Some(helper.options),
            }),
            "primarypreferred" => Ok(ReadPreference::PrimaryPreferred {
                options: Some(helper.options),
            }),
            "secondarypreferred" => Ok(ReadPreference::SecondaryPreferred {
                options: Some(helper.options),
            }),
            "nearest" => Ok(ReadPreference::Nearest {
                options: Some(helper.options),
            }),
            other => Err(D::Error::custom(format!(
                "Unknown read preference mode: {other}"
            ))),
        }
    }
}

impl Serialize for ReadPreference {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        #[serde_with::skip_serializing_none]
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct ReadPreferenceHelper<'a> {
            mode: &'static str,
            #[serde(flatten)]
            options: Option<&'a ReadPreferenceOptions>,
        }

        let helper = ReadPreferenceHelper {
            mode: self.mode(),
            options: self.options(),
        };
        helper.serialize(serializer)
    }
}

/// Specifies read preference options for non-primary read preferences.
#[allow(deprecated)]
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ReadPreferenceOptions {
    /// Specifies which replica set members should be considered for operations. Each tag set will
    /// be checked in order until one or more servers is found with each tag in the set.
    #[serde(alias = "tag_sets")]
    pub tag_sets: Option<Vec<TagSet>>,

    /// Specifies the maximum amount of lag behind the primary that a secondary can be to be
    /// considered for the given operation. Any secondaries lagging behind more than
    /// `max_staleness` will not be considered for the operation.
    ///
    /// `max_staleness` must be at least 90 seconds. If a `max_staleness` less than 90 seconds is
    /// specified for an operation, the operation will return an error.
    #[serde(
        rename = "maxStalenessSeconds",
        default,
        with = "serde_util::duration_option_as_int_seconds"
    )]
    pub max_staleness: Option<Duration>,

    /// Specifies hedging behavior for reads. These options only apply to sharded clusters. Note
    /// that hedged reads are automatically enabled for read preference mode "nearest" on
    /// server versions less than 8.0.
    ///
    /// See the [MongoDB docs](https://www.mongodb.com/docs/manual/core/read-preference-hedge-option/) for more details.
    #[deprecated(
        note = "hedged reads are deprecated as of MongoDB 8.0 and will be removed in a future \
                server version"
    )]
    pub hedge: Option<HedgedReadOptions>,
}

impl ReadPreferenceOptions {
    pub(crate) fn is_default(&self) -> bool {
        #[allow(deprecated)]
        let hedge = self.hedge.is_some();
        !hedge
            && self.max_staleness.is_none()
            && self
                .tag_sets
                .as_ref()
                .map(|ts| ts.is_empty() || ts[..] == [HashMap::default()])
                .unwrap_or(true)
    }
}

/// Specifies hedging behavior for reads.
///
/// See the [MongoDB docs](https://www.mongodb.com/docs/manual/core/read-preference-hedge-option/) for more details.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct HedgedReadOptions {
    /// Whether or not to allow reads from a sharded cluster to be "hedged" across two replica
    /// set members per shard, with the results from the first response received back from either
    /// being returned.
    pub enabled: bool,
}

impl ReadPreference {
    /// Creates a `ReadPreference::Primary`. Reads will only be routed to the primary.
    pub fn primary() -> Self {
        Self::Primary
    }

    /// Creates a `ReadPreference::Secondary` with the given options. Reads will only be routed to a
    /// secondary.
    pub fn secondary(options: impl Into<Option<ReadPreferenceOptions>>) -> Self {
        Self::Secondary {
            options: options.into(),
        }
    }

    /// Creates a `ReadPreference::PrimaryPreferred` with the given options. Reads will be routed to
    /// the primary if it's available, and fall back to the secondaries if not.
    pub fn primary_preferred(options: impl Into<Option<ReadPreferenceOptions>>) -> Self {
        Self::PrimaryPreferred {
            options: options.into(),
        }
    }

    /// Creates a `ReadPreference::SecondaryPreferred` with the given options. Reads will be routed
    /// to a secondary if one is available, and fall back to the primary if not.
    pub fn secondary_preferred(options: impl Into<Option<ReadPreferenceOptions>>) -> Self {
        Self::SecondaryPreferred {
            options: options.into(),
        }
    }

    /// Creates a `ReadPreference::Nearest` with the given options. Reads will be routed to the node
    /// with the least network latency regardless of whether it's the primary or a secondary.
    pub fn nearest(options: impl Into<Option<ReadPreferenceOptions>>) -> Self {
        Self::Nearest {
            options: options.into(),
        }
    }

    pub(crate) fn mode(&self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Secondary { .. } => "secondary",
            Self::PrimaryPreferred { .. } => "primaryPreferred",
            Self::SecondaryPreferred { .. } => "secondaryPreferred",
            Self::Nearest { .. } => "nearest",
        }
    }

    pub(crate) fn options(&self) -> Option<&ReadPreferenceOptions> {
        match self {
            Self::Primary => None,
            Self::Secondary { options }
            | Self::PrimaryPreferred { options }
            | Self::SecondaryPreferred { options }
            | Self::Nearest { options } => options.as_ref(),
        }
    }

    pub(crate) fn max_staleness(&self) -> Option<Duration> {
        self.options().and_then(|options| options.max_staleness)
    }

    pub(crate) fn tag_sets(&self) -> Option<&Vec<TagSet>> {
        self.options().and_then(|options| options.tag_sets.as_ref())
    }

    pub(crate) fn with_tags(mut self, tag_sets: Vec<TagSet>) -> Result<Self> {
        let options = match self {
            Self::Primary => {
                return Err(ErrorKind::InvalidArgument {
                    message: "read preference tags can only be specified when a non-primary mode \
                              is specified"
                        .to_string(),
                }
                .into());
            }
            Self::Secondary { ref mut options } => options,
            Self::PrimaryPreferred { ref mut options } => options,
            Self::SecondaryPreferred { ref mut options } => options,
            Self::Nearest { ref mut options } => options,
        };

        options.get_or_insert_with(Default::default).tag_sets = Some(tag_sets);

        Ok(self)
    }

    pub(crate) fn with_max_staleness(mut self, max_staleness: Duration) -> Result<Self> {
        let options = match self {
            ReadPreference::Primary => {
                return Err(ErrorKind::InvalidArgument {
                    message: "max staleness can only be specified when a non-primary mode is \
                              specified"
                        .to_string(),
                }
                .into());
            }
            ReadPreference::Secondary { ref mut options } => options,
            ReadPreference::PrimaryPreferred { ref mut options } => options,
            ReadPreference::SecondaryPreferred { ref mut options } => options,
            ReadPreference::Nearest { ref mut options } => options,
        };

        options.get_or_insert_with(Default::default).max_staleness = Some(max_staleness);

        Ok(self)
    }
}

/// A read preference tag set. See the documentation [here](https://www.mongodb.com/docs/manual/tutorial/configure-replica-set-tag-sets/) for more details.
pub type TagSet = HashMap<String, String>;

#[cfg(test)]
mod test {
    use std::time::Duration;

    use super::{HedgedReadOptions, ReadPreference, ReadPreferenceOptions};
    use crate::bson::doc;

    #[test]
    fn hedged_read_included_in_document() {
        #[allow(deprecated)]
        let options = Some(
            ReadPreferenceOptions::builder()
                .hedge(HedgedReadOptions { enabled: true })
                .build(),
        );

        let read_pref = ReadPreference::Secondary { options };
        let doc = crate::bson_compat::serialize_to_document(&read_pref).unwrap();

        assert_eq!(
            doc,
            doc! { "mode": "secondary", "hedge": { "enabled": true } }
        );
    }

    #[test]
    fn constructors() {
        assert_eq!(ReadPreference::primary(), ReadPreference::Primary);

        assert_eq!(
            ReadPreference::secondary(None),
            ReadPreference::Secondary { options: None }
        );
        assert_eq!(
            ReadPreference::primary_preferred(None),
            ReadPreference::PrimaryPreferred { options: None }
        );
        assert_eq!(
            ReadPreference::secondary_preferred(None),
            ReadPreference::SecondaryPreferred { options: None }
        );
        assert_eq!(
            ReadPreference::nearest(None),
            ReadPreference::Nearest { options: None }
        );

        let options = ReadPreferenceOptions::builder()
            .max_staleness(Duration::from_secs(120))
            .build();
        assert_eq!(
            ReadPreference::nearest(options.clone()),
            ReadPreference::Nearest {
                options: Some(options)
            }
        );
    }
}
