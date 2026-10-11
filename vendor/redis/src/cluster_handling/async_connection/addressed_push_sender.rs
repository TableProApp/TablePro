use futures_channel::mpsc::UnboundedSender;

use crate::{
    PushInfo,
    aio::{AsyncPushSender, SendError},
    cluster::NodeAddress,
};

pub(super) struct AddressedPushSender {
    address: NodeAddress,
    sender: UnboundedSender<(NodeAddress, PushInfo)>,
}

impl AddressedPushSender {
    pub(super) fn new(
        address: NodeAddress,
        sender: UnboundedSender<(NodeAddress, PushInfo)>,
    ) -> Self {
        Self { address, sender }
    }
}

impl AsyncPushSender for AddressedPushSender {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        self.sender
            .unbounded_send((self.address.clone(), info))
            .map_err(|_| SendError)
    }
}
