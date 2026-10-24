# Workspace restoration and cleanup privacy train acceptance

Aggregate [#1518](https://github.com/cozyGarage/BookiE/pull/1518) included [#1510](https://github.com/cozyGarage/BookiE/pull/1510) and [#1517](https://github.com/cozyGarage/BookiE/pull/1517). Forgejo run 925 passed at exact head `fe2c150dab6d48dfb070f67256baa3d2d6c28efd`. Required GitHub checks passed for the aggregate and both pinned member heads. [Verification identities and documentation-only differences](acceptance.json).

The aggregate merged as `bc2c5a9e443e3e4c2f9502b1d993161765be9212` before the run completed. Ordered two-parent integration and member identities were verified afterward. The intervening base and final merged-tree differences contain documentation only, matching the explicit documentation-only acceptance allowance. Executable, test, script and CI source match the gated head. Full-tree equality is not claimed.

The restoration repair discards unrestorable saved tab records before selecting a restored page, with failing-then-passing service and installed-app regressions. This satisfies [#1509](https://github.com/cozyGarage/BookiE/issues/1509); it does not close the broader workspace-freeze investigation. The cleanup repair withholds raw driver payloads from detached-session close warnings while retaining typed category and operation diagnostics, satisfying [#1516](https://github.com/cozyGarage/BookiE/issues/1516). It is not a complete application logging audit.

The final MongoDB GTK job spent 6 minutes 34 seconds compiling its optimized CI executable. Its actual scenario passed in 7.298 seconds. That observation identifies build time in this job, not the exclusive cause of whole-train duration.
