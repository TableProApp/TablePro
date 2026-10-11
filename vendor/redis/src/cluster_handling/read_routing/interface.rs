use std::num::NonZeroUsize;
use std::sync::Arc;

use super::super::NodeAddress;
use super::super::slot_range_map::SlotRangeMap;

/// A snapshot of the topology for a single shard in the cluster.
///
/// A shard is a group of slot ranges served by the same set of nodes.
#[derive(Debug, Clone)]
pub struct Shard {
    slot_ranges: Arc<[(u16, u16)]>,
    primary: NodeAddress,
    replicas: Arc<[NodeAddress]>,
}

impl Shard {
    /// Creates a new shard.
    pub fn new(
        slot_ranges: impl Into<Arc<[(u16, u16)]>>,
        primary: NodeAddress,
        replicas: impl Into<Arc<[NodeAddress]>>,
    ) -> Self {
        Self {
            slot_ranges: slot_ranges.into(),
            primary,
            replicas: replicas.into(),
        }
    }

    /// The slot ranges owned by this shard. Each tuple is `(start, end)` inclusive.
    pub fn slot_ranges(&self) -> &[(u16, u16)] {
        &self.slot_ranges
    }

    /// The primary node for this shard.
    pub fn primary(&self) -> &NodeAddress {
        &self.primary
    }

    /// The replica nodes for this shard (may be empty).
    pub fn replicas(&self) -> &[NodeAddress] {
        &self.replicas
    }
}

/// A pre-built view of the cluster topology, organized by shard.
///
/// Provides iteration over all shards and O(log n) slot-to-shard lookup.
#[derive(Debug, Clone)]
pub struct ClusterTopology {
    slots: SlotRangeMap<Arc<Shard>>,
}

impl ClusterTopology {
    /// Build a topology from a list of shards.
    pub fn from_shards(shards: Vec<Shard>) -> Self {
        let mut slots = SlotRangeMap::new();
        for shard in shards {
            let shard = Arc::new(shard);
            for &(start, end) in shard.slot_ranges() {
                slots.insert(start, end, Arc::clone(&shard));
            }
        }
        Self { slots }
    }

    /// Returns the shard that owns the given slot, or `None` if the slot
    /// is not covered by any shard.
    pub fn shard_for_slot(&self, slot: u16) -> Option<&Shard> {
        self.slots.get(slot).map(|arc| arc.as_ref())
    }

    /// Iterates over all unique shards in the topology.
    pub fn shards(&self) -> impl Iterator<Item = &Shard> {
        let mut seen = std::collections::HashSet::new();
        self.slots
            .values()
            .filter(move |shard| seen.insert(Arc::as_ptr(shard)))
            .map(|arc| arc.as_ref())
    }
}

/// A non-empty slice of replica [`NodeAddress`]es.
///
/// This wrapper guarantees that the underlying slice contains at least one
/// element, so callers never need to handle the empty case.
#[derive(Debug)]
pub struct Replicas<'a> {
    inner: &'a [NodeAddress],
}

impl<'a> Replicas<'a> {
    /// Wraps a slice, returning `None` if it is empty.
    pub fn new(slice: &'a [NodeAddress]) -> Option<Self> {
        if slice.is_empty() {
            None
        } else {
            Some(Self { inner: slice })
        }
    }

    /// Returns the number of replicas (always >= 1).
    pub fn len(&self) -> NonZeroUsize {
        // SAFETY: Replicas is guaranteed non-empty by construction.
        NonZeroUsize::new(self.inner.len()).expect("Replicas is non-empty")
    }

    /// Returns the first replica (always present).
    pub fn first(&self) -> &'a NodeAddress {
        &self.inner[0]
    }

    /// Returns the replica at the given index, or `None` if out of bounds.
    pub fn get(&self, idx: usize) -> Option<&'a NodeAddress> {
        self.inner.get(idx)
    }

    /// Picks a uniformly random replica.
    pub fn choose_random(&self) -> &'a NodeAddress {
        use rand::seq::IndexedRandom;
        self.inner.choose(&mut rand::rng()).expect("non-empty")
    }

    /// Iterates over all replicas.
    pub fn iter(&self) -> impl Iterator<Item = &'a NodeAddress> {
        self.inner.iter()
    }
}

/// Candidates when any node (primary or replica) is acceptable for a read.
#[derive(Debug)]
pub struct AnyNodeCandidates<'a> {
    slot: u16,
    primary: &'a NodeAddress,
    replicas: Replicas<'a>,
}

impl<'a> AnyNodeCandidates<'a> {
    /// The exact slot being read.
    pub fn slot(&self) -> u16 {
        self.slot
    }

    /// The primary node for this shard.
    pub fn primary(&self) -> &'a NodeAddress {
        self.primary
    }

    /// The replicas for this shard (guaranteed non-empty).
    pub fn replicas(&self) -> &Replicas<'a> {
        &self.replicas
    }
}

/// Candidates when only replicas are acceptable for a read.
#[derive(Debug)]
pub struct ReplicasOnlyCandidates<'a> {
    slot: u16,
    replicas: Replicas<'a>,
}

impl<'a> ReplicasOnlyCandidates<'a> {
    /// The exact slot being read.
    pub fn slot(&self) -> u16 {
        self.slot
    }

    /// The replicas for this shard (guaranteed non-empty).
    pub fn replicas(&self) -> &Replicas<'a> {
        &self.replicas
    }
}

/// The candidate nodes passed to [`ReadRoutingStrategy::route_read`].
///
/// The strategy is only called when there are replicas available for the
/// target slot. If a slot has no replicas, the caller falls back to the
/// primary without consulting the strategy.
#[derive(Debug)]
pub enum ReadCandidates<'a> {
    /// Any node (primary or replica) is acceptable for this read.
    AnyNode(AnyNodeCandidates<'a>),
    /// A replica is required for this read.
    ReplicasOnly(ReplicasOnlyCandidates<'a>),
}

impl<'a> ReadCandidates<'a> {
    /// Returns the slot being read from.
    pub fn slot(&self) -> u16 {
        match self {
            ReadCandidates::AnyNode(c) => c.slot(),
            ReadCandidates::ReplicasOnly(c) => c.slot(),
        }
    }

    pub(crate) fn any_node(slot: u16, primary: &'a NodeAddress, replicas: Replicas<'a>) -> Self {
        ReadCandidates::AnyNode(AnyNodeCandidates {
            slot,
            primary,
            replicas,
        })
    }

    pub(crate) fn replicas_only(slot: u16, replicas: Replicas<'a>) -> Self {
        ReadCandidates::ReplicasOnly(ReplicasOnlyCandidates { slot, replicas })
    }
}

/// A strategy for choosing which node to route read commands to in a Redis Cluster.
///
/// [`route_read`](ReadRoutingStrategy::route_read) is called for each read command with
/// the [`ReadCandidates`] for the target slot. Return a reference to the chosen node.
///
/// Optionally, implement [`on_topology_changed`](ReadRoutingStrategy::on_topology_changed)
/// to receive notifications when the cluster topology is discovered or refreshed.
/// The [`ClusterTopology`] provides both an iterable shard list and O(log n)
/// slot-to-shard lookup — store it to correlate [`route_read`](Self::route_read)
/// calls with shards.
///
/// # Examples
///
/// Route reads to the first replica:
///
/// ```rust
/// use redis::cluster_read_routing::{ReadRoutingStrategy, ReadCandidates};
/// use redis::cluster::NodeAddress;
///
/// #[derive(Default)]
/// struct FirstReplica;
///
/// impl ReadRoutingStrategy for FirstReplica {
///     fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
///         match candidates {
///             ReadCandidates::AnyNode(c) => c.replicas().first(),
///             ReadCandidates::ReplicasOnly(c) => c.replicas().first(),
///         }
///     }
/// }
/// ```
pub trait ReadRoutingStrategy: Send + Sync {
    /// Called when the connection discovers or refreshes the cluster topology.
    ///
    /// The [`ClusterTopology`] groups slot ranges into shards by primary node.
    /// Strategies that need per-shard state should store this topology and use
    /// [`ClusterTopology::shard_for_slot`] during [`route_read`](Self::route_read)
    /// to identify which shard a read belongs to.
    ///
    /// This is called on every slot map refresh, including the initial topology
    /// discovery when a connection is first created. The default implementation
    /// does nothing.
    ///
    /// **Important:** This method is synchronous and is called on the connection's
    /// hot path. Implementations should return quickly — offload any expensive or
    /// async work (e.g. spawning probe tasks) rather than blocking here.
    fn on_topology_changed(&self, _topology: ClusterTopology) {}

    /// Choose which node within a shard to route a read command to.
    ///
    /// The returned reference must point to one of the addresses provided in
    /// the [`ReadCandidates`] (either the primary or one of the replicas).
    ///
    /// This function is only called when replicas are available. If a shard has only a primary,
    /// the client will simply fall back to the primary without invoking the strategy.
    fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress;
}

/// A factory for creating per-connection [`ReadRoutingStrategy`] instances.
///
/// This trait is stored in the cluster client and used to create a strategy instance
/// for each connection.
///
/// A blanket implementation is provided for any `T: ReadRoutingStrategy + Default + 'static`,
/// so simple nonsharing strategies work automatically without implementing this
/// trait explicitly.
///
/// By directly implementing this trait, you can share state between multiple strategy instances
/// (and thus between multiple connections).
///
/// For a more complex strategy example that makes use of this, see `examples/latency-aware-routing.rs`.
///
/// # Examples
///
/// ```rust,no_run
/// use redis::cluster_read_routing::{
///     ReadRoutingStrategy, ReadRoutingStrategyFactory, ReadCandidates,
/// };
/// use redis::cluster::NodeAddress;
///
/// struct MyStrategyFactory;
///
/// impl ReadRoutingStrategyFactory for MyStrategyFactory {
///     fn create_strategy(&self) -> Box<dyn ReadRoutingStrategy> {
///         Box::new(MyStrategy::new())
///     }
/// }
///
/// struct MyStrategy;
///
/// impl MyStrategy {
///     fn new() -> Self { MyStrategy }
/// }
///
/// impl ReadRoutingStrategy for MyStrategy {
///     fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
///         match candidates {
///             ReadCandidates::AnyNode(c) => c.replicas().first(),
///             ReadCandidates::ReplicasOnly(c) => c.replicas().first(),
///         }
///     }
/// }
/// ```
pub trait ReadRoutingStrategyFactory: Send + Sync {
    /// Create a new strategy instance.
    fn create_strategy(&self) -> Box<dyn ReadRoutingStrategy>;
}

impl<T: ReadRoutingStrategy + Default + 'static> ReadRoutingStrategyFactory for T {
    fn create_strategy(&self) -> Box<dyn ReadRoutingStrategy> {
        Box::new(T::default())
    }
}
