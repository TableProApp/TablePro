use std::any::Any;
use std::future::Future;
use std::panic::{AssertUnwindSafe, resume_unwind};

use futures::FutureExt;
use tablepro_core::DriverError;

const UNSUPPORTED_VARIANT: &str = "Tiberius cannot decode this sql_variant value; the connection was retired";

pub(crate) fn is_unsupported_result(error: &DriverError) -> bool {
    matches!(error, DriverError::Unsupported(message) if message == UNSUPPORTED_VARIANT)
}

pub(crate) async fn catch_tiberius_variant_panic<T>(
    query: impl Future<Output = Result<T, DriverError>>,
) -> Result<T, DriverError> {
    match AssertUnwindSafe(query).catch_unwind().await {
        Ok(result) => result,
        Err(payload) if is_tiberius_variant_panic(payload.as_ref()) => {
            Err(DriverError::Unsupported(UNSUPPORTED_VARIANT.into()))
        }
        Err(payload) => resume_unwind(payload),
    }
}

fn is_tiberius_variant_panic(payload: &(dyn Any + Send)) -> bool {
    payload
        .downcast_ref::<&str>()
        .is_some_and(|message| message.contains("not yet implemented for SSVariant"))
        || payload
            .downcast_ref::<String>()
            .is_some_and(|message| message.contains("not yet implemented for SSVariant"))
}

#[cfg(test)]
mod tests {
    use super::{catch_tiberius_variant_panic, is_tiberius_variant_panic, is_unsupported_result};
    use std::any::Any;
    use std::panic::AssertUnwindSafe;

    use futures::FutureExt;
    use tablepro_core::DriverError;

    #[test]
    fn only_the_known_ssvariant_metadata_panic_is_classified() {
        let variant: Box<dyn Any + Send> = Box::new("not yet implemented: not yet implemented for SSVariant");
        let unrelated: Box<dyn Any + Send> = Box::new("not yet implemented: another TDS type");
        assert!(is_tiberius_variant_panic(variant.as_ref()));
        assert!(!is_tiberius_variant_panic(unrelated.as_ref()));
    }

    #[tokio::test]
    async fn known_variant_panic_becomes_unsupported() {
        let result: Result<(), DriverError> =
            catch_tiberius_variant_panic(async { panic!("not yet implemented for SSVariant") }).await;
        assert!(matches!(&result, Err(DriverError::Unsupported(_))));
        assert!(is_unsupported_result(result.as_ref().unwrap_err()));
        assert!(!is_unsupported_result(&DriverError::Unsupported(
            "another unsupported operation".into()
        )));
        assert!(!is_unsupported_result(&DriverError::Query {
            message: "server rejected SQL".into(),
            sqlstate: Some("42000".into()),
            position: None,
        }));
    }

    #[tokio::test]
    async fn unrelated_panics_are_not_swallowed() {
        let query = catch_tiberius_variant_panic::<()>(async { panic!("unexpected driver panic") });
        let result = AssertUnwindSafe(query).catch_unwind().await;
        assert!(result.is_err(), "an unrelated panic must continue to unwind");
    }
}
