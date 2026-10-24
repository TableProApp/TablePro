use testcontainers::bollard::query_parameters::InspectContainerOptions;
use testcontainers::core::client::docker_client_instance;
use testcontainers::{ContainerAsync, Image};

const LOG_TAIL_LINES: usize = 40;

pub(crate) async fn container_state<I: Image>(container: &ContainerAsync<I>) -> String {
    let inspected = match docker_client_instance().await {
        Ok(docker) => docker
            .inspect_container(container.id(), None::<InspectContainerOptions>)
            .await
            .map_err(|error| error.to_string()),
        Err(error) => Err(error.to_string()),
    };
    match inspected.map(|response| response.state) {
        Ok(Some(state)) => format!(
            "status {}, exit code {}, OOM killed {}, error \"{}\"",
            state.status.map(|status| status.to_string()).unwrap_or_default(),
            state.exit_code.map(|code| code.to_string()).unwrap_or_default(),
            state.oom_killed.unwrap_or_default(),
            state.error.unwrap_or_default(),
        ),
        Ok(None) => "no state reported".to_owned(),
        Err(error) => format!("unavailable: {error}"),
    }
}

pub(crate) async fn log_tail<I: Image>(container: &ContainerAsync<I>) -> String {
    let stdout = container.stdout_to_vec().await;
    let stderr = container.stderr_to_vec().await;
    format!(
        "stdout:\n{}\nstderr:\n{}",
        stream_tail(stdout.as_deref().map_err(ToString::to_string)),
        stream_tail(stderr.as_deref().map_err(ToString::to_string)),
    )
}

fn stream_tail(output: Result<&[u8], String>) -> String {
    match output {
        Ok(bytes) => {
            let text = String::from_utf8_lossy(bytes);
            let lines: Vec<&str> = text.lines().collect();
            lines[lines.len().saturating_sub(LOG_TAIL_LINES)..].join("\n")
        }
        Err(error) => format!("unavailable: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_log_tail_keeps_the_last_lines() {
        let log: String = (1..=50).map(|line| format!("line {line}\n")).collect();

        let tail = stream_tail(Ok(log.as_bytes()));

        assert!(tail.starts_with("line 11\n"), "{tail}");
        assert!(tail.ends_with("\nline 50"), "{tail}");
        assert_eq!(stream_tail(Err("gone".to_owned())), "unavailable: gone");
    }
}
