use std::time::Duration;

use testcontainers::bollard::Docker;
use testcontainers::bollard::errors::Error as BollardError;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, Image, ImageExt};

use crate::FixtureError;

const PULL_ATTEMPTS: u32 = 3;
const PULL_RETRY_DELAY: Duration = Duration::from_secs(5);

/// Starts the container, pulling its image first when Docker does not have
/// it. testcontainers pulls once, so a pull the registry cut short ("bytes
/// remaining on stream") failed every test that needed the image.
pub async fn start_container<I: Image>(request: ContainerRequest<I>) -> Result<ContainerAsync<I>, FixtureError> {
    let descriptor = request.descriptor();
    if image_missing(&descriptor).await {
        pull(&descriptor, request.platform().as_deref()).await?;
    }
    Ok(request.start().await?)
}

async fn image_missing(descriptor: &str) -> bool {
    // Any other answer leaves the pull to testcontainers, as before.
    let Ok(docker) = Docker::connect_with_defaults() else {
        return false;
    };
    matches!(
        docker.inspect_image(descriptor).await,
        Err(BollardError::DockerResponseServerError { status_code: 404, .. })
    )
}

async fn pull(descriptor: &str, platform: Option<&str>) -> Result<(), FixtureError> {
    let (name, tag) = descriptor.rsplit_once(':').unwrap_or((descriptor, "latest"));
    let mut attempt = 1;
    loop {
        let image = GenericImage::new(name, tag);
        // testcontainers falls back to linux/amd64 itself when no platform is
        // named, which the SQL Server images need on arm64.
        let pulled = match platform {
            Some(platform) => image.with_platform(platform).pull_image().await,
            None => image.pull_image().await,
        };
        match pulled {
            Ok(_) => return Ok(()),
            Err(_) if attempt < PULL_ATTEMPTS => {
                attempt += 1;
                tokio::time::sleep(PULL_RETRY_DELAY).await;
            }
            Err(error) => return Err(error.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use testcontainers::TestcontainersError;
    use testcontainers::core::error::ClientError;

    use super::*;

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_pull_that_keeps_failing_is_tried_three_times_and_reported() {
        let started = Instant::now();

        let error = start_container(ContainerRequest::from(GenericImage::new(
            "alpine",
            "tablepro-no-such-tag",
        )))
        .await
        .err()
        .unwrap();

        let FixtureError::Container(TestcontainersError::Client(ClientError::PullImage { descriptor, .. })) = &error
        else {
            panic!("unexpected error: {error}");
        };
        assert_eq!(descriptor, "alpine:tablepro-no-such-tag");
        assert!(
            started.elapsed() >= PULL_RETRY_DELAY * (PULL_ATTEMPTS - 1),
            "took {:?}",
            started.elapsed()
        );
    }
}
