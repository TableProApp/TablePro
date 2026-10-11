use std::time::Duration;

use serde::{de::Unexpected, Deserialize, Deserializer, Serialize};

use crate::{event::cmap::*, options::ServerAddress};

impl Serialize for CmapEvent {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            Self::PoolCreated(event) => event.serialize(serializer),
            Self::PoolClosed(event) => event.serialize(serializer),
            Self::PoolReady(event) => event.serialize(serializer),
            Self::ConnectionCreated(event) => event.serialize(serializer),
            Self::ConnectionReady(event) => event.serialize(serializer),
            Self::ConnectionClosed(event) => event.serialize(serializer),
            Self::ConnectionCheckoutStarted(event) => event.serialize(serializer),
            Self::ConnectionCheckoutFailed(event) => event.serialize(serializer),
            Self::ConnectionCheckedOut(event) => event.serialize(serializer),
            Self::PoolCleared(event) => event.serialize(serializer),
            Self::ConnectionCheckedIn(event) => event.serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for CmapEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(tag = "type")]
        // clippy doesn't like that all variants start with the same name, but we use these
        // to match the test file names.
        #[allow(clippy::enum_variant_names)]
        enum EventHelper {
            #[serde(deserialize_with = "self::deserialize_pool_created")]
            ConnectionPoolCreated(PoolCreatedEvent),
            ConnectionPoolClosed(PoolClosedEvent),
            ConnectionPoolReady(PoolReadyEvent),
            ConnectionCreated(ConnectionCreatedEvent),
            ConnectionReady(ConnectionReadyEvent),
            ConnectionClosed(ConnectionClosedEvent),
            ConnectionCheckOutStarted(ConnectionCheckoutStartedEvent),
            #[serde(deserialize_with = "self::deserialize_checkout_failed")]
            ConnectionCheckOutFailed(ConnectionCheckoutFailedEvent),
            ConnectionCheckedOut(ConnectionCheckedOutEvent),
            ConnectionPoolCleared(PoolClearedEvent),
            ConnectionCheckedIn(ConnectionCheckedInEvent),
        }

        let helper = EventHelper::deserialize(deserializer)?;
        let event = match helper {
            EventHelper::ConnectionPoolCreated(e) => CmapEvent::PoolCreated(e),
            EventHelper::ConnectionPoolClosed(e) => CmapEvent::PoolClosed(e),
            EventHelper::ConnectionPoolReady(e) => CmapEvent::PoolReady(e),
            EventHelper::ConnectionCreated(e) => CmapEvent::ConnectionCreated(e),
            EventHelper::ConnectionReady(e) => CmapEvent::ConnectionReady(e),
            EventHelper::ConnectionClosed(e) => CmapEvent::ConnectionClosed(e),
            EventHelper::ConnectionCheckOutStarted(e) => CmapEvent::ConnectionCheckoutStarted(e),
            EventHelper::ConnectionCheckOutFailed(e) => CmapEvent::ConnectionCheckoutFailed(e),
            EventHelper::ConnectionCheckedOut(e) => CmapEvent::ConnectionCheckedOut(e),
            EventHelper::ConnectionPoolCleared(e) => CmapEvent::PoolCleared(e),
            EventHelper::ConnectionCheckedIn(e) => CmapEvent::ConnectionCheckedIn(e),
        };
        Ok(event)
    }
}

impl CmapEvent {
    pub(crate) fn name(&self) -> &'static str {
        match self {
            CmapEvent::PoolCreated(_) => "ConnectionPoolCreated",
            CmapEvent::PoolReady(_) => "ConnectionPoolReady",
            CmapEvent::PoolClosed(_) => "ConnectionPoolClosed",
            CmapEvent::ConnectionCreated(_) => "ConnectionCreated",
            CmapEvent::ConnectionReady(_) => "ConnectionReady",
            CmapEvent::ConnectionClosed(_) => "ConnectionClosed",
            CmapEvent::ConnectionCheckoutStarted(_) => "ConnectionCheckOutStarted",
            CmapEvent::ConnectionCheckoutFailed(_) => "ConnectionCheckOutFailed",
            CmapEvent::ConnectionCheckedOut(_) => "ConnectionCheckedOut",
            CmapEvent::PoolCleared(_) => "ConnectionPoolCleared",
            CmapEvent::ConnectionCheckedIn(_) => "ConnectionCheckedIn",
        }
    }
}

#[derive(Debug, Deserialize)]
struct PoolCreatedEventHelper {
    #[serde(default)]
    pub options: Option<PoolOptionsHelper>,
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum PoolOptionsHelper {
    Number(u64),
    Options(ConnectionPoolOptions),
}

fn deserialize_pool_created<'de, D>(deserializer: D) -> Result<PoolCreatedEvent, D::Error>
where
    D: Deserializer<'de>,
{
    let helper = PoolCreatedEventHelper::deserialize(deserializer)?;

    // The CMAP spec tests use "42" as a placeholder in the expected events to indicate that the
    // driver should assert that a value is present without any constraints on the value itself.
    // This idiom is used for the connection pool creation options even when no options are
    // specified, meaning that there isn't any useful assertion we can do based on this value.
    // Because of this, we deserialize the value `42` into `None` for the options, which prevents
    // deserialization failure due to an unexpected type. For other integer values, we raise an
    // error indicating that we expect `42` instead.
    let options = match helper.options {
        Some(PoolOptionsHelper::Options(opts)) => Some(opts),
        Some(PoolOptionsHelper::Number(42)) | None => None,
        Some(PoolOptionsHelper::Number(other)) => {
            return Err(serde::de::Error::invalid_value(
                Unexpected::Unsigned(other),
                &"42",
            ));
        }
    };

    Ok(PoolCreatedEvent {
        address: ServerAddress::Tcp {
            host: Default::default(),
            port: None,
        },
        options,
    })
}

#[derive(Debug, Deserialize)]
struct ConnectionCheckoutFailedHelper {
    reason: Option<CheckoutFailedReasonHelper>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum CheckoutFailedReasonHelper {
    Timeout,
    ConnectionError,
    PoolClosed,
}

fn deserialize_checkout_failed<'de, D>(
    deserializer: D,
) -> Result<ConnectionCheckoutFailedEvent, D::Error>
where
    D: Deserializer<'de>,
{
    let helper = ConnectionCheckoutFailedHelper::deserialize(deserializer)?;

    let reason = match helper.reason {
        Some(CheckoutFailedReasonHelper::ConnectionError) => {
            ConnectionCheckoutFailedReason::ConnectionError
        }
        Some(CheckoutFailedReasonHelper::Timeout) => ConnectionCheckoutFailedReason::Timeout,
        // The driver does not implement the tests that use the PoolClosed reason, so we map the
        // test value to unset to allow for deserialization.
        Some(CheckoutFailedReasonHelper::PoolClosed) | None => {
            ConnectionCheckoutFailedReason::Unset
        }
    };

    Ok(ConnectionCheckoutFailedEvent {
        address: ServerAddress::Tcp {
            host: Default::default(),
            port: None,
        },
        reason,
        #[cfg(feature = "tracing-unstable")]
        error: None,
        duration: Duration::ZERO,
    })
}
