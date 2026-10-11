use super::interface::{ReadCandidates, ReadRoutingStrategy};
use crate::cluster_handling::NodeAddress;

/// Routes reads to a random replica node.
#[derive(Debug, Default)]
pub struct RandomReplicaStrategy;

impl ReadRoutingStrategy for RandomReplicaStrategy {
    fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
        match candidates {
            ReadCandidates::AnyNode(c) => c.replicas().choose_random(),
            ReadCandidates::ReplicasOnly(c) => c.replicas().choose_random(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster_handling::read_routing::Replicas;

    fn node(host: &str, port: u16) -> NodeAddress {
        NodeAddress::from_parts(host.into(), port)
    }

    #[test]
    fn chooses_replica_when_replicas_exist() {
        let primary = node("primary", 6379);
        let replicas = [node("replica1", 6379), node("replica2", 6379)];
        let candidates = ReadCandidates::any_node(0, &primary, Replicas::new(&replicas).unwrap());

        let strategy = RandomReplicaStrategy;
        let chosen = strategy.route_read(&candidates);
        assert!(replicas.contains(chosen));
    }

    #[test]
    fn chooses_replica_for_replicas_only() {
        let replicas = [node("replica1", 6379), node("replica2", 6379)];
        let candidates = ReadCandidates::replicas_only(0, Replicas::new(&replicas).unwrap());

        let strategy = RandomReplicaStrategy;
        let chosen = strategy.route_read(&candidates);
        assert!(replicas.contains(chosen));
    }
}
