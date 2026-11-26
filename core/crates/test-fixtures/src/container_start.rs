use std::time::Duration;

use testcontainers::core::error::ClientError;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ContainerRequest, Image, TestcontainersError};

use crate::FixtureError;

const START_ATTEMPTS: u32 = 3;
const PULL_RETRY_DELAY: Duration = Duration::from_secs(5);

// testcontainers pulls once, so a pull the registry cut short ("bytes remaining on stream") failed every test that
// needed the image. A request is consumed by its start, hence the builder.
pub async fn start_container<I: Image>(
    request: impl Fn() -> ContainerRequest<I>,
) -> Result<ContainerAsync<I>, FixtureError> {
    let mut attempt = 1;
    loop {
        match request().start().await {
            Err(TestcontainersError::Client(ClientError::PullImage { .. })) if attempt < START_ATTEMPTS => {
                attempt += 1;
                tokio::time::sleep(PULL_RETRY_DELAY).await;
            }
            started => return Ok(started?),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;
    use crate::FixtureImage;

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_pull_that_keeps_failing_is_tried_three_times_and_reported() {
        let image = FixtureImage {
            name: "alpine",
            tag: "tablepro-no-such-tag",
        };
        let started = Instant::now();

        let error = start_container(|| image.generic().into()).await.err().unwrap();

        let FixtureError::Container(TestcontainersError::Client(ClientError::PullImage { descriptor, .. })) = &error
        else {
            panic!("unexpected error: {error}");
        };
        assert_eq!(descriptor, &format!("{}:{}", image.pull_name(), image.tag));
        assert!(
            started.elapsed() >= PULL_RETRY_DELAY * (START_ATTEMPTS - 1),
            "took {:?}",
            started.elapsed()
        );
    }
}
