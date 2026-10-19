use tablepro_core::credentials::SecretError;

/// Where in the flow the failure happened. Opening the keyring and using
/// it fail differently: a wire error while opening means the service is
/// not there, while the same error later is a hiccup on a service that
/// does exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
    Open,
    Use,
}

pub(super) fn map_error(error: oo7::Error, stage: Stage) -> SecretError {
    match error {
        oo7::Error::DBus(oo7::dbus::Error::Dismissed) => SecretError::UnlockDismissed,
        oo7::Error::DBus(oo7::dbus::Error::Service(oo7::dbus::ServiceError::IsLocked(_))) => SecretError::Locked,
        oo7::Error::File(oo7::file::Error::Locked) => SecretError::Locked,
        oo7::Error::DBus(error @ (oo7::dbus::Error::ZBus(_) | oo7::dbus::Error::NotFound(_)))
            if stage == Stage::Open =>
        {
            SecretError::ServiceUnavailable {
                detail: error.to_string(),
            }
        }
        // Under Flatpak, Keyring::new asks the Secret portal first, so a
        // missing portal surfaces here rather than as a D-Bus failure.
        oo7::Error::File(error @ oo7::file::Error::Portal(_)) => SecretError::PortalUnavailable {
            detail: error.to_string(),
        },
        other => SecretError::Backend {
            service_message: service_message(&other),
            detail: other.to_string(),
        },
    }
}

/// The Secret Service's own words, for a failure that is its reply
/// rather than oo7's or the bus connection's.
fn service_message(error: &oo7::Error) -> Option<String> {
    use oo7::dbus::{Error, ServiceError};
    use oo7::zbus::DBusError as _;

    let oo7::Error::DBus(error) = error else {
        return None;
    };
    let message = match error {
        Error::Service(
            ServiceError::IsLocked(message) | ServiceError::NoSession(message) | ServiceError::NoSuchObject(message),
        ) => Some(message.clone()),
        Error::Service(ServiceError::ZBus(error)) | Error::ZBus(error) => match error {
            oo7::zbus::Error::MethodError(name, description, _) => {
                Some(description.clone().unwrap_or_else(|| name.to_string()))
            }
            oo7::zbus::Error::FDO(error) => error.description().map(str::to_owned),
            _ => None,
        },
        _ => None,
    };
    message.filter(|message| !message.trim().is_empty())
}

/// Whether the cached handle is worth keeping. A wire error means the
/// connection is gone, so the next call reopens instead of retrying on a
/// dead socket.
pub(super) fn invalidates_handle(error: &oo7::Error) -> bool {
    matches!(error, oo7::Error::DBus(oo7::dbus::Error::ZBus(_)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_dismissed_is_unlock_dismissed() {
        let mapped = map_error(oo7::dbus::Error::Dismissed.into(), Stage::Use);

        assert_eq!(mapped, SecretError::UnlockDismissed);
        assert!(mapped.is_retryable());
    }

    #[test]
    fn map_is_locked_service_error_is_locked() {
        let mapped = map_error(
            oo7::dbus::Error::Service(oo7::dbus::ServiceError::IsLocked("collection".to_owned())).into(),
            Stage::Use,
        );

        assert_eq!(mapped, SecretError::Locked);
    }

    #[test]
    fn map_file_locked_is_locked() {
        let mapped = map_error(oo7::file::Error::Locked.into(), Stage::Use);

        assert_eq!(mapped, SecretError::Locked);
    }

    #[test]
    fn map_not_found_on_open_is_service_unavailable() {
        let mapped = map_error(oo7::dbus::Error::NotFound("collection".to_owned()).into(), Stage::Open);

        assert!(matches!(mapped, SecretError::ServiceUnavailable { .. }), "{mapped:?}");
        assert!(!mapped.is_retryable());
    }

    #[test]
    fn map_not_found_while_using_is_a_backend_error() {
        let mapped = map_error(oo7::dbus::Error::NotFound("collection".to_owned()).into(), Stage::Use);

        assert!(
            matches!(
                mapped,
                SecretError::Backend {
                    service_message: None,
                    ..
                }
            ),
            "{mapped:?}"
        );
    }

    #[test]
    fn a_reply_from_the_service_keeps_its_own_words() {
        let mapped = map_error(
            oo7::dbus::Error::Service(oo7::dbus::ServiceError::NoSuchObject(
                "No such item at /org/freedesktop/secrets/collection/login/7".to_owned(),
            ))
            .into(),
            Stage::Use,
        );

        let SecretError::Backend { service_message, .. } = mapped else {
            panic!("expected a backend error, got {mapped:?}");
        };
        assert_eq!(
            service_message.as_deref(),
            Some("No such item at /org/freedesktop/secrets/collection/login/7")
        );
    }

    #[test]
    fn oo7s_own_text_is_not_taken_for_the_services() {
        let mapped = map_error(oo7::dbus::Error::Deleted.into(), Stage::Use);

        assert!(
            matches!(
                mapped,
                SecretError::Backend {
                    service_message: None,
                    ..
                }
            ),
            "{mapped:?}"
        );
    }

    #[test]
    fn map_portal_error_is_portal_unavailable() {
        let mapped = map_error(
            oo7::file::Error::Portal(oo7::ashpd::Error::NoResponse).into(),
            Stage::Open,
        );

        assert!(matches!(mapped, SecretError::PortalUnavailable { .. }), "{mapped:?}");
    }

    #[test]
    fn only_a_wire_error_invalidates_the_handle() {
        assert!(!invalidates_handle(&oo7::dbus::Error::Dismissed.into()));
        assert!(!invalidates_handle(&oo7::file::Error::Locked.into()));
    }
}
