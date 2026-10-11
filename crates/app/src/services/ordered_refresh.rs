use std::future::Future;

pub async fn after_mutation<T>(
    order: &tokio::sync::Mutex<()>,
    mutation: impl Future<Output = ()>,
    refresh: impl Future<Output = T>,
) -> T {
    let _turn = order.lock().await;
    mutation.await;
    refresh.await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    async fn step(log: &Arc<Mutex<Vec<&'static str>>>, name: &'static str, delay_ms: u64) {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        log.lock().unwrap().push(name);
    }

    #[tokio::test(start_paused = true)]
    async fn a_later_mutation_never_overtakes_an_earlier_refresh() {
        let order = tokio::sync::Mutex::new(());
        let log = Arc::new(Mutex::new(Vec::new()));
        tokio::join!(
            after_mutation(&order, step(&log, "delete 1", 50), step(&log, "refresh 1", 0)),
            after_mutation(&order, step(&log, "delete 2", 0), step(&log, "refresh 2", 0)),
        );
        assert_eq!(
            *log.lock().unwrap(),
            vec!["delete 1", "refresh 1", "delete 2", "refresh 2"]
        );
    }
}
