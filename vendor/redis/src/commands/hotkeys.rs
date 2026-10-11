//! Defines types to use with the HOTKEYS commands.
//!
//! The HOTKEYS command is a stateful, node-local command requiring session affinity.
//! It should only be used on standalone clients (Connection, MultiplexedConnection, etc.)
//! and NOT on cluster clients (ClusterConnection).
//!
//! # Command Syntax (Redis 8.6.0+)
//!
//! ```text
//! HOTKEYS START METRICS count [CPU] [NET] [COUNT k] [DURATION seconds] [SAMPLE ratio] [SLOTS count slot [slot ...]]
//! HOTKEYS GET
//! HOTKEYS STOP
//! HOTKEYS RESET
//! ```
//!
//! # Using HOTKEYS in Cluster Mode
//!
//! While the high-level `HotkeysCommands` trait is not available on `ClusterConnection`,
//! HOTKEYS commands can still be used in cluster mode through `route_command` with
//! explicit routing. Two patterns are useful:
//!
//! ## Routing to a single node
//!
//! Useful for inspecting a specific shard, e.g. when investigating a known hot slot.
//!
//! ```rust,no_run
//! # #[cfg(feature = "cluster")]
//! # {
//! use redis::cluster::ClusterClient;
//! use redis::cluster_routing::{RoutingInfo, SingleNodeRoutingInfo};
//! use redis::{cmd, FromRedisValue, HotkeysOptions, HotkeysResponse};
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/"];
//! let client = ClusterClient::new(nodes).unwrap();
//! let mut connection = client.get_connection().unwrap();
//!
//! // Route to a specific node
//! let routing = RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress {
//!     host: "127.0.0.1".to_string(),
//!     port: 6379,
//! });
//!
//! // Start tracking on that specific node - track keys by CPU time percentage
//! let opts = HotkeysOptions::new_with_cpu();
//! let _ = connection.route_command(
//!     &cmd("HOTKEYS").arg("START").arg(opts),
//!     routing.clone()
//! ).unwrap();
//!
//! // ... perform operations ...
//!
//! // Get metrics from the same node
//! let value = connection.route_command(
//!     &cmd("HOTKEYS").arg("GET"),
//!     routing.clone()
//! ).unwrap();
//! let response = HotkeysResponse::from_redis_value(value).unwrap();
//!
//! // Stop tracking on that node
//! let _ = connection.route_command(
//!     &cmd("HOTKEYS").arg("STOP"),
//!     routing
//! ).unwrap();
//! # }
//! ```
//!
//! ## Routing to all primaries (cluster-wide tracking)
//!
//! For cluster-wide observability the natural pattern is to fan the command out to
//! every primary so each shard tracks its own keys. `START` and `STOP` can use
//! [`ResponsePolicy::AllSucceeded`](crate::cluster_routing::ResponsePolicy::AllSucceeded)
//! to assert every node accepted the command. `GET` should be issued without a
//! response policy: the response is then a [`Value::Map`] keyed by node address,
//! and each entry is parsed with [`HotkeysResponse::from_redis_value`].
//!
//! ```rust,no_run
//! # #[cfg(feature = "cluster")]
//! # {
//! use redis::cluster::ClusterClient;
//! use redis::cluster_routing::{
//!     MultipleNodeRoutingInfo, ResponsePolicy, RoutingInfo,
//! };
//! use redis::{cmd, from_redis_value, FromRedisValue, HotkeysOptions, HotkeysResponse, Value};
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/"];
//! let client = ClusterClient::new(nodes).unwrap();
//! let mut connection = client.get_connection().unwrap();
//!
//! // START on every primary and require success everywhere.
//! // `with_slots` is not used in here and each primary tracks the keys for the slots it owns.
//! let start_opts = HotkeysOptions::new_with_cpu().and_net();
//! let _ = connection.route_command(
//!     &cmd("HOTKEYS").arg("START").arg(&start_opts),
//!     RoutingInfo::MultiNode((
//!         MultipleNodeRoutingInfo::AllMasters,
//!         Some(ResponsePolicy::AllSucceeded),
//!     )),
//! ).unwrap();
//!
//! // ... perform operations ...
//!
//! // GET from every primary with no policy.
//! // The cluster client will get back the per-node responses.
//! let value = connection.route_command(
//!     &cmd("HOTKEYS").arg("GET"),
//!     RoutingInfo::MultiNode((MultipleNodeRoutingInfo::AllMasters, None)),
//! ).unwrap();
//! if let Value::Map(per_node) = value {
//!     for (addr_val, response_val) in per_node {
//!         let addr: String = from_redis_value(addr_val).unwrap();
//!         let snapshot = HotkeysResponse::from_redis_value(response_val).unwrap();
//!         println!("node {addr}: {} hot keys by CPU",
//!             snapshot.by_cpu_time_us.as_ref().map(|v| v.len()).unwrap_or(0));
//!     }
//! }
//!
//! // STOP on every primary.
//! let _ = connection.route_command(
//!     &cmd("HOTKEYS").arg("STOP"),
//!     RoutingInfo::MultiNode((
//!         MultipleNodeRoutingInfo::AllMasters,
//!         Some(ResponsePolicy::AllSucceeded),
//!     )),
//! ).unwrap();
//! # }
//! ```

use crate::errors::ParsingError;
use crate::types::{FromRedisValue, RedisWrite, ToRedisArgs, Value};
use std::collections::HashMap;

/// Minimum value for the COUNT parameter of HOTKEYS START.
pub const HOTKEYS_COUNT_MIN: u64 = 1;
/// Maximum value for the COUNT parameter of HOTKEYS START.
pub const HOTKEYS_COUNT_MAX: u64 = 64;

/// Options for the HOTKEYS START command.
///
/// At least one of `cpu` or `net` must be enabled to specify which metrics to collect.
/// The `METRICS count` is automatically derived from how many metric types are enabled.
///
/// Use [`HotkeysOptions::new_with_cpu()`] or [`HotkeysOptions::new_with_net()`] constructors to create
/// valid options with at least one metric enabled.
///
/// # Example
///
/// ```rust,no_run
/// use redis::{HotkeysOptions, HotkeysCommands};
///
/// # fn example() -> redis::RedisResult<()> {
/// let client = redis::Client::open("redis://127.0.0.1/")?;
/// let mut con = client.get_connection()?;
///
/// // Track hotkeys by both CPU and network usage for 60 seconds
/// let opts = HotkeysOptions::new_with_cpu()
///     .and_net()
///     .with_duration_secs(60);
///
/// con.hotkeys_start(opts)?;
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct HotkeysOptions {
    /// Track hotkeys by CPU time percentage
    cpu: bool,
    /// Track hotkeys by network bytes percentage
    net: bool,
    /// Value of K for top-K hotkeys tracking (optional COUNT parameter)
    count_k: Option<u64>,
    /// Duration in seconds for tracking (optional DURATION parameter)
    duration_secs: Option<u64>,
    /// Sampling ratio for probabilistic tracking (optional SAMPLE parameter)
    sample_ratio: Option<u64>,
    /// Specific slots to track in cluster mode (optional SLOTS parameter)
    slots: Option<Vec<u16>>,
}

impl HotkeysOptions {
    /// Creates options to track hotkeys by CPU time percentage.
    ///
    /// # Example
    ///
    /// ```rust
    /// use redis::HotkeysOptions;
    ///
    /// // Track hotkeys by CPU time
    /// let opts = HotkeysOptions::new_with_cpu();
    ///
    /// // Track by both CPU and network
    /// let opts = HotkeysOptions::new_with_cpu().and_net();
    /// ```
    pub fn new_with_cpu() -> Self {
        Self {
            cpu: true,
            net: false,
            count_k: None,
            duration_secs: None,
            sample_ratio: None,
            slots: None,
        }
    }

    /// Creates options to track hotkeys by network bytes percentage.
    ///
    /// # Example
    ///
    /// ```rust
    /// use redis::HotkeysOptions;
    ///
    /// // Track hotkeys by network bytes
    /// let opts = HotkeysOptions::new_with_net();
    ///
    /// // Track by both network and CPU
    /// let opts = HotkeysOptions::new_with_net().and_cpu();
    /// ```
    pub fn new_with_net() -> Self {
        Self {
            cpu: false,
            net: true,
            count_k: None,
            duration_secs: None,
            sample_ratio: None,
            slots: None,
        }
    }

    /// Also track hotkeys by CPU time percentage.
    ///
    /// Used when both metrics are needed and the options were created using [`HotkeysOptions::new_with_net()`]
    pub fn and_cpu(mut self) -> Self {
        self.cpu = true;
        self
    }

    /// Also track hotkeys by network bytes percentage.
    ///
    /// Used when both metrics are needed and the options were created using [`HotkeysOptions::new_with_cpu()`]
    pub fn and_net(mut self) -> Self {
        self.net = true;
        self
    }

    /// Returns the number of metrics being tracked.
    fn metrics_count(&self) -> u64 {
        self.cpu as u64 + self.net as u64
    }

    /// Set the value of K for top-K hotkeys tracking.
    ///
    /// This is the COUNT parameter in the Redis command.
    ///
    /// # Errors
    /// Returns an error if `k` is not in the valid range `1..=64`
    /// (see [`HOTKEYS_COUNT_MIN`] and [`HOTKEYS_COUNT_MAX`]).
    pub fn with_count(mut self, k: u64) -> Result<Self, String> {
        if !(HOTKEYS_COUNT_MIN..=HOTKEYS_COUNT_MAX).contains(&k) {
            return Err(format!(
                "COUNT must be between {HOTKEYS_COUNT_MIN} and {HOTKEYS_COUNT_MAX}, got: {k}"
            ));
        }
        self.count_k = Some(k);
        Ok(self)
    }

    /// Set the duration in seconds for how long tracking should run.
    ///
    /// After this time period, tracking will automatically stop.
    /// If not specified, tracking continues until manually stopped with HOTKEYS STOP.
    pub fn with_duration_secs(mut self, seconds: u64) -> Self {
        self.duration_secs = Some(seconds);
        self
    }

    /// Set the sampling ratio for probabilistic tracking.
    ///
    /// Each key is sampled with probability 1/ratio. Higher values reduce
    /// performance impact but may miss some hotkeys. Lower values provide
    /// more accurate results but with higher performance cost.
    pub fn with_sample_ratio(mut self, ratio: u64) -> Self {
        self.sample_ratio = Some(ratio);
        self
    }

    /// Set specific hash slots to track in a cluster environment.
    ///
    /// Only keys that hash to the specified slots will be tracked.
    /// Useful for narrowing tracking to a subset of the slots owned by a single shard.
    ///
    /// # When to use
    ///
    /// This option is meaningful only in cluster mode and only with **single-node**
    /// routing (e.g. [`RoutingInfo::SingleNode`](crate::cluster_routing::RoutingInfo::SingleNode))
    /// targeting a primary that owns the requested slots. The Redis server will
    /// reject the command if any of the requested slots are not owned by the
    /// receiving node.
    ///
    /// When fanning the command out to every node (e.g.
    /// [`MultipleNodeRoutingInfo::AllMasters`](crate::cluster_routing::MultipleNodeRoutingInfo::AllMasters)),
    /// omit `with_slots` and let each primary track the keys for the slots it
    /// owns, otherwise every primary that does not own the supplied slot list
    /// will return an error.
    ///
    /// Note: Using SLOTS when not in cluster mode will result in an error.
    pub fn with_slots(mut self, slots: Vec<u16>) -> Self {
        self.slots = Some(slots);
        self
    }
}

impl ToRedisArgs for HotkeysOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        // METRICS count [CPU] [NET] - required
        out.write_arg(b"METRICS");
        out.write_arg_fmt(self.metrics_count());

        if self.cpu {
            out.write_arg(b"CPU");
        }

        if self.net {
            out.write_arg(b"NET");
        }

        // Optional: COUNT k
        if let Some(k) = self.count_k {
            out.write_arg(b"COUNT");
            out.write_arg_fmt(k);
        }

        // Optional: DURATION seconds
        if let Some(secs) = self.duration_secs {
            out.write_arg(b"DURATION");
            out.write_arg_fmt(secs);
        }

        // Optional: SAMPLE ratio
        if let Some(ratio) = self.sample_ratio {
            out.write_arg(b"SAMPLE");
            out.write_arg_fmt(ratio);
        }

        // Optional: SLOTS count slot [slot ...]
        if let Some(ref slots) = self.slots {
            out.write_arg(b"SLOTS");
            out.write_arg_fmt(slots.len());
            for slot in slots {
                out.write_arg_fmt(slot);
            }
        }
    }

    fn num_of_args(&self) -> usize {
        // METRICS + count
        let mut n = 2;
        n += self.cpu as usize;
        n += self.net as usize;
        if self.count_k.is_some() {
            n += 2;
        }
        if self.duration_secs.is_some() {
            n += 2;
        }
        if self.sample_ratio.is_some() {
            n += 2;
        }
        if let Some(ref slots) = self.slots {
            // SLOTS + count + one arg per slot
            n += 2 + slots.len();
        }
        n
    }
}

/// A single hotkey entry with its metric value.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub struct HotKeyEntry {
    /// The key name.
    pub key: String,
    /// The metric value (CPU time in microseconds or network bytes, depending on context).
    pub value: u64,
}

/// Represents a range of slots.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub struct SlotRange {
    /// Start of the slot range (inclusive).
    pub start: u16,
    /// End of the slot range (inclusive).
    pub end: u16,
}

/// Response from the HOTKEYS GET command.
///
/// Contains information about the hotkeys tracking session,
/// including tracking metadata, performance statistics, and lists of top K
/// hot keys sorted by the metrics specified in HOTKEYS START.
#[derive(Debug, Clone, PartialEq, Default)]
#[non_exhaustive]
pub struct HotkeysResponse {
    /// Whether tracking is currently active (1) or stopped (0).
    pub tracking_active: bool,
    /// The sampling ratio used during tracking.
    pub sample_ratio: u64,
    /// Array of selected slot ranges.
    pub selected_slots: Vec<SlotRange>,
    /// CPU time in microseconds for all commands on all slots.
    pub all_commands_all_slots_us: u64,
    /// Network bytes for all commands on all slots.
    pub net_bytes_all_commands_all_slots: u64,
    /// Unix timestamp in milliseconds when tracking started.
    pub collection_start_time_unix_ms: u64,
    /// Duration of tracking in milliseconds.
    pub collection_duration_ms: u64,
    /// User CPU time used in milliseconds (only when CPU metric was specified).
    pub total_cpu_time_user_ms: Option<u64>,
    /// System CPU time used in milliseconds (only when CPU metric was specified).
    pub total_cpu_time_sys_ms: Option<u64>,
    /// Total network bytes processed (only when NET metric was specified).
    pub total_net_bytes: Option<u64>,
    /// Array of hotkeys sorted by CPU time in microseconds (only when CPU metric was specified).
    pub by_cpu_time_us: Option<Vec<HotKeyEntry>>,
    /// Array of hotkeys sorted by network bytes (only when NET metric was specified).
    pub by_net_bytes: Option<Vec<HotKeyEntry>>,

    // Cluster-specific fields (when SLOTS was used)
    /// CPU time in microseconds for sampled commands in selected slots (cluster mode with SAMPLE).
    pub sampled_commands_selected_slots_us: Option<u64>,
    /// CPU time in microseconds for all commands in selected slots (cluster mode).
    pub all_commands_selected_slots_us: Option<u64>,
    /// Network bytes for sampled commands in selected slots (cluster mode with SAMPLE).
    pub net_bytes_sampled_commands_selected_slots: Option<u64>,
    /// Network bytes for all commands on selected slots (cluster mode).
    pub net_bytes_all_commands_selected_slots: Option<u64>,
}

/// Helper to strip surrounding quotes from a string if present
fn strip_quotes(s: String) -> String {
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s
    }
}

/// Helper function to parse a key-value pair array into HotKeyEntry vec
fn parse_hotkey_entries(arr: &[Value]) -> Result<Vec<HotKeyEntry>, ParsingError> {
    use crate::types::from_redis_value_ref;

    let mut entries = Vec::with_capacity(arr.len() / 2);

    let mut iter = arr.iter();
    while let Some(key_val) = iter.next() {
        let key: String = from_redis_value_ref(key_val)?;
        // Strip surrounding quotes if present (Redis returns quoted keys)
        let key = strip_quotes(key);
        let value: u64 = iter
            .next()
            .ok_or_else(|| ParsingError::from("Expected value after key in hotkey entry"))
            .and_then(from_redis_value_ref)?;

        entries.push(HotKeyEntry { key, value });
    }

    Ok(entries)
}

/// Helper function to parse slot ranges from the selected-slots array
fn parse_slot_ranges(arr: &[Value]) -> Result<Vec<SlotRange>, ParsingError> {
    use crate::types::from_redis_value_ref;

    let mut ranges = Vec::with_capacity(arr.len());

    for item in arr {
        let Value::Array(range_arr) = item else {
            crate::errors::invalid_type_error!("Expected array for slot range", item);
        };

        match range_arr.len() {
            1 => {
                let slot: u16 = from_redis_value_ref(&range_arr[0])?;
                ranges.push(SlotRange {
                    start: slot,
                    end: slot,
                });
            }
            n if n >= 2 => {
                let start: u16 = from_redis_value_ref(&range_arr[0])?;
                let end: u16 = from_redis_value_ref(&range_arr[1])?;
                ranges.push(SlotRange { start, end });
            }
            _ => crate::errors::invalid_type_error!("Empty slot range entry", range_arr),
        }
    }

    Ok(ranges)
}

impl FromRedisValue for HotkeysResponse {
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        use crate::types::from_redis_value;

        // Redis 8.6 wraps every HOTKEYS GET response in a single-element outer
        // array with one entry per tracking session. Unwrap it here so the inner
        // value (Array of field/value pairs in RESP2, Map in RESP3) can be
        // parsed uniformly below. The passthrough arm keeps unit-test fixtures
        // that build the inner value directly working without needing to
        // mirror the server's outer wrapping.
        let v = match v {
            Value::Array(mut arr) if arr.len() == 1 => arr.remove(0),
            other => other,
        };

        // The response can be an Array (RESP2) or Map (RESP3)
        // Parse it into a HashMap for easier field access
        let mut fields: HashMap<String, Value> = match v {
            Value::Array(arr) => {
                // RESP2: flat array with alternating field names and values
                let mut map = HashMap::new();
                let mut iter = arr.into_iter();
                while let Some(key) = iter.next() {
                    let key_str: String = from_redis_value(key)?;
                    // Strip surrounding quotes if present (Redis returns quoted keys)
                    let key_str = strip_quotes(key_str);
                    if let Some(val) = iter.next() {
                        map.insert(key_str, val);
                    }
                }
                map
            }
            Value::Map(pairs) => {
                // RESP3: proper map
                let mut map = HashMap::new();
                for (k, v) in pairs {
                    let key_str: String = from_redis_value(k)?;
                    let key_str = strip_quotes(key_str);
                    map.insert(key_str, v);
                }
                map
            }
            _ => {
                crate::errors::invalid_type_error!(
                    "Expected array or map response for HOTKEYS GET",
                    v
                );
            }
        };

        let mut response = Self::default();

        // Parse required fields
        if let Some(v) = fields.remove("tracking-active") {
            response.tracking_active = from_redis_value::<i64>(v)? != 0;
        }

        if let Some(v) = fields.remove("sample-ratio") {
            response.sample_ratio = from_redis_value(v)?;
        }

        if let Some(Value::Array(arr)) = fields.remove("selected-slots") {
            response.selected_slots = parse_slot_ranges(&arr)?;
        }

        if let Some(v) = fields.remove("all-commands-all-slots-us") {
            response.all_commands_all_slots_us = from_redis_value(v)?;
        }

        if let Some(v) = fields.remove("net-bytes-all-commands-all-slots") {
            response.net_bytes_all_commands_all_slots = from_redis_value(v)?;
        }

        if let Some(v) = fields.remove("collection-start-time-unix-ms") {
            response.collection_start_time_unix_ms = from_redis_value(v)?;
        }

        if let Some(v) = fields.remove("collection-duration-ms") {
            response.collection_duration_ms = from_redis_value(v)?;
        }

        // Parse optional CPU-related fields
        if let Some(v) = fields.remove("total-cpu-time-user-ms") {
            response.total_cpu_time_user_ms = Some(from_redis_value(v)?);
        }

        if let Some(v) = fields.remove("total-cpu-time-sys-ms") {
            response.total_cpu_time_sys_ms = Some(from_redis_value(v)?);
        }

        if let Some(Value::Array(arr)) = fields.remove("by-cpu-time-us") {
            response.by_cpu_time_us = Some(parse_hotkey_entries(&arr)?);
        }

        // Parse optional NET-related fields
        if let Some(v) = fields.remove("total-net-bytes") {
            response.total_net_bytes = Some(from_redis_value(v)?);
        }

        if let Some(Value::Array(arr)) = fields.remove("by-net-bytes") {
            response.by_net_bytes = Some(parse_hotkey_entries(&arr)?);
        }

        // Parse cluster-specific fields
        if let Some(v) = fields.remove("sampled-commands-selected-slots-us") {
            response.sampled_commands_selected_slots_us = Some(from_redis_value(v)?);
        }

        if let Some(v) = fields.remove("all-commands-selected-slots-us") {
            response.all_commands_selected_slots_us = Some(from_redis_value(v)?);
        }

        if let Some(v) = fields.remove("net-bytes-sampled-commands-selected-slots") {
            response.net_bytes_sampled_commands_selected_slots = Some(from_redis_value(v)?);
        }

        if let Some(v) = fields.remove("net-bytes-all-commands-selected-slots") {
            response.net_bytes_all_commands_selected_slots = Some(from_redis_value(v)?);
        }

        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hotkeys_options_cpu_constructor() {
        let opts = HotkeysOptions::new_with_cpu();
        assert_eq!(opts.num_of_args(), 3); // METRICS 1 CPU
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 3);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"CPU");
    }

    #[test]
    fn test_hotkeys_options_net_constructor() {
        let opts = HotkeysOptions::new_with_net();
        assert_eq!(opts.num_of_args(), 3); // METRICS 1 NET
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 3);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"NET");
    }

    #[test]
    fn test_hotkeys_options_cpu_and_net() {
        let opts = HotkeysOptions::new_with_cpu().and_net();
        assert_eq!(opts.num_of_args(), 4); // METRICS 2 CPU NET
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 4);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"2");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"NET");
    }

    #[test]
    fn test_hotkeys_options_net_and_cpu() {
        let opts = HotkeysOptions::new_with_net().and_cpu();
        assert_eq!(opts.num_of_args(), 4); // METRICS 2 CPU NET
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 4);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"2");
        // CPU comes before NET in serialization order
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"NET");
    }

    #[test]
    fn test_hotkeys_options_with_duration() {
        let opts = HotkeysOptions::new_with_cpu().with_duration_secs(60);
        assert_eq!(opts.num_of_args(), 5); // METRICS 1 CPU DURATION 60
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 5);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"DURATION");
        assert_eq!(args[4], b"60");
    }

    #[test]
    fn test_hotkeys_options_with_count() {
        let opts = HotkeysOptions::new_with_cpu().with_count(50).unwrap();
        assert_eq!(opts.num_of_args(), 5); // METRICS 1 CPU COUNT 50
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 5);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"COUNT");
        assert_eq!(args[4], b"50");
    }

    #[test]
    fn test_hotkeys_options_with_count_min_valid() {
        let opts = HotkeysOptions::new_with_cpu()
            .with_count(HOTKEYS_COUNT_MIN)
            .unwrap();
        let args = opts.to_redis_args();
        assert_eq!(args[3], b"COUNT");
        assert_eq!(args[4], HOTKEYS_COUNT_MIN.to_string().as_bytes());
    }

    #[test]
    fn test_hotkeys_options_with_count_max_valid() {
        let opts = HotkeysOptions::new_with_cpu()
            .with_count(HOTKEYS_COUNT_MAX)
            .unwrap();
        let args = opts.to_redis_args();
        assert_eq!(args[3], b"COUNT");
        assert_eq!(args[4], HOTKEYS_COUNT_MAX.to_string().as_bytes());
    }

    #[test]
    fn test_hotkeys_options_with_count_too_low() {
        let result = HotkeysOptions::new_with_cpu().with_count(HOTKEYS_COUNT_MIN - 1);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains(&format!(
            "COUNT must be between {HOTKEYS_COUNT_MIN} and {HOTKEYS_COUNT_MAX}"
        )));
    }

    #[test]
    fn test_hotkeys_options_with_count_too_high() {
        let result = HotkeysOptions::new_with_cpu().with_count(HOTKEYS_COUNT_MAX + 1);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains(&format!(
            "COUNT must be between {HOTKEYS_COUNT_MIN} and {HOTKEYS_COUNT_MAX}"
        )));
    }

    #[test]
    fn test_hotkeys_options_with_sample() {
        let opts = HotkeysOptions::new_with_cpu().with_sample_ratio(1000);
        assert_eq!(opts.num_of_args(), 5); // METRICS 1 CPU SAMPLE 1000
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 5);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"SAMPLE");
        assert_eq!(args[4], b"1000");
    }

    #[test]
    fn test_hotkeys_options_with_slots() {
        let opts = HotkeysOptions::new_with_cpu().with_slots(vec![0, 100, 200]);
        assert_eq!(opts.num_of_args(), 8); // METRICS 1 CPU SLOTS 3 0 100 200
        let args = opts.to_redis_args();
        assert_eq!(args.len(), 8);
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"1");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"SLOTS");
        assert_eq!(args[4], b"3");
        assert_eq!(args[5], b"0");
        assert_eq!(args[6], b"100");
        assert_eq!(args[7], b"200");
    }

    #[test]
    fn test_hotkeys_options_full() {
        let opts = HotkeysOptions::new_with_cpu()
            .and_net()
            .with_count(50)
            .unwrap()
            .with_duration_secs(120)
            .with_sample_ratio(500);
        // METRICS 2 CPU NET COUNT 50 DURATION 120 SAMPLE 500
        assert_eq!(opts.num_of_args(), 10);
        let args = opts.to_redis_args();
        assert_eq!(args[0], b"METRICS");
        assert_eq!(args[1], b"2");
        assert_eq!(args[2], b"CPU");
        assert_eq!(args[3], b"NET");
        assert_eq!(args[4], b"COUNT");
        assert_eq!(args[5], b"50");
        assert_eq!(args[6], b"DURATION");
        assert_eq!(args[7], b"120");
        assert_eq!(args[8], b"SAMPLE");
        assert_eq!(args[9], b"500");
    }

    #[test]
    fn test_hotkeys_response_parsing_resp2() {
        use crate::Value;

        // Simulate RESP2 flat array response
        let response = Value::Array(vec![
            Value::BulkString(b"tracking-active".to_vec()),
            Value::Int(1),
            Value::BulkString(b"sample-ratio".to_vec()),
            Value::Int(1),
            Value::BulkString(b"selected-slots".to_vec()),
            Value::Array(vec![Value::Array(vec![Value::Int(0), Value::Int(16383)])]),
            Value::BulkString(b"all-commands-all-slots-us".to_vec()),
            Value::Int(5000),
            Value::BulkString(b"net-bytes-all-commands-all-slots".to_vec()),
            Value::Int(2048),
            Value::BulkString(b"collection-start-time-unix-ms".to_vec()),
            Value::Int(1700000000000),
            Value::BulkString(b"collection-duration-ms".to_vec()),
            Value::Int(10000),
            Value::BulkString(b"total-cpu-time-user-ms".to_vec()),
            Value::Int(100),
            Value::BulkString(b"total-cpu-time-sys-ms".to_vec()),
            Value::Int(50),
            Value::BulkString(b"by-cpu-time-us".to_vec()),
            Value::Array(vec![
                Value::BulkString(b"key1".to_vec()),
                Value::Int(1500),
                Value::BulkString(b"key2".to_vec()),
                Value::Int(750),
            ]),
        ]);

        let result = HotkeysResponse::from_redis_value(response).unwrap();

        assert!(result.tracking_active);
        assert_eq!(result.sample_ratio, 1);
        assert_eq!(result.selected_slots.len(), 1);
        assert_eq!(result.selected_slots[0].start, 0);
        assert_eq!(result.selected_slots[0].end, 16383);
        assert_eq!(result.all_commands_all_slots_us, 5000);
        assert_eq!(result.net_bytes_all_commands_all_slots, 2048);
        assert_eq!(result.collection_start_time_unix_ms, 1700000000000);
        assert_eq!(result.collection_duration_ms, 10000);
        assert_eq!(result.total_cpu_time_user_ms, Some(100));
        assert_eq!(result.total_cpu_time_sys_ms, Some(50));

        let cpu_keys = result.by_cpu_time_us.unwrap();
        assert_eq!(cpu_keys.len(), 2);
        assert_eq!(cpu_keys[0].key, "key1");
        assert_eq!(cpu_keys[0].value, 1500);
        assert_eq!(cpu_keys[1].key, "key2");
        assert_eq!(cpu_keys[1].value, 750);
    }

    #[test]
    fn test_hotkeys_response_parsing_resp3() {
        use crate::Value;

        // Simulate RESP3 map response.
        let response = Value::Map(vec![
            (
                Value::BulkString(b"tracking-active".to_vec()),
                Value::Int(1),
            ),
            (Value::BulkString(b"sample-ratio".to_vec()), Value::Int(1)),
            (
                Value::BulkString(b"selected-slots".to_vec()),
                Value::Array(vec![Value::Array(vec![Value::Int(0), Value::Int(16383)])]),
            ),
            (
                Value::BulkString(b"all-commands-all-slots-us".to_vec()),
                Value::Int(5000),
            ),
            (
                Value::BulkString(b"all-commands-selected-slots-us".to_vec()),
                Value::Int(4000),
            ),
            (
                Value::BulkString(b"net-bytes-all-commands-all-slots".to_vec()),
                Value::Int(2048),
            ),
            (
                Value::BulkString(b"net-bytes-all-commands-selected-slots".to_vec()),
                Value::Int(1024),
            ),
            (
                Value::BulkString(b"collection-start-time-unix-ms".to_vec()),
                Value::Int(1700000000000),
            ),
            (
                Value::BulkString(b"collection-duration-ms".to_vec()),
                Value::Int(10000),
            ),
            (
                Value::BulkString(b"total-cpu-time-user-ms".to_vec()),
                Value::Int(100),
            ),
            (
                Value::BulkString(b"total-cpu-time-sys-ms".to_vec()),
                Value::Int(50),
            ),
            (
                Value::BulkString(b"by-cpu-time-us".to_vec()),
                Value::Array(vec![
                    Value::BulkString(b"key1".to_vec()),
                    Value::Int(1500),
                    Value::BulkString(b"key2".to_vec()),
                    Value::Int(750),
                ]),
            ),
        ]);

        let result = HotkeysResponse::from_redis_value(response).unwrap();

        assert!(result.tracking_active);
        assert_eq!(result.sample_ratio, 1);
        assert_eq!(result.selected_slots.len(), 1);
        assert_eq!(result.selected_slots[0].start, 0);
        assert_eq!(result.selected_slots[0].end, 16383);
        assert_eq!(result.all_commands_all_slots_us, 5000);
        assert_eq!(result.all_commands_selected_slots_us, Some(4000));
        assert_eq!(result.net_bytes_all_commands_all_slots, 2048);
        assert_eq!(result.net_bytes_all_commands_selected_slots, Some(1024));
        assert_eq!(result.collection_start_time_unix_ms, 1700000000000);
        assert_eq!(result.collection_duration_ms, 10000);
        assert_eq!(result.total_cpu_time_user_ms, Some(100));
        assert_eq!(result.total_cpu_time_sys_ms, Some(50));

        let cpu_keys = result.by_cpu_time_us.unwrap();
        assert_eq!(cpu_keys.len(), 2);
        assert_eq!(cpu_keys[0].key, "key1");
        assert_eq!(cpu_keys[0].value, 1500);
        assert_eq!(cpu_keys[1].key, "key2");
        assert_eq!(cpu_keys[1].value, 750);
    }

    #[test]
    fn test_hotkeys_response_parsing_with_net() {
        use crate::Value;

        let response = Value::Array(vec![
            Value::BulkString(b"tracking-active".to_vec()),
            Value::Int(0),
            Value::BulkString(b"sample-ratio".to_vec()),
            Value::Int(1),
            Value::BulkString(b"selected-slots".to_vec()),
            Value::Array(vec![]),
            Value::BulkString(b"all-commands-all-slots-us".to_vec()),
            Value::Int(0),
            Value::BulkString(b"net-bytes-all-commands-all-slots".to_vec()),
            Value::Int(4096),
            Value::BulkString(b"collection-start-time-unix-ms".to_vec()),
            Value::Int(1700000000000),
            Value::BulkString(b"collection-duration-ms".to_vec()),
            Value::Int(5000),
            Value::BulkString(b"total-net-bytes".to_vec()),
            Value::Int(8192),
            Value::BulkString(b"by-net-bytes".to_vec()),
            Value::Array(vec![
                Value::BulkString(b"bigkey".to_vec()),
                Value::Int(4096),
                Value::BulkString(b"smallkey".to_vec()),
                Value::Int(256),
            ]),
        ]);

        let result = HotkeysResponse::from_redis_value(response).unwrap();

        assert!(!result.tracking_active);
        assert_eq!(result.total_net_bytes, Some(8192));

        let net_keys = result.by_net_bytes.unwrap();
        assert_eq!(net_keys.len(), 2);
        assert_eq!(net_keys[0].key, "bigkey");
        assert_eq!(net_keys[0].value, 4096);
        assert_eq!(net_keys[1].key, "smallkey");
        assert_eq!(net_keys[1].value, 256);
    }

    #[test]
    fn test_hotkeys_response_nil() {
        use crate::Value;
        use crate::types::from_redis_value;

        // Redis returns `Nil` for HOTKEYS GET when there is no active tracking
        // session (e.g. never started, stopped, or reset). `hotkeys_get` decodes
        // into `Option<HotkeysResponse>`, so `Nil` must surface as `None` rather
        // than a default-constructed response.
        let response = Value::Nil;
        let result: Option<HotkeysResponse> = from_redis_value(response).unwrap();
        assert!(result.is_none());
    }
}
