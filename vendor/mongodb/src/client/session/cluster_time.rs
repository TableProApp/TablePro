use derive_where::derive_where;
use serde::{Deserialize, Serialize};

use crate::bson::{Document, Timestamp};

/// Struct modeling a cluster time reported by the server.
///
/// See [the MongoDB documentation](https://www.mongodb.com/docs/manual/core/read-isolation-consistency-recency/)
/// for more information.
#[derive(Debug, Deserialize, Clone, Serialize)]
#[derive_where(PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClusterTime {
    pub(crate) cluster_time: Timestamp,

    #[derive_where(skip)]
    pub(crate) signature: Document,
}

impl std::cmp::Ord for ClusterTime {
    fn cmp(&self, other: &ClusterTime) -> std::cmp::Ordering {
        self.cluster_time.cmp(&other.cluster_time)
    }
}

impl std::cmp::PartialOrd for ClusterTime {
    fn partial_cmp(&self, other: &ClusterTime) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
