use tablepro_core::{DriverError, ServerInfo};
use tiberius::Client;
use tokio_util::compat::Compat;

use crate::errors::map_error;
use crate::transport_io::{ReadTally, TransportIo};

/// The stream tiberius drives: a transport stream behind the futures-io
/// traits tiberius is written against.
pub(crate) type MssqlStream = Compat<TransportIo>;

pub(crate) type MssqlClient = Client<MssqlStream>;

/// One logged-in connection, and the count of what its server has sent.
pub(crate) struct MssqlLink {
    pub(crate) client: MssqlClient,
    tally: ReadTally,
}

impl MssqlLink {
    pub(crate) fn new(client: MssqlClient, tally: ReadTally) -> Self {
        Self { client, tally }
    }

    pub(crate) fn tally(&self) -> ReadTally {
        self.tally.clone()
    }

    /// Run a batch of the driver's own whose results nobody reads. Every
    /// token is consumed, so the next request starts on a clean wire.
    pub(crate) async fn batch(&mut self, sql: &str) -> Result<(), DriverError> {
        let stream = self.client.simple_query(sql).await.map_err(map_error)?;
        stream.into_results().await.map_err(map_error)?;
        Ok(())
    }

    /// The open transactions on this connection.
    pub(crate) async fn transaction_count(&mut self) -> Result<i64, DriverError> {
        let stream = self
            .client
            .simple_query("SELECT CAST(@@TRANCOUNT AS bigint)")
            .await
            .map_err(map_error)?;
        let row = stream.into_row().await.map_err(map_error)?;
        let count = match &row {
            Some(row) => row.try_get::<i64, _>(0).map_err(map_error)?,
            None => None,
        };
        count.ok_or_else(|| DriverError::Protocol("@@TRANCOUNT returned no value".to_owned()))
    }
}

/// What the server says it is, read once at connect.
pub(crate) async fn server_info(link: &mut MssqlLink) -> Result<ServerInfo, DriverError> {
    let stream = link
        .client
        .simple_query("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))")
        .await
        .map_err(map_error)?;
    let row = stream.into_row().await.map_err(map_error)?;
    let version = match &row {
        Some(row) => row.try_get::<&str, _>(0).map_err(map_error)?.map(str::to_owned),
        None => None,
    }
    .ok_or_else(|| DriverError::Protocol("the server did not report ProductVersion".to_owned()))?;
    let (major, minor, build) = split_version(&version)
        .ok_or_else(|| DriverError::Protocol(format!("the server reported version {version}")))?;
    Ok(ServerInfo::new("SQL Server", version, major, minor, build))
}

/// `ProductVersion` reads `16.0.4135.4`: major, minor, build, revision.
fn split_version(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.trim().split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next().map_or(Some(0), |minor| minor.parse().ok())?;
    let build = parts.next().map_or(Some(0), |build| build.parse().ok())?;
    Some((major, minor, build))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_versions_split_into_major_minor_and_build() {
        assert_eq!(split_version("16.0.4135.4"), Some((16, 0, 4135)));
        assert_eq!(split_version("15.0.2000.5"), Some((15, 0, 2000)));
        assert_eq!(split_version("12"), Some((12, 0, 0)));
        assert_eq!(split_version("Microsoft"), None);
        assert_eq!(split_version(""), None);
    }
}
