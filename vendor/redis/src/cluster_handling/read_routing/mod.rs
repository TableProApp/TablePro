//! Pluggable read routing strategies for cluster connections.
//!
//! In a cluster each shard has a primary and zero or more replicas.
//! By default all reads go to the primary. A `ReadRoutingStrategy` chooses
//! which node within a shard should handle each read — for example picking
//! a random replica, round-robin across replicas, or selecting the
//! lowest-latency node.
//!
//! This module contains the trait definitions for implementing custom
//! strategies and some built-in strategies.
//!
//! See `examples/latency-aware-routing.rs` for a more complex custom strategy.

mod interface;
mod random_replica;
mod round_robin_replica;

pub use interface::{
    AnyNodeCandidates, ClusterTopology, ReadCandidates, ReadRoutingStrategy,
    ReadRoutingStrategyFactory, Replicas, ReplicasOnlyCandidates, Shard,
};
pub use random_replica::RandomReplicaStrategy;
pub use round_robin_replica::RoundRobinReplicaStrategy;
