use std::time::Duration;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CloseBehaviour {
    #[default]
    Immediate,
    Delay(Duration),
    Hang,
}

impl CloseBehaviour {
    pub(crate) async fn run(self) {
        match self {
            Self::Immediate => {}
            Self::Delay(delay) => tokio::time::sleep(delay).await,
            Self::Hang => std::future::pending().await,
        }
    }
}
