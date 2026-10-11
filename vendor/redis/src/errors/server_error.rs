use arcstr::ArcStr;
use std::fmt;

use crate::RetryMethod;

/// Kinds of errors returned from the server
#[derive(PartialEq, Debug, Clone, Copy, Eq)]
#[non_exhaustive]
pub enum ServerErrorKind {
    /// The server generated an invalid response, or returned a general error.
    ResponseError,
    /// A script execution was aborted.
    ExecAbort,
    /// The server cannot response because it's loading a dump.
    BusyLoading,
    /// A script that was requested does not actually exist.
    NoScript,
    /// Raised if a key moved to a different node.
    Moved,
    /// Raised if a key moved to a different node but we need to ask.
    Ask,
    /// Raised if a request needs to be retried.
    TryAgain,
    /// Raised if a redis cluster is down.
    ClusterDown,
    /// A request spans multiple slots
    CrossSlot,
    /// A cluster master is unavailable.
    MasterDown,
    /// Attempt to write to a read-only server
    ReadOnly,
    /// Attempted to kill a script/function while they werent' executing
    NotBusy,
    /// Attempted to unsubscribe on a connection that is not in subscribed mode.
    NoSub,
    /// Attempted to use a command without ACL permission.
    NoPerm,
}

impl ServerErrorKind {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::ResponseError => "ERR",
            Self::ExecAbort => "EXECABORT",
            Self::BusyLoading => "LOADING",
            Self::NoScript => "NOSCRIPT",
            Self::Moved => "MOVED",
            Self::Ask => "ASK",
            Self::TryAgain => "TRYAGAIN",
            Self::ClusterDown => "CLUSTERDOWN",
            Self::CrossSlot => "CROSSSLOT",
            Self::MasterDown => "MASTERDOWN",
            Self::ReadOnly => "READONLY",
            Self::NotBusy => "NOTBUSY",
            Self::NoSub => "NOSUB",
            Self::NoPerm => "NOPERM",
        }
    }

    pub(crate) fn retry_method(self) -> RetryMethod {
        match self {
            Self::Moved => RetryMethod::MovedRedirect,
            Self::Ask => RetryMethod::AskRedirect,

            Self::TryAgain | Self::MasterDown | Self::ClusterDown | Self::BusyLoading => {
                RetryMethod::WaitAndRetry
            }

            // A write that lands on a node demoted to replica during failover returns READONLY.
            // The slot map is stale, so refresh topology and retry against the new master.
            Self::ReadOnly => RetryMethod::RefreshSlotsAndRetry,

            Self::ResponseError
            | Self::ExecAbort
            | Self::NoScript
            | Self::CrossSlot
            | Self::NotBusy
            | Self::NoSub
            | Self::NoPerm => RetryMethod::NoRetry,
        }
    }
}

/// An error that was returned from the server
#[derive(PartialEq, Debug, Clone)]
pub struct ServerError(pub(crate) Repr);

#[derive(PartialEq, Debug, Clone)]
pub(crate) enum Repr {
    Extension {
        code: ArcStr,
        detail: Option<ArcStr>,
    },
    Known {
        kind: ServerErrorKind,
        detail: Option<ArcStr>,
    },
}

impl ServerError {
    /// Returns the kind of error. If `None`, try `crate::Self::code` to get the error code.
    pub fn kind(&self) -> Option<ServerErrorKind> {
        match &self.0 {
            Repr::Extension { .. } => None,
            Repr::Known { kind, .. } => Some(*kind),
        }
    }

    /// The error code returned from the server
    pub fn code(&self) -> &str {
        match &self.0 {
            Repr::Extension { code, .. } => code,
            Repr::Known { kind, .. } => kind.code(),
        }
    }

    /// Additional details about the error, if exist
    pub fn details(&self) -> Option<&str> {
        match &self.0 {
            Repr::Extension { detail, .. } => detail.as_ref().map(|str| str.as_str()),
            Repr::Known { detail, .. } => detail.as_ref().map(|str| str.as_str()),
        }
    }

    #[cfg(feature = "cluster-async")]
    pub(crate) fn requires_action(&self) -> bool {
        !matches!(
            self.kind()
                .map(|kind| kind.retry_method())
                .unwrap_or(RetryMethod::NoRetry),
            RetryMethod::NoRetry
        )
    }
}

impl fmt::Display for ServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            Repr::Extension { code, detail } => {
                fmt::Debug::fmt(&code, f)?;
                if let Some(detail) = detail {
                    f.write_str(": ")?;
                    detail.fmt(f)?;
                }
                Ok(())
            }
            Repr::Known { kind, detail } => {
                fmt::Debug::fmt(&kind, f)?;
                if let Some(detail) = detail {
                    f.write_str(": ")?;
                    detail.fmt(f)?;
                }
                Ok(())
            }
        }
    }
}

impl std::error::Error for ServerError {}
