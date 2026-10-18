use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use futures::FutureExt;
use futures::channel::oneshot;
use futures::future::LocalBoxFuture;
use tablepro_core::NetworkEndpoint;
use tablepro_session::fakes::{FakeConnector, FakeEstablish};
use tablepro_session::health::Reachability;
use tablepro_session::runtime::Tasks;
use tablepro_session::{SessionClaim, SessionKey, SessionRegistry};
use tablepro_test_support::{ConnectionScript, FakeReply};

use crate::runtime::ReachabilityProbe;
use crate::test_support::FakeSession;

/// Answers each check with the next scripted reply, or holds it until
/// the test sends one, and records what it was asked.
#[derive(Default)]
pub(crate) struct FakeProbe {
    asked: RefCell<Vec<NetworkEndpoint>>,
    replies: RefCell<VecDeque<LocalBoxFuture<'static, Reachability>>>,
}

impl FakeProbe {
    pub(crate) fn answering(reachability: Reachability) -> Rc<Self> {
        let probe = Rc::new(Self::default());
        probe.then(reachability);
        probe
    }

    pub(crate) fn then(&self, reachability: Reachability) {
        self.replies
            .borrow_mut()
            .push_back(futures::future::ready(reachability).boxed_local());
    }

    /// The next check waits for the sender.
    pub(crate) fn then_held(&self) -> oneshot::Sender<Reachability> {
        let (sender, receiver) = oneshot::channel();
        self.replies
            .borrow_mut()
            .push_back(receiver.map(|reply| reply.unwrap_or_default()).boxed_local());
        sender
    }

    pub(crate) fn asked(&self) -> Vec<NetworkEndpoint> {
        self.asked.borrow().clone()
    }
}

impl ReachabilityProbe for FakeProbe {
    fn can_reach(&self, endpoint: &NetworkEndpoint) -> LocalBoxFuture<'static, Reachability> {
        self.asked.borrow_mut().push(endpoint.clone());
        let next = self.replies.borrow_mut().pop_front();
        next.unwrap_or_else(|| futures::future::ready(Reachability::Reachable).boxed_local())
    }
}

/// A session on `host` port 5432, attached under a key of its own.
pub(crate) struct Attached {
    pub fake: FakeSession,
    pub key: SessionKey,
    _claim: SessionClaim,
}

pub(crate) fn attach_remote(
    registry: &Rc<SessionRegistry>,
    host: &str,
    reconnects: Vec<FakeEstablish>,
    tasks: Tasks,
) -> Attached {
    let mut script = ConnectionScript::default();
    script.probe.always(FakeReply::ok(()));
    let request = FakeConnector::network_request(host, 5432).expect("a request");
    let fake = FakeSession::start_for(request, script, reconnects, tasks);
    let key = SessionKey::Saved(uuid::Uuid::new_v4());
    let claim = registry.claim(key.clone(), 1).expect("a claim");
    claim.attach(&fake.session);
    Attached {
        fake,
        key,
        _claim: claim,
    }
}
