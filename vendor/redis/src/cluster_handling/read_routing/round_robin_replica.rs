use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};

use super::interface::{ClusterTopology, ReadCandidates, ReadRoutingStrategy};
use crate::cluster_handling::NodeAddress;
use crate::cluster_handling::slot_range_map::SlotRangeMap;

/// Per-shard counters indexed by slot range for O(log n) lookup.
/// All ranges belonging to the same shard share one `Arc<AtomicUsize>`.
struct SlotCounters {
    slots: SlotRangeMap<Arc<AtomicUsize>>,
}

/// Routes reads to replica nodes in round-robin order.
///
/// Each instance maintains an independent counter **per shard** that increments
/// on every call to [`route_read`](ReadRoutingStrategy::route_read). This
/// ensures that reads to different shards rotate independently — a hot shard
/// won't skew the rotation for other shards.
pub struct RoundRobinReplicaStrategy {
    state: Arc<RwLock<SlotCounters>>,
}

impl RoundRobinReplicaStrategy {
    /// Creates a new `RoundRobinReplicaStrategy` with all counters starting at 0.
    pub fn new() -> Self {
        Self::default()
    }
}

impl Default for RoundRobinReplicaStrategy {
    fn default() -> Self {
        Self {
            state: Arc::new(RwLock::new(SlotCounters {
                slots: SlotRangeMap::new(),
            })),
        }
    }
}

impl ReadRoutingStrategy for RoundRobinReplicaStrategy {
    fn on_topology_changed(&self, topology: ClusterTopology) {
        let mut slots = SlotRangeMap::new();
        for shard in topology.shards() {
            let counter = Arc::new(AtomicUsize::new(0));
            for &(start, end) in shard.slot_ranges() {
                slots.insert(start, end, Arc::clone(&counter));
            }
        }
        let mut state = self.state.write().expect("Lock poisoned");
        state.slots = slots;
    }

    fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
        let slot = candidates.slot();
        let idx = {
            let state = self.state.read().expect("Lock poisoned");
            state
                .slots
                .get(slot)
                .map(|counter| counter.fetch_add(1, Ordering::Relaxed))
                .unwrap_or(0)
        };

        let replicas = match candidates {
            ReadCandidates::AnyNode(c) => c.replicas(),
            ReadCandidates::ReplicasOnly(c) => c.replicas(),
        };
        replicas.get(idx % replicas.len()).expect("non-empty")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster_handling::read_routing::{Replicas, Shard};

    fn node(host: &str, port: u16) -> NodeAddress {
        NodeAddress::from_parts(host.into(), port)
    }

    fn setup_strategy() -> RoundRobinReplicaStrategy {
        let strategy = RoundRobinReplicaStrategy::new();
        // Two shards: shard 1 owns slots 0-1000, shard 2 owns slots 1001-2000.
        strategy.on_topology_changed(ClusterTopology::from_shards(vec![
            Shard::new(
                vec![(0, 1000)],
                node("primary1", 6379),
                vec![node("replica1a", 6379), node("replica1b", 6379)],
            ),
            Shard::new(
                vec![(1001, 2000)],
                node("primary2", 6379),
                vec![node("replica2a", 6379), node("replica2b", 6379)],
            ),
        ]));
        strategy
    }

    #[test]
    fn round_robins_within_a_shard() {
        let strategy = setup_strategy();
        let replica_a = node("replica1a", 6379);
        let replica_b = node("replica1b", 6379);
        let replicas = [replica_a.clone(), replica_b.clone()];

        let candidates = ReadCandidates::replicas_only(1, Replicas::new(&replicas).unwrap());

        // Two full cycles: a, b, a, b
        assert_eq!(strategy.route_read(&candidates), &replica_a);
        assert_eq!(strategy.route_read(&candidates), &replica_b);
        assert_eq!(strategy.route_read(&candidates), &replica_a);
        assert_eq!(strategy.route_read(&candidates), &replica_b);
    }

    #[test]
    fn different_shards_rotate_independently() {
        let strategy = setup_strategy();

        let replicas1 = [node("replica1a", 6379), node("replica1b", 6379)];
        let replicas2 = [node("replica2a", 6379), node("replica2b", 6379)];

        let candidates1 = ReadCandidates::replicas_only(1, Replicas::new(&replicas1).unwrap());
        let candidates2 = ReadCandidates::replicas_only(1001, Replicas::new(&replicas2).unwrap());

        // interleave — each shard keeps its own position.
        assert_eq!(strategy.route_read(&candidates1), &replicas1[0]);
        assert_eq!(strategy.route_read(&candidates2), &replicas2[0]); // shard 2 starts fresh
        assert_eq!(strategy.route_read(&candidates1), &replicas1[1]);
        assert_eq!(strategy.route_read(&candidates2), &replicas2[1]);
        // Second cycle
        assert_eq!(strategy.route_read(&candidates1), &replicas1[0]);
        assert_eq!(strategy.route_read(&candidates2), &replicas2[0]);
    }

    #[test]
    fn round_robins_any_node_with_replicas() {
        let strategy = setup_strategy();
        let primary = node("primary1", 6379);
        let replica_a = node("replica1a", 6379);
        let replica_b = node("replica1b", 6379);
        let replicas = [replica_a.clone(), replica_b.clone()];

        let candidates = ReadCandidates::any_node(1, &primary, Replicas::new(&replicas).unwrap());

        // Two full cycles through replicas: a, b, a, b
        assert_eq!(strategy.route_read(&candidates), &replica_a);
        assert_eq!(strategy.route_read(&candidates), &replica_b);
        assert_eq!(strategy.route_read(&candidates), &replica_a);
        assert_eq!(strategy.route_read(&candidates), &replica_b);
    }

    #[test]
    fn multiple_ranges_on_same_shard_share_counter() {
        let strategy = RoundRobinReplicaStrategy::new();
        // One shard (same primary) owns two disjoint ranges: 0-1000 and 2001-3000.
        strategy.on_topology_changed(ClusterTopology::from_shards(vec![
            Shard::new(
                vec![(0, 1000), (2001, 3000)],
                node("primary1", 6379),
                vec![node("replica1a", 6379), node("replica1b", 6379)],
            ),
            Shard::new(
                vec![(1001, 2000)],
                node("primary2", 6379),
                vec![node("replica2a", 6379), node("replica2b", 6379)],
            ),
        ]));

        let replicas = [node("replica1a", 6379), node("replica1b", 6379)];

        let candidates_low = ReadCandidates::replicas_only(500, Replicas::new(&replicas).unwrap());
        let candidates_high =
            ReadCandidates::replicas_only(2500, Replicas::new(&replicas).unwrap());

        // Reading from slot 500 advances the shared counter.
        assert_eq!(strategy.route_read(&candidates_low), &replicas[0]);
        // Reading from slot 2500 sees the same counter (same shard), so it continues.
        assert_eq!(strategy.route_read(&candidates_high), &replicas[1]);
        // Back to low range — counter keeps advancing.
        assert_eq!(strategy.route_read(&candidates_low), &replicas[0]);
        assert_eq!(strategy.route_read(&candidates_high), &replicas[1]);
    }
}
