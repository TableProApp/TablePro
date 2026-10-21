use std::time::Duration;

use sqlx::postgres::PgPoolOptions;

pub(crate) fn options() -> PgPoolOptions {
    PgPoolOptions::new()
        .max_connections(4)
        .acquire_timeout(Duration::from_secs(5))
        .after_release(|connection, _| {
            Box::pin(async move { Ok(sqlx::query("DISCARD ALL").execute(connection).await.is_ok()) })
        })
}
