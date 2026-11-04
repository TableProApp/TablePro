/// The `endpoint:` flag of a connection suite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuiteEndpoint {
    Network,
    File,
}
