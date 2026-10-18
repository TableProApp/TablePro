static TURN: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub async fn take() -> tokio::sync::MutexGuard<'static, ()> {
    TURN.lock().await
}

pub async fn run<T>(operation: impl std::future::Future<Output = T>) -> T {
    run_locked(&TURN, operation).await
}

async fn run_locked<T>(turn: &tokio::sync::Mutex<()>, operation: impl std::future::Future<Output = T>) -> T {
    let _turn = turn.lock().await;
    operation.await
}

#[cfg(test)]
pub fn is_held() -> bool {
    TURN.try_lock().is_err()
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn run_locked_holds_the_turn_during_the_operation() {
        let turn = tokio::sync::Mutex::const_new(());
        let held = super::run_locked(&turn, async { turn.try_lock().is_err() }).await;

        assert!(held);
        assert!(turn.try_lock().is_ok());
    }
}
