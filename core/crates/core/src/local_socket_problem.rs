use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LocalSocketProblem {
    // In a Flatpak this is also a socket the sandbox does not show.
    #[error("no socket is there")]
    Missing,

    #[error("nothing is listening on it")]
    Refused,

    #[error("permission denied")]
    PermissionDenied,

    #[error("{detail}")]
    Other { detail: String },
}

impl LocalSocketProblem {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Missing => "local_socket.missing",
            Self::Refused => "local_socket.refused",
            Self::PermissionDenied => "local_socket.permission_denied",
            Self::Other { .. } => "local_socket.other",
        }
    }

    pub fn from_io(error: &std::io::Error) -> Self {
        match error.kind() {
            std::io::ErrorKind::NotFound => Self::Missing,
            std::io::ErrorKind::ConnectionRefused => Self::Refused,
            std::io::ErrorKind::PermissionDenied => Self::PermissionDenied,
            _ => Self::Other {
                detail: error.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};

    use super::*;

    #[test]
    fn an_io_error_becomes_the_problem_the_user_can_act_on() {
        assert_eq!(
            LocalSocketProblem::from_io(&Error::from(ErrorKind::NotFound)),
            LocalSocketProblem::Missing
        );
        assert_eq!(
            LocalSocketProblem::from_io(&Error::from(ErrorKind::ConnectionRefused)),
            LocalSocketProblem::Refused
        );
        assert_eq!(
            LocalSocketProblem::from_io(&Error::from(ErrorKind::PermissionDenied)),
            LocalSocketProblem::PermissionDenied
        );
        assert_eq!(
            LocalSocketProblem::from_io(&Error::other("path too long")).code(),
            "local_socket.other"
        );
    }
}
