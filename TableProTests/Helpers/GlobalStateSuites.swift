import Testing

/// Suites that keep a process-wide value swapped across a suspension nest here. `.serialized` on
/// this parent orders every nested suite against the others; on a sibling suite it would only
/// order its own cases.
@Suite(.serialized)
enum GlobalStateSuites {}
