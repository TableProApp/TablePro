use std::collections::HashSet;

use super::NodeAddress;
use super::read_routing::{ClusterTopology, ReadCandidates, ReadRoutingStrategy, Replicas, Shard};
use super::slot_range_map::SlotRangeMap;
use crate::cluster_routing::{Route, SlotAddr};

pub(crate) const SLOT_SIZE: u16 = 16384;

#[derive(Debug, Default)]
pub(crate) struct SlotMap {
    slots: SlotRangeMap<SlotAddrs>,
}

impl SlotMap {
    pub fn new() -> Self {
        Self {
            slots: Default::default(),
        }
    }

    pub fn from_slots(slots: Vec<SlotRange>) -> Self {
        let mut map = SlotRangeMap::new();
        for slot in slots {
            map.insert(slot.start, slot.end, SlotAddrs::from_slot(slot));
        }
        Self { slots: map }
    }

    #[cfg(feature = "cluster-async")]
    pub fn fill_slots(&mut self, slots: Vec<SlotRange>) {
        for slot in slots {
            self.slots
                .insert(slot.start, slot.end, SlotAddrs::from_slot(slot));
        }
    }

    pub fn slot_addr_for_route(
        &self,
        route: Route,
        strategy: Option<&dyn ReadRoutingStrategy>,
    ) -> Option<&NodeAddress> {
        let slot = route.slot();
        self.slots
            .get(slot)
            .map(|addrs| addrs.slot_addr(slot, route.slot_addr(), strategy))
    }

    // TODO - Include the routing strategy in the fallback logic too.
    #[cfg(feature = "cluster-async")]
    pub(crate) fn shard_fallback_addrs(&self, route: Route) -> Vec<NodeAddress> {
        let Some(addrs) = self.slots.get(route.slot()) else {
            return Vec::new();
        };
        match route.slot_addr() {
            SlotAddr::Master => vec![],
            SlotAddr::ReplicaOptional => {
                let mut candidates = addrs.replicas.clone();
                candidates.push(addrs.primary.clone());
                candidates
            }
            SlotAddr::ReplicaRequired => addrs.replicas.clone(),
        }
    }

    #[cfg(feature = "cluster-async")]
    pub fn clear(&mut self) {
        self.slots.clear();
    }

    pub fn values(&self) -> impl Iterator<Item = &SlotAddrs> {
        self.slots.values()
    }

    fn all_unique_addresses(&self, only_primaries: bool) -> HashSet<&NodeAddress> {
        let mut addresses: HashSet<_> = HashSet::new();
        if only_primaries {
            addresses.extend(self.values().map(|slot_addrs| &slot_addrs.primary));
        } else {
            addresses.extend(self.values().flat_map(|slot_addrs| slot_addrs.into_iter()));
        }

        addresses
    }

    pub fn addresses_for_all_primaries(&self) -> HashSet<&NodeAddress> {
        self.all_unique_addresses(true)
    }

    pub fn addresses_for_all_nodes(&self) -> HashSet<&NodeAddress> {
        self.all_unique_addresses(false)
    }

    pub fn addresses_for_multi_slot<'a, 'b>(
        &'a self,
        routes: &'b [(Route, Vec<usize>)],
        strategy: Option<&'a dyn ReadRoutingStrategy>,
    ) -> impl Iterator<Item = Option<&'a NodeAddress>> + 'a
    where
        'b: 'a,
    {
        routes
            .iter()
            .map(move |(route, _)| self.slot_addr_for_route(*route, strategy))
    }

    /// Produces a [`ClusterTopology`] snapshot by grouping slot ranges by
    /// primary node into shards.
    pub fn topology(&self) -> ClusterTopology {
        struct ShardBuilder {
            primary: NodeAddress,
            slot_ranges: Vec<(u16, u16)>,
            replicas: Vec<NodeAddress>,
        }

        let mut builders: Vec<ShardBuilder> = Vec::new();
        for (start, end, addrs) in self.slots.iter() {
            if let Some(b) = builders.iter_mut().find(|b| b.primary == addrs.primary) {
                b.slot_ranges.push((start, end));
            } else {
                builders.push(ShardBuilder {
                    primary: addrs.primary.clone(),
                    slot_ranges: vec![(start, end)],
                    replicas: addrs.replicas.clone(),
                });
            }
        }

        ClusterTopology::from_shards(
            builders
                .into_iter()
                .map(|b| Shard::new(b.slot_ranges, b.primary, b.replicas))
                .collect(),
        )
    }
}

/// This is just a simplified version of [`SlotRange`],
/// which stores only the master and optional replica
/// to avoid the need to choose a replica each time
/// a command is executed
#[derive(Debug)]
pub(crate) struct SlotAddrs {
    primary: NodeAddress,
    replicas: Vec<NodeAddress>,
}

impl SlotAddrs {
    pub(crate) fn new(primary: NodeAddress, replicas: Vec<NodeAddress>) -> Self {
        Self { primary, replicas }
    }

    pub(crate) fn slot_addr(
        &self,
        slot: u16,
        slot_addr: SlotAddr,
        strategy: Option<&dyn ReadRoutingStrategy>,
    ) -> &NodeAddress {
        let Some(strategy) = strategy else {
            return match slot_addr {
                SlotAddr::Master | SlotAddr::ReplicaOptional => &self.primary,
                SlotAddr::ReplicaRequired => match Replicas::new(&self.replicas) {
                    Some(replicas) => replicas.choose_random(),
                    None => &self.primary,
                },
            };
        };
        match Replicas::new(&self.replicas) {
            Some(replicas) => match slot_addr {
                SlotAddr::Master => &self.primary,
                SlotAddr::ReplicaOptional => {
                    strategy.route_read(&ReadCandidates::any_node(slot, &self.primary, replicas))
                }
                SlotAddr::ReplicaRequired => {
                    strategy.route_read(&ReadCandidates::replicas_only(slot, replicas))
                }
            },
            None => &self.primary,
        }
    }

    pub(crate) fn from_slot(slot: SlotRange) -> Self {
        Self::new(slot.master, slot.replicas)
    }
}

impl<'a> IntoIterator for &'a SlotAddrs {
    type Item = &'a NodeAddress;
    type IntoIter =
        std::iter::Chain<std::iter::Once<&'a NodeAddress>, std::slice::Iter<'a, NodeAddress>>;

    fn into_iter(
        self,
    ) -> std::iter::Chain<std::iter::Once<&'a NodeAddress>, std::slice::Iter<'a, NodeAddress>> {
        std::iter::once(&self.primary).chain(self.replicas.iter())
    }
}

#[derive(Debug, PartialEq)]
pub(crate) struct SlotRange {
    pub(crate) start: u16,
    pub(crate) end: u16,
    pub(crate) master: NodeAddress,
    pub(crate) replicas: Vec<NodeAddress>,
}

impl SlotRange {
    pub fn new(s: u16, e: u16, m: NodeAddress, r: Vec<NodeAddress>) -> Self {
        Self {
            start: s,
            end: e,
            master: m,
            replicas: r,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster_handling::read_routing::ReadRoutingStrategy;
    use crate::cluster_routing::Slot;

    fn addr(s: &str) -> NodeAddress {
        NodeAddress::try_from(s).unwrap()
    }

    /// Always picks the first replica.
    #[derive(Default)]
    struct FirstReplicaStrategy;

    impl ReadRoutingStrategy for FirstReplicaStrategy {
        fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
            match candidates {
                ReadCandidates::AnyNode(c) => c.replicas().first(),
                ReadCandidates::ReplicasOnly(c) => c.replicas().first(),
            }
        }
    }

    #[test]
    fn test_slot_map_with_strategy() {
        let strategy = FirstReplicaStrategy;
        let slot_map = SlotMap::from_slots(vec![
            SlotRange {
                start: 1,
                end: 1000,
                master: addr("node1:6379"),
                replicas: vec![addr("replica1:6379")],
            },
            SlotRange {
                start: 1001,
                end: 2000,
                master: addr("node2:6379"),
                replicas: vec![addr("replica2:6379")],
            },
        ]);

        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node1:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(500).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node1:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1000).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node1:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1000).unwrap(), SlotAddr::ReplicaOptional),
                    Some(&strategy)
                )
                .unwrap(),
            "replica1:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1001).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node2:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1500).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node2:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(2000).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node2:6379"
        );
        assert!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(2001).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .is_none()
        );
    }

    #[test]
    fn test_slot_map_when_no_strategy_is_set() {
        let slot_map = SlotMap::from_slots(vec![SlotRange {
            start: 1,
            end: 1000,
            master: addr("node1:6379"),
            replicas: vec![addr("replica1:6379")],
        }]);

        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1000).unwrap(), SlotAddr::ReplicaOptional),
                    None
                )
                .unwrap(),
            "node1:6379"
        );
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(1000).unwrap(), SlotAddr::ReplicaRequired),
                    None
                )
                .unwrap(),
            "replica1:6379"
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn test_shard_fallback_addrs_master_is_empty() {
        let slot_map = get_slot_map();
        let fallback = slot_map
            .shard_fallback_addrs(Route::with_slot(Slot::new(1500).unwrap(), SlotAddr::Master));
        assert!(fallback.is_empty());
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn test_shard_fallback_addrs_replica_optional() {
        let slot_map = get_slot_map();
        let fallback = slot_map.shard_fallback_addrs(Route::with_slot(
            Slot::new(1500).unwrap(),
            SlotAddr::ReplicaOptional,
        ));
        assert_eq!(
            fallback,
            vec![
                addr("replica2:6379"),
                addr("replica3:6379"),
                addr("node2:6379")
            ]
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn test_shard_fallback_addrs_replica_requiredy() {
        let slot_map = get_slot_map();
        let fallback = slot_map.shard_fallback_addrs(Route::with_slot(
            Slot::new(2500).unwrap(),
            SlotAddr::ReplicaRequired,
        ));
        assert_eq!(
            fallback,
            vec![
                addr("replica4:6379"),
                addr("replica5:6379"),
                addr("replica6:6379")
            ]
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn test_shard_fallback_addrs_missing_slot_is_empty() {
        let slot_map = get_slot_map();
        let fallback = slot_map.shard_fallback_addrs(Route::with_slot(
            Slot::new(1001).unwrap(),
            SlotAddr::ReplicaOptional,
        ));
        assert!(fallback.is_empty());
    }

    fn get_slot_map() -> SlotMap {
        SlotMap::from_slots(vec![
            SlotRange::new(1, 1000, addr("node1:6379"), vec![addr("replica1:6379")]),
            SlotRange::new(
                1002,
                2000,
                addr("node2:6379"),
                vec![addr("replica2:6379"), addr("replica3:6379")],
            ),
            SlotRange::new(
                2001,
                3000,
                addr("node3:6379"),
                vec![
                    addr("replica4:6379"),
                    addr("replica5:6379"),
                    addr("replica6:6379"),
                ],
            ),
            SlotRange::new(
                3001,
                4000,
                addr("node2:6379"),
                vec![addr("replica2:6379"), addr("replica3:6379")],
            ),
        ])
    }

    #[test]
    fn test_slot_map_get_all_primaries() {
        let slot_map = get_slot_map();
        let addresses = slot_map.addresses_for_all_primaries();
        assert_eq!(
            addresses,
            HashSet::from_iter([
                &addr("node1:6379"),
                &addr("node2:6379"),
                &addr("node3:6379")
            ])
        );
    }

    #[test]
    fn test_slot_map_get_all_nodes() {
        let slot_map = get_slot_map();
        let addresses = slot_map.addresses_for_all_nodes();
        assert_eq!(
            addresses,
            HashSet::from_iter([
                &addr("node1:6379"),
                &addr("node2:6379"),
                &addr("node3:6379"),
                &addr("replica1:6379"),
                &addr("replica2:6379"),
                &addr("replica3:6379"),
                &addr("replica4:6379"),
                &addr("replica5:6379"),
                &addr("replica6:6379")
            ])
        );
    }

    #[test]
    fn test_slot_map_get_multi_node() {
        let strategy = FirstReplicaStrategy;
        let slot_map = get_slot_map();
        let routes = vec![
            (
                Route::with_slot(Slot::new(1).unwrap(), SlotAddr::Master),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2001).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
        ];
        let addresses = slot_map
            .addresses_for_multi_slot(&routes, Some(&strategy))
            .collect::<Vec<_>>();
        assert_eq!(
            addresses,
            vec![Some(&addr("node1:6379")), Some(&addr("replica4:6379"))]
        );
    }

    #[test]
    fn test_slot_map_should_ignore_replicas_in_multi_slot_if_no_strategy_is_set() {
        let slot_map = get_slot_map();
        let routes = vec![
            (
                Route::with_slot(Slot::new(1).unwrap(), SlotAddr::Master),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2001).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
        ];
        let addresses = slot_map
            .addresses_for_multi_slot(&routes, None)
            .collect::<Vec<_>>();
        assert_eq!(
            addresses,
            vec![Some(&addr("node1:6379")), Some(&addr("node3:6379"))]
        );
    }

    /// This test is needed in order to verify that if the MultiSlot route finds the same node for more than a single route,
    /// that node's address will appear multiple times, in the same order.
    #[test]
    fn test_slot_map_get_repeating_addresses_when_the_same_node_is_found_in_multi_slot() {
        let strategy = FirstReplicaStrategy;
        let slot_map = get_slot_map();
        let routes = vec![
            (
                Route::with_slot(Slot::new(1).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2001).unwrap(), SlotAddr::Master),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2002).unwrap(), SlotAddr::Master),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(3).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2003).unwrap(), SlotAddr::Master),
                vec![],
            ),
        ];
        let addresses = slot_map
            .addresses_for_multi_slot(&routes, Some(&strategy))
            .collect::<Vec<_>>();
        assert_eq!(
            addresses,
            vec![
                Some(&addr("replica1:6379")),
                Some(&addr("node3:6379")),
                Some(&addr("replica1:6379")),
                Some(&addr("node3:6379")),
                Some(&addr("replica1:6379")),
                Some(&addr("node3:6379"))
            ]
        );
    }

    #[test]
    fn test_slot_map_get_none_when_slot_is_missing_from_multi_slot() {
        let strategy = FirstReplicaStrategy;
        let slot_map = get_slot_map();
        let routes = vec![
            (
                Route::with_slot(Slot::new(1).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(5000).unwrap(), SlotAddr::Master),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(6000).unwrap(), SlotAddr::ReplicaOptional),
                vec![],
            ),
            (
                Route::with_slot(Slot::new(2002).unwrap(), SlotAddr::Master),
                vec![],
            ),
        ];
        let addresses = slot_map
            .addresses_for_multi_slot(&routes, Some(&strategy))
            .collect::<Vec<_>>();
        assert_eq!(
            addresses,
            vec![
                Some(&addr("replica1:6379")),
                None,
                None,
                Some(&addr("node3:6379"))
            ]
        );
    }

    #[test]
    fn test_slot_map_topology() {
        let slot_map = SlotMap::from_slots(vec![
            SlotRange::new(0, 5000, addr("node1:6379"), vec![addr("replica1:6379")]),
            SlotRange::new(5001, 10000, addr("node2:6379"), vec![]),
        ]);
        let topo = slot_map.topology();
        assert_eq!(topo.shards().count(), 2);

        let node1 = topo
            .shards()
            .find(|s| s.primary() == &addr("node1:6379"))
            .unwrap();
        assert_eq!(node1.slot_ranges(), &[(0, 5000)]);
        assert_eq!(node1.replicas(), &[addr("replica1:6379")]);

        let node2 = topo
            .shards()
            .find(|s| s.primary() == &addr("node2:6379"))
            .unwrap();
        assert_eq!(node2.slot_ranges(), &[(5001, 10000)]);
        assert!(node2.replicas().is_empty());
    }

    #[test]
    fn test_slot_map_topology_groups_by_primary() {
        let slot_map = get_slot_map();
        let topo = slot_map.topology();
        // node2 has two ranges (1002-2000 and 3001-4000), should be one shard
        assert_eq!(topo.shards().count(), 3);
        let node2_shard = topo
            .shards()
            .find(|s| s.primary() == &addr("node2:6379"))
            .unwrap();
        assert_eq!(node2_shard.slot_ranges(), &[(1002, 2000), (3001, 4000)]);
    }

    #[test]
    fn test_slot_map_topology_shard_lookup() {
        let slot_map = get_slot_map();
        let topo = slot_map.topology();

        let shard = topo.shard_for_slot(500).unwrap();
        assert_eq!(shard.primary(), &addr("node1:6379"));

        let shard = topo.shard_for_slot(1500).unwrap();
        assert_eq!(shard.primary(), &addr("node2:6379"));

        // Slot 3500 is in the second range of node2's shard
        let shard = topo.shard_for_slot(3500).unwrap();
        assert_eq!(shard.primary(), &addr("node2:6379"));

        assert!(topo.shard_for_slot(5000).is_none());
    }

    #[test]
    fn test_custom_strategy() {
        /// Always picks the first replica.
        #[derive(Default)]
        struct AlwaysFirstReplica;

        impl ReadRoutingStrategy for AlwaysFirstReplica {
            fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
                match candidates {
                    ReadCandidates::AnyNode(c) => c.replicas().first(),
                    ReadCandidates::ReplicasOnly(c) => c.replicas().first(),
                }
            }
        }

        let strategy = AlwaysFirstReplica;
        let slot_map = SlotMap::from_slots(vec![SlotRange::new(
            1,
            1000,
            addr("node1:6379"),
            vec![addr("replica1:6379"), addr("replica2:6379")],
        )]);

        // ReplicaOptional with AlwaysFirstReplica should always return replica1
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(500).unwrap(), SlotAddr::ReplicaOptional),
                    Some(&strategy)
                )
                .unwrap(),
            "replica1:6379"
        );

        // ReplicaRequired with AlwaysFirstReplica should also return replica1
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(500).unwrap(), SlotAddr::ReplicaRequired),
                    Some(&strategy)
                )
                .unwrap(),
            "replica1:6379"
        );

        // Master always returns primary regardless of strategy
        assert_eq!(
            slot_map
                .slot_addr_for_route(
                    Route::with_slot(Slot::new(500).unwrap(), SlotAddr::Master),
                    Some(&strategy)
                )
                .unwrap(),
            "node1:6379"
        );
    }
}
