use redis::Value as Reply;
use tablepro_core::meta::SchemaInfo;
use tablepro_core::{CatalogBudget, DriverError, StopRequest};

use crate::errors::server_error;
use crate::link::{Link, command, stoppable};

// Redis's default `databases`: a server that will not say has at least these.
const ASSUMED: u32 = 16;

// `databases` and `cluster-databases` go up to the largest `int`.
const MOST: u32 = 2_147_483_647;

// Named by the index, as SELECT, a saved connection and a connection URL spell it (core ADR 0038).
pub(crate) async fn list(
    link: &Link,
    own: u32,
    cluster: bool,
    stop: &StopRequest,
) -> Result<Vec<SchemaInfo>, DriverError> {
    let count = count(link, own, cluster, stop).await?;
    let mut budget = CatalogBudget::default();
    let mut databases = Vec::new();
    for index in 0..count {
        let name = index.to_string();
        budget.charge(size_of::<SchemaInfo>().saturating_add(name.len()))?;
        databases.push(SchemaInfo {
            name,
            is_default: index == own,
            is_system: false,
        });
    }
    Ok(databases)
}

// Managed services deny CONFIG yet run more than 16 (Azure 64, Memorystore 100); Redis Cluster serves database 0 alone.
async fn count(link: &Link, own: u32, cluster: bool, stop: &StopRequest) -> Result<u32, DriverError> {
    let at_least = own.saturating_add(1);
    if cluster {
        let served = read(link, &["CONFIG", "GET", "cluster-databases"], stop).await?;
        return Ok(served.as_ref().and_then(reported_count).unwrap_or(1).max(at_least));
    }
    let reported = read(link, &["CONFIG", "GET", "databases"], stop).await?;
    if let Some(count) = reported.as_ref().and_then(reported_count) {
        return Ok(count.max(at_least));
    }
    let keyspace = read(link, &["INFO", "keyspace"], stop).await?;
    let holding = keyspace
        .as_ref()
        .and_then(text)
        .map(|info| keyspace_databases(&info))
        .unwrap_or_default();
    Ok(resolve(&holding, own))
}

// ERR is a command a managed service removed, NOPERM one an ACL denies; LOADING or BUSY the user has to see.
async fn read(link: &Link, arguments: &[&str], stop: &StopRequest) -> Result<Option<Reply>, DriverError> {
    match stoppable(stop, link.send(&command(arguments))).await? {
        Reply::ServerError(error) if matches!(error.code(), "ERR" | "NOPERM") => Ok(None),
        Reply::ServerError(error) => Err(server_error(&error)),
        reply => Ok(Some(reply)),
    }
}

// An empty reply is a parameter the server does not know.
fn reported_count(reply: &Reply) -> Option<u32> {
    let value = match reply {
        Reply::Array(pair) => pair.get(1)?,
        Reply::Map(pairs) => &pairs.first()?.1,
        _ => return None,
    };
    let count = match value {
        Reply::BulkString(bytes) => std::str::from_utf8(bytes).ok()?.trim().parse::<u32>().ok()?,
        Reply::SimpleString(text) => text.trim().parse::<u32>().ok()?,
        Reply::Int(count) => u32::try_from(*count).ok()?,
        _ => return None,
    };
    (1..=MOST).contains(&count).then_some(count)
}

fn text(reply: &Reply) -> Option<String> {
    match reply {
        Reply::BulkString(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        Reply::VerbatimString { text, .. } => Some(text.clone()),
        Reply::SimpleString(text) => Some(text.clone()),
        _ => None,
    }
}

// `db3:keys=12,expires=0,avg_ttl=0`, one line for each database that holds keys.
fn keyspace_databases(info: &str) -> Vec<u32> {
    info.lines()
        .filter_map(|line| {
            let (name, _) = line.trim().strip_prefix("db")?.split_once(':')?;
            name.parse::<u32>().ok().filter(|index| *index < MOST)
        })
        .collect()
}

fn resolve(holding: &[u32], own: u32) -> u32 {
    let highest = holding.iter().copied().chain([own]).max().unwrap_or(own);
    ASSUMED.max(highest.saturating_add(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk(text: &str) -> Reply {
        Reply::BulkString(text.as_bytes().to_vec())
    }

    #[test]
    fn config_get_gives_the_count_from_its_pair() {
        assert_eq!(
            reported_count(&Reply::Array(vec![bulk("databases"), bulk("16")])),
            Some(16)
        );
        assert_eq!(
            reported_count(&Reply::Map(vec![(bulk("databases"), bulk("100"))])),
            Some(100)
        );
        assert_eq!(
            reported_count(&Reply::Array(vec![bulk("databases"), Reply::Int(64)])),
            Some(64)
        );
    }

    #[test]
    fn a_parameter_the_server_does_not_know_or_a_count_out_of_range_says_nothing() {
        assert_eq!(reported_count(&Reply::Array(Vec::new())), None);
        assert_eq!(reported_count(&Reply::Array(vec![bulk("databases"), bulk("0")])), None);
        assert_eq!(
            reported_count(&Reply::Array(vec![bulk("databases"), bulk("2147483648")])),
            None
        );
        assert_eq!(
            reported_count(&Reply::Array(vec![bulk("databases"), bulk("many")])),
            None
        );
        assert_eq!(reported_count(&Reply::Nil), None);
    }

    #[test]
    fn the_keyspace_names_each_database_that_holds_keys() {
        let info = "# Keyspace\r\ndb0:keys=3,expires=0,avg_ttl=0\r\ndb20:keys=1,expires=1,avg_ttl=9\r\n";

        assert_eq!(keyspace_databases(info), [0, 20]);
        assert_eq!(keyspace_databases("# Keyspace\r\n"), Vec::<u32>::new());
        assert_eq!(keyspace_databases("dbx:keys=1\r\ndb:keys=1\r\n"), Vec::<u32>::new());
    }

    #[test]
    fn without_the_servers_count_the_list_reaches_past_every_database_known() {
        assert_eq!(resolve(&[], 0), 16);
        assert_eq!(resolve(&[0, 3], 0), 16);
        assert_eq!(resolve(&[0, 20], 0), 21);
        assert_eq!(resolve(&[], 40), 41);
        assert_eq!(resolve(&[99], 40), 100);
    }
}
