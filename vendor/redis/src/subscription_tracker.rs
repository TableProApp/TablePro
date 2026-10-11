#![allow(dead_code)]

use core::str;
use std::collections::HashSet;

use crate::{Arg, Cmd, Pipeline};

#[derive(Default)]
pub(crate) struct SubscriptionTracker {
    subscriptions: HashSet<Vec<u8>>,
    s_subscriptions: HashSet<Vec<u8>>,
    p_subscriptions: HashSet<Vec<u8>>,
}

pub(crate) enum SubscriptionAction {
    Subscribe,
    Unsubscribe,
    PSubscribe,
    PUnsubscribe,
    SSubscribe,
    Sunsubscribe,
}

impl SubscriptionAction {
    fn additive(&self) -> bool {
        match self {
            Self::Subscribe | Self::PSubscribe | Self::SSubscribe => true,

            Self::Unsubscribe | Self::PUnsubscribe | Self::Sunsubscribe => false,
        }
    }
}

impl SubscriptionTracker {
    pub(crate) fn to_request(
        cmd: &Cmd,
    ) -> Option<(SubscriptionAction, impl Iterator<Item = Vec<u8>>)> {
        let mut args_iter = cmd.args_iter();
        let first_arg = args_iter.next()?;

        let first_arg = match first_arg {
            Arg::Simple(arg) => arg,
            Arg::Cursor => return None,
        };
        let first_arg = str::from_utf8(first_arg).ok()?;

        let args = args_iter.filter_map(|arg| match arg {
            Arg::Simple(arg) => Some(arg.to_vec()),
            Arg::Cursor => None,
        });

        let action = if first_arg.eq_ignore_ascii_case("SUBSCRIBE") {
            SubscriptionAction::Subscribe
        } else if first_arg.eq_ignore_ascii_case("PSUBSCRIBE") {
            SubscriptionAction::PSubscribe
        } else if first_arg.eq_ignore_ascii_case("SSUBSCRIBE") {
            SubscriptionAction::SSubscribe
        } else if first_arg.eq_ignore_ascii_case("UNSUBSCRIBE") {
            SubscriptionAction::Unsubscribe
        } else if first_arg.eq_ignore_ascii_case("PUNSUBSCRIBE") {
            SubscriptionAction::PUnsubscribe
        } else if first_arg.eq_ignore_ascii_case("SUNSUBSCRIBE") {
            SubscriptionAction::Sunsubscribe
        } else {
            return None;
        };
        Some((action, args))
    }

    pub(crate) fn update_with_request(
        &mut self,
        action: SubscriptionAction,
        args: impl Iterator<Item = Vec<u8>>,
    ) {
        let set = match action {
            SubscriptionAction::Subscribe | SubscriptionAction::Unsubscribe => {
                &mut self.subscriptions
            }
            SubscriptionAction::PSubscribe | SubscriptionAction::PUnsubscribe => {
                &mut self.p_subscriptions
            }
            SubscriptionAction::SSubscribe | SubscriptionAction::Sunsubscribe => {
                &mut self.s_subscriptions
            }
        };

        if action.additive() {
            for sub in args {
                set.insert(sub);
            }
        } else {
            for sub in args {
                set.remove(&sub);
            }
        }
    }

    #[cfg(test)]
    fn update_with_cmd<'a>(&'a mut self, cmd: &'a Cmd) {
        if let Some((action, args)) = Self::to_request(cmd) {
            self.update_with_request(action, args);
        }
    }

    pub(crate) fn get_subscription_pipeline(&self) -> Pipeline {
        let mut pipeline = crate::pipe();
        if !self.subscriptions.is_empty() {
            let cmd = pipeline.cmd("SUBSCRIBE");
            for channel in self.subscriptions.iter() {
                cmd.arg(channel);
            }
        }
        if !self.s_subscriptions.is_empty() {
            let cmd = pipeline.cmd("SSUBSCRIBE");
            for channel in self.s_subscriptions.iter() {
                cmd.arg(channel);
            }
        }
        if !self.p_subscriptions.is_empty() {
            let cmd = pipeline.cmd("PSUBSCRIBE");
            for channel in self.p_subscriptions.iter() {
                cmd.arg(channel);
            }
        }

        pipeline
    }
}

#[cfg(test)]
mod tests {
    use crate::{cmd, pipe};

    use super::*;

    #[test]
    fn test_add_and_remove_subscriptions() {
        let mut tracker = SubscriptionTracker::default();

        tracker.update_with_cmd(cmd("subscribe").arg("foo").arg("bar"));
        tracker.update_with_cmd(cmd("PSUBSCRIBE").arg("fo*o").arg("b*ar"));
        tracker.update_with_cmd(cmd("SSUBSCRIBE").arg("sfoo").arg("sbar"));
        tracker.update_with_cmd(cmd("unsubscribe").arg("foo"));
        tracker.update_with_cmd(cmd("Punsubscribe").arg("b*ar"));
        tracker.update_with_cmd(cmd("Sunsubscribe").arg("sfoo").arg("SBAR"));
        // ignore irrelevant commands
        tracker.update_with_cmd(cmd("GET").arg("sfoo"));

        let result = tracker.get_subscription_pipeline();
        let mut expected = pipe();
        expected
            .cmd("SUBSCRIBE")
            .arg("bar")
            .cmd("SSUBSCRIBE")
            .arg("sbar")
            .cmd("PSUBSCRIBE")
            .arg("fo*o");
        assert_eq!(
            result.get_packed_pipeline(),
            expected.get_packed_pipeline(),
            "{}",
            String::from_utf8(result.get_packed_pipeline()).unwrap()
        );
    }

    #[test]
    fn test_skip_empty_subscriptions() {
        let mut tracker = SubscriptionTracker::default();

        tracker.update_with_cmd(cmd("subscribe").arg("foo").arg("bar"));
        tracker.update_with_cmd(cmd("PSUBSCRIBE").arg("fo*o").arg("b*ar"));
        tracker.update_with_cmd(cmd("unsubscribe").arg("foo").arg("bar"));
        tracker.update_with_cmd(cmd("punsubscribe").arg("fo*o"));

        let result = tracker.get_subscription_pipeline();
        let mut expected = pipe();
        expected.cmd("PSUBSCRIBE").arg("b*ar");
        assert_eq!(
            result.get_packed_pipeline(),
            expected.get_packed_pipeline(),
            "{}",
            String::from_utf8(result.get_packed_pipeline()).unwrap()
        );
    }

    #[test]
    fn test_only_unsubscribe_from_existing_subscriptions() {
        let mut tracker = SubscriptionTracker::default();

        tracker.update_with_cmd(cmd("unsubscribe").arg("foo"));
        tracker.update_with_cmd(cmd("subscribe").arg("foo"));

        let result = tracker.get_subscription_pipeline();
        let mut expected = pipe();
        expected.cmd("SUBSCRIBE").arg("foo");
        assert_eq!(
            result.get_packed_pipeline(),
            expected.get_packed_pipeline(),
            "{}",
            String::from_utf8(result.get_packed_pipeline()).unwrap()
        );
    }
}
