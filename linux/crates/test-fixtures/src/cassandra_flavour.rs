use crate::{CassandraVersion, FixtureError, FixtureImage, ScyllaVersion, ServerVersion};

/// The CQL server a `CassandraFixture` runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CassandraFlavour {
    Cassandra,
    Scylla,
}

impl CassandraFlavour {
    pub const ALL: [Self; 2] = [Self::Cassandra, Self::Scylla];

    /// The image of the release the flavour's variable picks, and the
    /// major and minor version that release reports.
    pub fn selected(self) -> Result<(FixtureImage, (u32, u32)), FixtureError> {
        Ok(match self {
            Self::Cassandra => {
                let version = CassandraVersion::selected()?;
                (version.image(), version.reported())
            }
            Self::Scylla => {
                let version = ScyllaVersion::selected()?;
                (version.image(), version.reported())
            }
        })
    }

    pub(crate) fn service(self) -> &'static str {
        match self {
            Self::Cassandra => "cassandra",
            Self::Scylla => "scylla",
        }
    }

    pub(crate) fn configuration_file(self) -> &'static str {
        match self {
            Self::Cassandra => "/etc/cassandra/cassandra.yaml",
            Self::Scylla => "/etc/scylla/scylla.yaml",
        }
    }
}
