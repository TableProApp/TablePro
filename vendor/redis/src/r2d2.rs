#[cfg(feature = "sentinel")]
use crate::sentinel::LockedSentinelClient;
use crate::{ConnectionLike, RedisError};

macro_rules! impl_manage_connection {
    ($client:ty, $connection:ty) => {
        impl r2d2::ManageConnection for $client {
            type Connection = $connection;
            type Error = RedisError;

            fn connect(&self) -> Result<Self::Connection, Self::Error> {
                self.get_connection()
            }

            fn is_valid(&self, conn: &mut Self::Connection) -> Result<(), Self::Error> {
                let pong: String = crate::Cmd::ping().query(conn)?;
                match pong.as_str() {
                    "PONG" => Ok(()),
                    _ => Err((crate::ErrorKind::UnexpectedReturnType, "ping request", pong).into()),
                }
            }

            fn has_broken(&self, conn: &mut Self::Connection) -> bool {
                !conn.is_open()
            }
        }
    };
}

impl_manage_connection!(crate::Client, crate::Connection);

#[cfg(feature = "cluster")]
impl_manage_connection!(
    crate::cluster::ClusterClient,
    crate::cluster::ClusterConnection
);

#[cfg(feature = "sentinel")]
impl_manage_connection!(LockedSentinelClient, crate::Connection);
