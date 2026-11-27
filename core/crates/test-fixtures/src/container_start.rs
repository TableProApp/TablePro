use std::time::Duration;

use testcontainers::bollard::query_parameters::TagImageOptionsBuilder;
use testcontainers::core::client::docker_client_instance;
use testcontainers::core::error::ClientError;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, Image, TestcontainersError};

use crate::FixtureError;

const START_ATTEMPTS: u32 = 3;
const PULL_RETRY_DELAY: Duration = Duration::from_secs(5);
const DOCKER_HUB_MIRROR: &str = "TABLEPRO_TEST_DOCKER_HUB_MIRROR";

// testcontainers pulls once, so a pull the registry cut short ("bytes remaining on stream") failed every test that
// needed the image. A request is consumed by its start, hence the builder.
pub async fn start_container<I: Image>(
    request: impl Fn() -> ContainerRequest<I>,
) -> Result<ContainerAsync<I>, FixtureError> {
    let mirror = std::env::var(DOCKER_HUB_MIRROR).unwrap_or_default();
    let mut attempt = 1;
    loop {
        let request = request();
        pull_through_mirror(&request.descriptor(), &mirror).await;
        match request.start().await {
            Err(TestcontainersError::Client(ClientError::PullImage { .. })) if attempt < START_ATTEMPTS => {
                attempt += 1;
                tokio::time::sleep(PULL_RETRY_DELAY).await;
            }
            started => return Ok(started?),
        }
    }
}

// A daemon's registry-mirrors, which a job container cannot set on the runner's daemon (linux/docs/testing.md, Docker
// or Podman). When the mirror fails, testcontainers pulls from Docker Hub as before.
async fn pull_through_mirror(descriptor: &str, mirror: &str) {
    let Some((mirrored, repository, tag)) = docker_hub_mirror_reference(descriptor, mirror) else {
        return;
    };
    let Ok(docker) = docker_client_instance().await else {
        return;
    };
    if docker.inspect_image(descriptor).await.is_ok() {
        return;
    }
    let pulled = GenericImage::new(mirrored.clone(), tag.to_owned()).pull_image().await;
    if pulled.is_ok() {
        let options = TagImageOptionsBuilder::new().repo(repository).tag(tag).build();
        docker.tag_image(&format!("{mirrored}:{tag}"), Some(options)).await.ok();
    }
}

fn docker_hub_mirror_reference<'a>(descriptor: &'a str, mirror: &str) -> Option<(String, &'a str, &'a str)> {
    let mirror = mirror.trim_end_matches('/');
    let (repository, tag) = descriptor.rsplit_once(':').filter(|(_, tag)| !tag.contains('/'))?;
    if mirror.is_empty() || descriptor.contains('@') {
        return None;
    }
    let path = match repository.split_once('/') {
        // Docker's own rule for a first component that names a registry.
        Some((first, _)) if first.contains(['.', ':']) || first == "localhost" => return None,
        Some(_) => repository.to_owned(),
        None => format!("library/{repository}"),
    };
    Some((format!("{mirror}/{path}"), repository, tag))
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use testcontainers::bollard::query_parameters::RemoveImageOptions;

    use super::*;

    #[test]
    fn a_mirror_stands_in_for_docker_hub_and_no_other_registry() {
        let gcr = "mirror.gcr.io";
        let postgres = Some("mirror.gcr.io/library/postgres");
        let cases = [
            ("postgres:17-alpine", "", None),
            ("postgres:17-alpine", gcr, postgres),
            ("postgres:17-alpine", "mirror.gcr.io/", postgres),
            ("edoburu/pgbouncer:1", gcr, Some("mirror.gcr.io/edoburu/pgbouncer")),
            ("mcr.microsoft.com/mssql/server:2022", gcr, None),
            ("localhost/tablepro:dev", gcr, None),
            ("localhost:5000/tablepro:dev", gcr, None),
            ("postgres@sha256:0115267ab5a5", gcr, None),
        ];
        for (descriptor, mirror, expected) in cases {
            let mirrored = docker_hub_mirror_reference(descriptor, mirror).map(|(mirrored, _, _)| mirrored);
            assert_eq!(mirrored.as_deref(), expected, "{descriptor} through {mirror:?}");
        }
        assert_eq!(
            docker_hub_mirror_reference("linuxserver/openssh-server:9", gcr),
            Some((
                "mirror.gcr.io/linuxserver/openssh-server".to_owned(),
                "linuxserver/openssh-server",
                "9"
            ))
        );
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn an_image_comes_through_the_mirror_under_its_docker_hub_name() {
        let descriptor = "busybox:1.37.0-musl";
        let docker = docker_client_instance().await.unwrap();
        docker
            .remove_image(descriptor, None::<RemoveImageOptions>, None)
            .await
            .ok();

        pull_through_mirror(descriptor, "mirror.gcr.io").await;

        let pulled = docker.inspect_image(descriptor).await.unwrap();
        let names = pulled.repo_tags.unwrap_or_default();
        assert!(names.iter().any(|name| name == descriptor), "{names:?}");
        assert!(
            names
                .iter()
                .any(|name| name == "mirror.gcr.io/library/busybox:1.37.0-musl"),
            "{names:?}"
        );
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_pull_that_keeps_failing_is_tried_three_times_and_reported() {
        let started = Instant::now();

        let error = start_container(|| GenericImage::new("alpine", "tablepro-no-such-tag").into())
            .await
            .err()
            .unwrap();

        let FixtureError::Container(TestcontainersError::Client(ClientError::PullImage { descriptor, .. })) = &error
        else {
            panic!("unexpected error: {error}");
        };
        assert_eq!(descriptor, "alpine:tablepro-no-such-tag");
        assert!(
            started.elapsed() >= PULL_RETRY_DELAY * (START_ATTEMPTS - 1),
            "took {:?}",
            started.elapsed()
        );
    }
}
