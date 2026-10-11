use super::ClusterConnection;
use crate::RedisError;
use crate::cmd::{Cmd, cmd};
use crate::errors::ErrorKind;
use crate::types::{FromRedisValue, HashSet, RedisResult, ToRedisArgs, Value, from_redis_value};

pub(crate) const UNROUTABLE_ERROR: (ErrorKind, &str) = (
    ErrorKind::Client,
    "This command cannot be safely routed in cluster mode",
);

fn is_illegal_cmd(cmd: &str) -> bool {
    matches!(
        cmd,
        "BGREWRITEAOF" | "BGSAVE" | "BITOP" | "BRPOPLPUSH" |
        // All commands that start with "CLIENT"
        "CLIENT" | "CLIENT GETNAME" | "CLIENT KILL" | "CLIENT LIST" | "CLIENT SETNAME" |
        // All commands that start with "CONFIG"
        "CONFIG" | "CONFIG GET" | "CONFIG RESETSTAT" | "CONFIG REWRITE" | "CONFIG SET" |
        "DBSIZE" |
        "ECHO" |
        "FLUSHALL" | "FLUSHDB" |
        "INFO" |
        "KEYS" |
        "LASTSAVE" |
        "MGET" | "MOVE" | "MSET" | "MSETNX" | "MSETEX" |
        "PING" | "PUBLISH" |
        "RANDOMKEY" | "RENAME" | "RENAMENX" | "RPOPLPUSH" |
        "SAVE" | "SCAN" |
        // All commands that start with "SCRIPT"
        "SCRIPT" | "SCRIPT EXISTS" | "SCRIPT FLUSH" | "SCRIPT KILL" | "SCRIPT LOAD" |
        "SDIFF" | "SDIFFSTORE" |
        // All commands that start with "SENTINEL"
        "SENTINEL" | "SENTINEL GET MASTER ADDR BY NAME" | "SENTINEL MASTER" | "SENTINEL MASTERS" |
        "SENTINEL MONITOR" | "SENTINEL REMOVE" | "SENTINEL SENTINELS" | "SENTINEL SET" |
        "SENTINEL SLAVES" | "SHUTDOWN" | "SINTER" | "SINTERSTORE" | "SLAVEOF" |
        // All commands that start with "SLOWLOG"
        "SLOWLOG" | "SLOWLOG GET" | "SLOWLOG LEN" | "SLOWLOG RESET" |
        "SMOVE" | "SORT" | "SUNION" | "SUNIONSTORE" |
        "TIME"
    )
}

/// Represents a Redis Cluster command pipeline.
#[derive(Clone)]
pub struct ClusterPipeline {
    commands: Vec<Cmd>,
    ignored_commands: HashSet<usize>,
    ignore_errors: bool,
}

/// A cluster pipeline is almost identical to a normal [Pipeline](crate::pipeline::Pipeline), with two exceptions:
/// * It does not support transactions
/// * The following commands can not be used in a cluster pipeline:
/// ```text
/// BGREWRITEAOF, BGSAVE, BITOP, BRPOPLPUSH
/// CLIENT GETNAME, CLIENT KILL, CLIENT LIST, CLIENT SETNAME, CONFIG GET,
/// CONFIG RESETSTAT, CONFIG REWRITE, CONFIG SET
/// DBSIZE
/// ECHO, EVALSHA
/// FLUSHALL, FLUSHDB
/// INFO
/// KEYS
/// LASTSAVE
/// MGET, MOVE, MSET, MSETNX, MSETEX
/// PING, PUBLISH
/// RANDOMKEY, RENAME, RENAMENX, RPOPLPUSH
/// SAVE, SCAN, SCRIPT EXISTS, SCRIPT FLUSH, SCRIPT KILL, SCRIPT LOAD, SDIFF, SDIFFSTORE,
/// SENTINEL GET MASTER ADDR BY NAME, SENTINEL MASTER, SENTINEL MASTERS, SENTINEL MONITOR,
/// SENTINEL REMOVE, SENTINEL SENTINELS, SENTINEL SET, SENTINEL SLAVES, SHUTDOWN, SINTER,
/// SINTERSTORE, SLAVEOF, SLOWLOG GET, SLOWLOG LEN, SLOWLOG RESET, SMOVE, SORT, SUNION, SUNIONSTORE
/// TIME
/// ```
impl ClusterPipeline {
    /// Create an empty pipeline.
    pub fn new() -> Self {
        Self::with_capacity(0)
    }

    /// Creates an empty pipeline with pre-allocated capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            commands: Vec::with_capacity(capacity),
            ignored_commands: HashSet::new(),
            ignore_errors: false,
        }
    }

    pub(crate) fn commands(&self) -> &Vec<Cmd> {
        &self.commands
    }

    /// Executes the pipeline and fetches the return values:
    ///
    /// ```rust,no_run
    /// # let nodes = vec!["redis://127.0.0.1:6379/"];
    /// # let client = redis::cluster::ClusterClient::new(nodes).unwrap();
    /// # let mut con = client.get_connection().unwrap();
    /// let mut pipe = redis::cluster::cluster_pipe();
    /// let (k1, k2) : (i32, i32) = pipe
    ///     .cmd("SET").arg("key_1").arg(42).ignore()
    ///     .cmd("SET").arg("key_2").arg(43).ignore()
    ///     .cmd("GET").arg("key_1")
    ///     .cmd("GET").arg("key_2").query(&mut con).unwrap();
    /// ```
    #[inline]
    pub fn query<T: FromRedisValue>(&self, con: &mut ClusterConnection) -> RedisResult<T> {
        for cmd in &self.commands {
            let cmd_name = std::str::from_utf8(cmd.arg_idx(0).unwrap_or(b""))
                .unwrap_or("")
                .trim()
                .to_ascii_uppercase();

            if is_illegal_cmd(&cmd_name) {
                fail!((
                    UNROUTABLE_ERROR.0,
                    UNROUTABLE_ERROR.1,
                    format!("Command '{cmd_name}' can't be executed in a cluster pipeline.")
                ))
            }
        }

        if self.commands.is_empty() {
            Err(RedisError::make_empty_command())
        } else {
            self.compose_response(con.execute_pipeline(self)?)
        }
    }

    /// This is an alternative to `query`` that can be used if you want to be able to handle a
    /// command's success or failure but don't care about the command's response. For example,
    /// this is useful for "SET" commands for which the response's content is not important.
    /// It avoids the need to define generic bounds for ().
    #[inline]
    pub fn exec(&self, con: &mut ClusterConnection) -> RedisResult<()> {
        self.query::<()>(con)
    }
}

/// Shortcut for creating a new cluster pipeline.
pub fn cluster_pipe() -> ClusterPipeline {
    ClusterPipeline::new()
}

implement_pipeline_commands!(ClusterPipeline);
