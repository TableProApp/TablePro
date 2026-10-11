//! This module provides the functionality to refresh and calculate the cluster topology for Redis Cluster.

use std::collections::HashSet;

use arcstr::ArcStr;

use super::NodeAddress;
use super::slot_map::SlotRange;
use crate::{RedisResult, Value, connection::is_wildcard_address};

// Parse slot data from raw redis value.
pub(crate) fn parse_slots(
    raw_slot_resp: Value,
    // The DNS address of the node from which `raw_slot_resp` was received.
    addr_of_answering_node: &str,
) -> RedisResult<Vec<SlotRange>> {
    // Parse response.
    let mut slots = Vec::with_capacity(2);
    let mut hosts = HashSet::<ArcStr>::new();

    if let Value::Array(items) = raw_slot_resp {
        let mut iter = items.into_iter();
        while let Some(Value::Array(item)) = iter.next() {
            if item.len() < 3 {
                continue;
            }

            let start = if let Value::Int(start) = item[0] {
                start as u16
            } else {
                continue;
            };

            let end = if let Value::Int(end) = item[1] {
                end as u16
            } else {
                continue;
            };

            let mut try_to_address = |node: Value| {
                let Value::Array(node) = node else {
                    return None;
                };
                if node.len() < 2 {
                    return None;
                }
                // According to the CLUSTER SLOTS documentation:
                // If the received hostname is an empty string or NULL, clients should utilize the hostname of the responding node.
                // However, if the received hostname is "?", it should be regarded as an indication of an unknown node.
                let hostname = if let Value::BulkString(ref ip) = node[0] {
                    let hostname = String::from_utf8_lossy(ip);
                    if hostname.is_empty() || is_wildcard_address(&hostname) {
                        addr_of_answering_node.into()
                    } else if hostname == "?" {
                        return None;
                    } else {
                        hostname
                    }
                } else if let Value::Nil = node[0] {
                    addr_of_answering_node.into()
                } else {
                    return None;
                };
                if hostname.is_empty() {
                    return None;
                }

                let port = if let Value::Int(port) = node[1] {
                    port as u16
                } else {
                    return None;
                };
                // if the hostname was already seen, we'll prefer to take it, in order to reduce fragmentation
                let hostname = match hosts.get(hostname.as_ref()) {
                    Some(host) => host.clone(),
                    None => {
                        let hostname: ArcStr = hostname.into();
                        hosts.insert(hostname.clone());
                        hostname
                    }
                };
                Some(NodeAddress::new(hostname, port))
            };

            let mut iterator = item.into_iter().skip(2);
            let mut primary = None;
            while primary.is_none() {
                let Some(node) = iterator.next() else {
                    break;
                };
                primary = try_to_address(node);
            }
            let Some(primary) = primary else {
                continue;
            };
            let replicas: Vec<NodeAddress> = iterator.filter_map(try_to_address).collect();

            slots.push(SlotRange::new(start, end, primary, replicas));
        }
    }

    Ok(slots)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slot_value_with_replicas(start: u16, end: u16, nodes: Vec<(&str, u16)>) -> Value {
        let mut node_values: Vec<Value> = nodes
            .iter()
            .map(|(host, port)| {
                Value::Array(vec![
                    Value::BulkString(host.as_bytes().to_vec()),
                    Value::Int(*port as i64),
                ])
            })
            .collect();
        let mut slot_vec = vec![Value::Int(start as i64), Value::Int(end as i64)];
        slot_vec.append(&mut node_values);
        Value::Array(slot_vec)
    }

    fn slot_value(start: u16, end: u16, node: &str, port: u16) -> Value {
        slot_value_with_replicas(start, end, vec![(node, port)])
    }

    #[test]
    fn parse_slots_returns_slots_with_host_name_if_missing() {
        let view = Value::Array(vec![slot_value(0, 4000, "", 6379)]);

        let slots = parse_slots(view, "node").unwrap();
        assert_eq!(slots[0].master, "node:6379");
    }

    #[test]
    fn parse_slots_treats_wildcard_hostnames_as_answering_node() {
        // Master advertised as 0.0.0.0 should be treated as the answering node's host
        let view = Value::Array(vec![slot_value_with_replicas(
            0,
            100,
            vec![("0.0.0.0", 7000)],
        )]);
        let slots = parse_slots(view, "answer.host").unwrap();
        assert_eq!(slots[0].master, "answer.host:7000");

        // IPv6 wildcard :: similarly falls back to answering node
        let view_v6 = Value::Array(vec![slot_value_with_replicas(200, 300, vec![("::", 7001)])]);
        let slots_v6 = parse_slots(view_v6, "answer6.host").unwrap();
        assert_eq!(slots_v6[0].master, "answer6.host:7001");
    }
}
