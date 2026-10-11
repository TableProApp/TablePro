use crate::{
    Cmd, RedisResult,
    cluster_handling::NodeAddress,
    cluster_routing::{
        MultipleNodeRoutingInfo, Redirect, ResponsePolicy, Route, RoutingInfo,
        SingleNodeRoutingInfo, SlotAddr,
    },
    errors::ServerErrorKind,
};

#[derive(Clone)]
pub(super) enum InternalRoutingInfo<C> {
    SingleNode(InternalSingleNodeRouting<C>),
    MultiNode((MultipleNodeRoutingInfo, Option<ResponsePolicy>)),
}

impl<C> std::fmt::Debug for InternalRoutingInfo<C> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SingleNode(arg0) => f.debug_tuple("SingleNode").field(arg0).finish(),
            Self::MultiNode(arg0) => f.debug_tuple("MultiNode").field(arg0).finish(),
        }
    }
}

impl<C> From<RoutingInfo> for InternalRoutingInfo<C> {
    fn from(value: RoutingInfo) -> Self {
        match value {
            RoutingInfo::SingleNode(route) => Self::SingleNode(route.into()),
            RoutingInfo::MultiNode(routes) => Self::MultiNode(routes),
        }
    }
}

impl<C> From<InternalSingleNodeRouting<C>> for InternalRoutingInfo<C> {
    fn from(value: InternalSingleNodeRouting<C>) -> Self {
        Self::SingleNode(value)
    }
}

#[derive(Clone, Default)]
pub(super) enum InternalSingleNodeRouting<C> {
    #[default]
    Random,
    SpecificNode(Route),
    ByAddress(NodeAddress),
    Connection {
        identifier: NodeAddress,
        conn: C,
    },
    Redirect {
        redirect: Redirect,
        previous_routing: Box<Self>,
    },
}

impl<C> std::fmt::Debug for InternalSingleNodeRouting<C> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Random => write!(f, "Random"),
            Self::SpecificNode(arg0) => f.debug_tuple("SpecificNode").field(arg0).finish(),
            Self::ByAddress(arg0) => f.debug_tuple("ByAddress").field(arg0).finish(),
            Self::Connection {
                identifier,
                conn: _conn,
            } => f
                .debug_struct("Connection")
                .field("identifier", identifier)
                .finish(),
            Self::Redirect {
                redirect,
                previous_routing,
            } => f
                .debug_struct("Redirect")
                .field("redirect", redirect)
                .field("previous_routing", previous_routing)
                .finish(),
        }
    }
}

impl<C> From<SingleNodeRoutingInfo> for InternalSingleNodeRouting<C> {
    fn from(value: SingleNodeRoutingInfo) -> Self {
        match value {
            SingleNodeRoutingInfo::Random => Self::Random,
            SingleNodeRoutingInfo::SpecificNode(route) => Self::SpecificNode(route),
            SingleNodeRoutingInfo::ByAddress { host, port } => {
                Self::ByAddress(NodeAddress::new(host, port))
            }
            SingleNodeRoutingInfo::RandomPrimary => Self::SpecificNode(Route::new_random_primary()),
        }
    }
}

pub(super) fn route_for_pipeline(pipeline: &crate::Pipeline) -> RedisResult<Option<Route>> {
    fn route_for_command(cmd: &Cmd) -> Option<Route> {
        match RoutingInfo::for_routable(cmd) {
            Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::SpecificNode(route))) => {
                Some(route)
            }
            Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::RandomPrimary)) => {
                Some(Route::new_random_primary())
            }
            Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random))
            | Some(RoutingInfo::MultiNode(_))
            | Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress { .. }))
            | None => None,
        }
    }

    // Find first specific slot and send to it. There's no need to check If later commands
    // should be routed to a different slot, since the server will return an error indicating this.
    pipeline.cmd_iter().map(route_for_command).try_fold(
        None,
        |chosen_route, next_cmd_route| match (chosen_route, next_cmd_route) {
            (None, _) => Ok(next_cmd_route),
            (_, None) => Ok(chosen_route),
            (Some(chosen_route), Some(next_cmd_route)) => {
                if chosen_route.slot() != next_cmd_route.slot() {
                    Err((
                        ServerErrorKind::CrossSlot.into(),
                        "Received crossed slots in pipeline",
                    )
                        .into())
                } else if chosen_route.slot_addr() != SlotAddr::Master {
                    Ok(Some(next_cmd_route))
                } else {
                    Ok(Some(chosen_route))
                }
            }
        },
    )
}

#[cfg(test)]
mod pipeline_routing_tests {
    use super::route_for_pipeline;
    use crate::cluster_routing::Slot;
    use crate::{
        cluster_routing::{Route, SlotAddr},
        cmd,
    };

    #[test]
    fn test_first_route_is_found() {
        let mut pipeline = crate::Pipeline::new();

        pipeline
            .flushall() // route to all masters
            .get("foo") // route to slot 12182
            .add_command(cmd("EVAL")); // route randomly

        assert_eq!(
            route_for_pipeline(&pipeline),
            Ok(Some(Route::with_slot(
                Slot::new(12182).unwrap(),
                SlotAddr::ReplicaOptional
            )))
        );
    }

    #[test]
    fn test_return_none_if_no_route_is_found() {
        let mut pipeline = crate::Pipeline::new();

        pipeline
            .flushall() // route to all masters
            .add_command(cmd("EVAL")); // route randomly

        assert_eq!(route_for_pipeline(&pipeline), Ok(None));
    }

    #[test]
    fn test_prefer_primary_route_over_replica() {
        let mut pipeline = crate::Pipeline::new();

        pipeline
            .get("foo") // route to replica of slot 12182
            .flushall() // route to all masters
            .add_command(cmd("EVAL"))// route randomly
            .cmd("CONFIG").arg("GET").arg("timeout") // unkeyed command
            .set("foo", "bar"); // route to primary of slot 12182

        assert_eq!(
            route_for_pipeline(&pipeline),
            Ok(Some(Route::with_slot(
                Slot::new(12182).unwrap(),
                SlotAddr::Master
            )))
        );
    }

    #[test]
    fn test_raise_cross_slot_error_on_conflicting_slots() {
        let mut pipeline = crate::Pipeline::new();

        pipeline
            .flushall() // route to all masters
            .set("baz", "bar") // route to slot 4813
            .get("foo"); // route to slot 12182

        assert_eq!(
            route_for_pipeline(&pipeline).unwrap_err().kind(),
            crate::ServerErrorKind::CrossSlot.into()
        );
    }

    #[test]
    fn unkeyed_commands_dont_affect_route() {
        let mut pipeline = crate::Pipeline::new();

        pipeline
            .set("{foo}bar", "baz") // route to primary of slot 12182
            .cmd("CONFIG").arg("GET").arg("timeout") // unkeyed command
            .set("foo", "bar") // route to primary of slot 12182
            .cmd("DEBUG").arg("PAUSE").arg("100") // unkeyed command
            .cmd("ECHO").arg("hello world"); // unkeyed command

        assert_eq!(
            route_for_pipeline(&pipeline),
            Ok(Some(Route::with_slot(
                Slot::new(12182).unwrap(),
                SlotAddr::Master
            )))
        );
    }
}
