# Distro floor diagnostics, 2026-10-15

Issue: [#937](https://github.com/cozyGarage/BookiE/issues/937). Pull request: [#949](https://github.com/cozyGarage/BookiE/pull/949).

Review reproduced a second hidden-diagnostic case: an actual subprocess printed a passed scenario followed by an unexpected portal startup error and exited 19. The original reporter emitted only the passed summary. The new regression failed before the fix.

The reporter now emits any matching summary and always prints the final 20 unfiltered log lines. It preserves the original nonzero suite status. Empty logs remain explicit failures. No scenario acceptance condition changed.

`python3 -m unittest scripts.tests.test_distro_floor_failure_report` passes all four regressions, including the mixed success/error log.
