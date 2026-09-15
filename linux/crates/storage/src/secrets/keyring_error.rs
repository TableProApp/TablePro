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
            detail: other.to_string(),
        },
    }
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

        assert!(matches!(mapped, SecretError::Backend { .. }), "{mapped:?}");
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
